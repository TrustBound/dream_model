//// Runs a query on real data and checks the analysis against it, the same
//// as the proof of concept's harness: no column typed never NULL may
//// return NULL, a hinted column that returns NULL breaks its promise, and
//// every `Option` parameter must accept NULL.
////
//// Each run is inside a transaction that is rolled back.

import dream_model/nullability.{type Analysis, type Column}
import dream_model/nullability/reason
import dream_model/postgres/wire
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What the data checks found.
pub type Outcome {
  /// Every check passed.
  Sound
  /// A column typed never NULL returned NULL, or PostgreSQL rejected NULL
  /// for an `Option` parameter.
  Broken(problems: List(String))
  /// A hinted column returned NULL, and the row check reported it.
  PromiseEnforced(message: String)
  /// A run failed with an error that the checks do not expect.
  RunFailed(message: String)
}

/// The SQLSTATE codes of a run that the data itself rejects: the run is
/// skipped, as in the proof of concept.
const rejected_by_data = [
  "23502", "23514", "23505", "23503", "22P02", "22003", "P0001", "21000",
  "44000",
]

/// The SQLSTATE codes that show a NULL parameter was rejected. 44000 is a
/// view's WITH CHECK OPTION.
const null_rejected = ["23502", "23514", "P0001", "44000"]

type Found {
  Found(breaks: List(String), promises: List(String))
}

/// Runs the query on each data set with each parameter set, and checks
/// the analysis. With no parameter sets, every parameter is `"1"`.
pub fn check(
  connection: wire.Connection,
  analysis: Analysis,
  name: String,
  sql: String,
  data_sets: List(#(String, String)),
  parameter_sets: Option(List(List(Option(String)))),
  reset: String,
) -> Outcome {
  let count = list.length(analysis.parameters)
  let parameter_sets =
    option.unwrap(parameter_sets, [list.repeat(Some("1"), count)])
  let runs =
    list.flat_map(data_sets, fn(data_set) {
      list.map(parameter_sets, fn(parameters) { #(data_set, parameters) })
    })
  let checked =
    list.try_fold(runs, Found([], []), fn(found, run) {
      let #(#(label, setup), parameters) = run
      check_run(
        connection,
        analysis,
        name,
        sql,
        label,
        setup,
        parameters,
        reset,
      )
      |> result.map(fn(more) {
        Found(
          list.append(found.breaks, more.breaks),
          list.append(found.promises, more.promises),
        )
      })
    })
  case checked {
    Error(message) -> RunFailed(message)
    Ok(found) -> {
      let first_parameters = list.first(parameter_sets) |> result.unwrap([])
      let first_data_set = list.first(data_sets) |> result.unwrap(#("", ""))
      let parameter_breaks =
        check_parameters(
          connection,
          analysis,
          sql,
          first_data_set,
          first_parameters,
          reset,
        )
      decide(list.append(found.breaks, parameter_breaks), found.promises)
    }
  }
}

fn decide(breaks: List(String), promises: List(String)) -> Outcome {
  case list.unique(breaks), promises {
    [_, ..] as breaks, _ -> Broken(breaks)
    [], [first, ..] -> PromiseEnforced(first)
    [], [] -> Sound
  }
}

fn check_run(
  connection: wire.Connection,
  analysis: Analysis,
  name: String,
  sql: String,
  label: String,
  setup: String,
  parameters: List(Option(String)),
  reset: String,
) -> Result(Found, String) {
  let ran = run(connection, sql, setup, parameters, reset)
  rollback(connection)
  case ran {
    Error(error) ->
      case list.contains(rejected_by_data, code(error)) {
        True -> Ok(Found([], []))
        False ->
          Error(
            "run failed on " <> label <> ": " <> wire.error_to_string(error),
          )
      }
    Ok(rows) -> Ok(check_rows(analysis.columns, rows, name, label, parameters))
  }
}

fn check_rows(
  columns: List(Column),
  rows: List(List(Option(String))),
  name: String,
  label: String,
  parameters: List(Option(String)),
) -> Found {
  let breaks =
    list.flat_map(rows, fn(row) {
      list.zip(columns, row)
      |> list.filter_map(fn(pair) {
        let #(column, value) = pair
        case value, column.not_null && column.reason != reason.NotNullHint {
          None, True ->
            Ok(
              "'"
              <> column.name
              <> "' typed never NULL but NULL came back (data: "
              <> label
              <> ", params: "
              <> string.inspect(parameters)
              <> ")",
            )
          _, _ -> Error(Nil)
        }
      })
    })
  let promises =
    list.filter_map(rows, fn(row) {
      nullability.check_row(columns, name, row)
      |> result.map_error(fn(promise) {
        nullability.broken_promise_to_string(promise)
        <> " (data: "
        <> label
        <> ")"
      })
      |> flip
    })
  Found(breaks, promises)
}

fn flip(checked: Result(Nil, String)) -> Result(String, Nil) {
  case checked {
    Ok(Nil) -> Error(Nil)
    Error(message) -> Ok(message)
  }
}

/// Every `Option` parameter must accept NULL: the run with NULL in its
/// place must not fail with a NOT NULL, CHECK or trigger error. The run
/// with the base parameters must pass first; otherwise the error does not
/// come from the NULL, for example an INSERT that leaves out a NOT NULL
/// column.
fn check_parameters(
  connection: wire.Connection,
  analysis: Analysis,
  sql: String,
  data_set: #(String, String),
  base: List(Option(String)),
  reset: String,
) -> List(String) {
  let base = case base {
    [] -> list.repeat(Some("1"), list.length(analysis.parameters))
    _ -> base
  }
  let base_run = run(connection, sql, data_set.1, base, reset)
  rollback(connection)
  case base_run {
    Ok(_) ->
      check_null_parameters(connection, analysis, sql, data_set, base, reset)
    Error(_) -> []
  }
}

fn check_null_parameters(
  connection: wire.Connection,
  analysis: Analysis,
  sql: String,
  data_set: #(String, String),
  base: List(Option(String)),
  reset: String,
) -> List(String) {
  analysis.parameters
  |> list.filter(fn(parameter) { parameter.optional })
  |> list.filter_map(fn(parameter) {
    let parameters =
      list.index_map(base, fn(value, index) {
        case index + 1 == parameter.position {
          True -> None
          False -> value
        }
      })
    let ran = run(connection, sql, data_set.1, parameters, reset)
    rollback(connection)
    case ran {
      Error(error) ->
        case list.contains(null_rejected, code(error)) {
          True ->
            Ok(
              "$"
              <> string.inspect(parameter.position)
              <> " typed Option but PostgreSQL rejected NULL: "
              <> wire.error_to_string(error),
            )
          False -> Error(Nil)
        }
      Ok(_) -> Error(Nil)
    }
  })
}

fn run(
  connection: wire.Connection,
  sql: String,
  setup: String,
  parameters: List(Option(String)),
  reset: String,
) -> Result(List(List(Option(String))), wire.WireError) {
  use _ <- result.try(wire.simple_query(connection, "begin"))
  use _ <- result.try(wire.simple_query(connection, reset))
  use _ <- result.try(case setup {
    "" -> Ok([])
    _ -> wire.simple_query(connection, setup)
  })
  wire.execute(connection, sql, parameters)
}

fn rollback(connection: wire.Connection) -> Nil {
  let _ = wire.simple_query(connection, "rollback")
  Nil
}

fn code(error: wire.WireError) -> String {
  case error {
    wire.ServerError(fields) -> wire.get_field(fields, "C") |> result.unwrap("")
    _ -> ""
  }
}
