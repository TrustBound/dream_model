//// Runs dream_model over sqlc's PostgreSQL end-to-end test corpus on one
//// PostgreSQL version, the same way as the proof of concept's
//// `corpus.py`.
////
//// For every case: load the schema into a new database, split the query
//// files into named queries, rewrite sqlc's named parameters to `$n`, and
//// analyze each query. Then run each analyzed query four times: on the
//// empty tables, and after each of three fills with random rows (NULL in
//// the columns that allow it, foreign keys not checked). A finding is a
//// column typed never NULL that returns NULL, or an analysis that fails
//// for a reason other than PostgreSQL rejecting the query.
////
//// The counts are the ones of the proof of concept's `corpus-NN.json`.
//// `write_report` writes them to `build/corpus-results/corpus-NN.json`.

import corpus/sqlc.{type Case}
import dream_model/nullability.{type Analysis}
import dream_model/nullability/reason
import dream_model/postgres/tree
import dream_model/postgres/wire
import fixtures/servers
import fuzz/random.{type Random}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The database of the corpus run on each server.
pub const database = "corpus_check"

/// The counts of a corpus run.
pub type Stats {
  Stats(
    cases: Int,
    schema_failed: Int,
    queries: Int,
    skipped_parameters: Int,
    rejected_by_postgres: Int,
    analyzed: Int,
    analysis_crashes: Int,
    columns: Int,
    table_columns: Int,
    table_not_null: Int,
    table_option: Int,
    computed: Int,
    executions: Int,
    rows: Int,
    breaks: Int,
    parameters: Int,
    optional_parameters: Int,
    timeouts: Int,
  )
}

/// What a corpus run found.
pub type Report {
  Report(
    version: Int,
    stats: Stats,
    reasons: Dict(String, Int),
    findings: List(String),
  )
}

type State {
  State(report: Report, random: Random)
}

type Analyzed {
  Analyzed(name: String, sql: String, analysis: Analysis)
}

const parameter_values = [
  #(16, "true"),
  #(20, "1"),
  #(21, "1"),
  #(23, "1"),
  #(25, "a"),
  #(1043, "a"),
  #(1700, "1"),
  #(701, "1.5"),
  #(700, "1.5"),
  #(1114, "2026-01-01"),
  #(1184, "2026-01-01"),
  #(1082, "2026-01-01"),
  #(2950, "00000000-0000-0000-0000-000000000001"),
  #(114, "{}"),
  #(3802, "{}"),
]

const column_values = [
  #("int2", ["1", "2", "3"]),
  #("int4", ["1", "2", "3"]),
  #("int8", ["1", "2", "3"]),
  #("numeric", ["1", "2.5"]),
  #("float4", ["1.5"]),
  #("float8", ["1.5"]),
  #("text", ["'a'", "'b'"]),
  #("varchar", ["'a'", "'b'"]),
  #("bpchar", ["'a'"]),
  #("bool", ["true", "false"]),
  #("timestamp", ["now()"]),
  #("timestamptz", ["now()"]),
  #("date", ["current_date"]),
  #("uuid", ["gen_random_uuid()"]),
  #("json", ["'{}'"]),
  #("jsonb", ["'{}'"]),
  #("bytea", ["'\\x00'"]),
  #("citext", ["'a'"]),
  #("interval", ["'1 day'"]),
  #("inet", ["'127.0.0.1'"]),
  #("time", ["now()"]),
  #("money", ["1"]),
]

const columns_sql =
  "select c.relname, a.attname, t.typname, a.attnotnull, t.typtype, a.atttypid, n.nspname, coalesce(a.attgenerated, '') from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace join pg_type t on t.oid = a.atttypid where c.relkind in ('r','p') and a.attnum > 0 and not a.attisdropped and n.nspname not in ('pg_catalog','information_schema','pg_toast') order by c.oid, a.attnum"

/// Runs the corpus on the server of a version, and drops its database at
/// the end. Fails when the corpus is not in build/corpus.
pub fn run(version: Int) -> Result(Report, String) {
  use cases <- result.try(sqlc.load_cases())
  let empty =
    Report(
      version:,
      stats: Stats(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
      reasons: dict.new(),
      findings: [],
    )
  let state =
    list.fold(cases, State(empty, random.new(7)), fn(state, corpus_case) {
      run_case(state, version, corpus_case)
    })
  let _ = recreate_database(version, False)
  Ok(state.report)
}

fn recreate_database(version: Int, create: Bool) -> Result(Nil, String) {
  let admin = servers.connect(version, servers.default_database)
  let done = {
    use _ <- result.try(wire.simple_query(
      admin,
      "drop database if exists " <> database <> " with (force)",
    ))
    case create {
      // FILE_COPY does not write the template database into the WAL, so
      // the many databases of a run do not fill the disk with WAL.
      True ->
        wire.simple_query(
          admin,
          "create database " <> database <> " strategy = file_copy",
        )
      False -> Ok([])
    }
  }
  let _ = wire.close(admin)
  done |> result.replace(Nil) |> result.map_error(wire.error_to_string)
}

fn connect_with_timeout(version: Int) -> Result(wire.Connection, String) {
  wire.parse_url(servers.url(version, database))
  |> result.map(fn(config) {
    wire.Config(..config, options: "-c statement_timeout=3000")
  })
  |> result.try(wire.connect)
  |> result.map_error(wire.error_to_string)
}

fn update_stats(state: State, change: fn(Stats) -> Stats) -> State {
  State(
    ..state,
    report: Report(..state.report, stats: change(state.report.stats)),
  )
}

fn add_finding(state: State, finding: String) -> State {
  State(
    ..state,
    report: Report(
      ..state.report,
      findings: list.append(state.report.findings, [finding]),
    ),
  )
}

fn run_case(state: State, version: Int, corpus_case: Case) -> State {
  let state =
    update_stats(state, fn(stats) { Stats(..stats, cases: stats.cases + 1) })
  let opened = {
    use Nil <- result.try(recreate_database(version, True))
    connect_with_timeout(version)
  }
  case opened {
    Error(message) ->
      add_finding(state, corpus_case.directory <> ": " <> message)
    Ok(connection) -> {
      let state = load_schema(state, version, connection, corpus_case)
      let _ = wire.close(connection)
      state
    }
  }
}

fn load_schema(
  state: State,
  version: Int,
  connection: wire.Connection,
  corpus_case: Case,
) -> State {
  case wire.simple_query(connection, corpus_case.schema) {
    Error(_) ->
      update_stats(state, fn(stats) {
        Stats(..stats, schema_failed: stats.schema_failed + 1)
      })
    Ok(_) -> run_queries(state, version, connection, corpus_case)
  }
}

fn run_queries(
  state: State,
  version: Int,
  connection: wire.Connection,
  corpus_case: Case,
) -> State {
  case nullability.connect(servers.url(version, database)) {
    Error(error) ->
      add_finding(
        state,
        corpus_case.directory
          <> ": the analyzer did not connect: "
          <> nullability.error_to_string(error),
      )
    Ok(analyzer) -> {
      let #(state, analyzed, analyzer) =
        sqlc.split_queries(corpus_case.queries)
        |> list.fold(#(state, [], analyzer), fn(folded, named) {
          let #(state, analyzed, analyzer) = folded
          analyze_query(state, analyzer, corpus_case, named, analyzed)
        })
      let _ = nullability.close(analyzer)
      let analyzed = list.reverse(analyzed)
      random.numbers(0, 3)
      |> list.fold(state, fn(state, round) {
        run_round(state, connection, corpus_case, analyzed, round)
      })
    }
  }
}

/// Runs every analyzed query once. Round 0 runs on the empty tables; each
/// later round first adds random rows.
fn run_round(
  state: State,
  connection: wire.Connection,
  corpus_case: Case,
  analyzed: List(Analyzed),
  round: Int,
) -> State {
  let _ =
    wire.simple_query(connection, "set session_replication_role = replica")
  let state = case round > 0 {
    True -> fill(state, connection)
    False -> state
  }
  list.fold(analyzed, state, fn(state, query) {
    execute(state, connection, corpus_case, query)
  })
}

fn analyze_query(
  state: State,
  analyzer: nullability.Analyzer,
  corpus_case: Case,
  named: #(String, String),
  analyzed: List(Analyzed),
) -> #(State, List(Analyzed), nullability.Analyzer) {
  let #(name, body) = named
  let state =
    update_stats(state, fn(stats) { Stats(..stats, queries: stats.queries + 1) })
  case sqlc.rewrite_parameters(body) {
    Error(Nil) -> #(
      update_stats(state, fn(stats) {
        Stats(..stats, skipped_parameters: stats.skipped_parameters + 1)
      }),
      analyzed,
      analyzer,
    )
    Ok(sql) -> {
      let #(state, found, analyzer) =
        decide(state, analyzer, corpus_case, name, sql)
      #(state, list.append(found, analyzed), analyzer)
    }
  }
}

fn decide(
  state: State,
  analyzer: nullability.Analyzer,
  corpus_case: Case,
  name: String,
  sql: String,
) -> #(State, List(Analyzed), nullability.Analyzer) {
  case nullability.analyze(analyzer, sql) {
    Ok(#(analysis, analyzer)) -> #(
      count_analysis(state, analysis),
      [Analyzed(name, sql, analysis)],
      analyzer,
    )
    Error(nullability.DatabaseFailed(wire.ServerError(_)))
    | Error(nullability.TreeFailed(tree.QueryFailed(wire.ServerError(_)))) -> #(
      update_stats(state, fn(stats) {
        Stats(..stats, rejected_by_postgres: stats.rejected_by_postgres + 1)
      }),
      [],
      analyzer,
    )
    Error(error) -> #(
      update_stats(state, fn(stats) {
        Stats(..stats, analysis_crashes: stats.analysis_crashes + 1)
      })
        |> add_finding(
          corpus_case.directory
          <> " "
          <> name
          <> ": the analysis crashed: "
          <> nullability.error_to_string(error)
          <> "\n  query: "
          <> sql,
        ),
      [],
      analyzer,
    )
  }
}

fn count_analysis(state: State, analysis: Analysis) -> State {
  let columns = analysis.columns
  let table = list.filter(columns, fn(column) { column.origin == reason.Table })
  let table_not_null = list.count(table, fn(column) { column.not_null })
  let optional =
    list.count(analysis.parameters, fn(parameter) { parameter.optional })
  let reasons =
    list.fold(columns, state.report.reasons, fn(reasons, column) {
      dict.upsert(
        reasons,
        reason.column_reason_to_string(column.reason),
        fn(count) { option.unwrap(count, 0) + 1 },
      )
    })
  let state = State(..state, report: Report(..state.report, reasons:))
  update_stats(state, fn(stats) {
    Stats(
      ..stats,
      analyzed: stats.analyzed + 1,
      columns: stats.columns + list.length(columns),
      table_columns: stats.table_columns + list.length(table),
      table_not_null: stats.table_not_null + table_not_null,
      table_option: stats.table_option + list.length(table) - table_not_null,
      computed: stats.computed + list.length(columns) - list.length(table),
      parameters: stats.parameters + list.length(analysis.parameters),
      optional_parameters: stats.optional_parameters + optional,
    )
  })
}

fn execute(
  state: State,
  connection: wire.Connection,
  corpus_case: Case,
  query: Analyzed,
) -> State {
  let parameters =
    list.map(query.analysis.parameters, fn(parameter) {
      list.key_find(parameter_values, parameter.type_oid)
      |> result.unwrap("1")
      |> Some
    })
  let ran = {
    use _ <- result.try(wire.simple_query(connection, "begin"))
    wire.execute(connection, query.sql, parameters)
  }
  let _ = wire.simple_query(connection, "rollback")
  case ran {
    Error(error) -> count_timeout(state, error_code(error))
    Ok(rows) -> check_rows(state, corpus_case, query, rows)
  }
}

/// A run that the statement timeout stopped is counted; a run that fails
/// for another reason is skipped, as in the proof of concept.
fn count_timeout(state: State, code: String) -> State {
  case code {
    "57014" ->
      update_stats(state, fn(stats) {
        Stats(..stats, timeouts: stats.timeouts + 1)
      })
    _ -> state
  }
}

fn error_code(error: wire.WireError) -> String {
  case error {
    wire.ServerError(fields) -> wire.get_field(fields, "C") |> result.unwrap("")
    _ -> ""
  }
}

fn check_rows(
  state: State,
  corpus_case: Case,
  query: Analyzed,
  rows: List(List(Option(String))),
) -> State {
  let state =
    update_stats(state, fn(stats) {
      Stats(
        ..stats,
        executions: stats.executions + 1,
        rows: stats.rows + list.length(rows),
      )
    })
  list.fold(rows, state, fn(state, row) {
    let broken =
      list.zip(query.analysis.columns, row)
      |> list.find(fn(pair) { pair.1 == None && { pair.0 }.not_null })
    case broken {
      Error(Nil) -> state
      Ok(#(column, _)) ->
        update_stats(state, fn(stats) {
          Stats(..stats, breaks: stats.breaks + 1)
        })
        |> add_finding(
          corpus_case.directory
          <> " "
          <> query.name
          <> ": '"
          <> column.name
          <> "' typed never NULL ("
          <> reason.column_reason_to_string(column.reason)
          <> ") but NULL came back\n  query: "
          <> query.sql,
        )
    }
  })
}

// --- Random rows -----------------------------------------------------------

type FillColumn {
  FillColumn(
    name: String,
    type_name: String,
    not_null: Bool,
    type_kind: String,
    type_oid: String,
    generated: Bool,
  )
}

/// Adds 1 to 4 random rows to every table; a row that PostgreSQL rejects
/// is left out.
fn fill(state: State, connection: wire.Connection) -> State {
  let rows = wire.simple_query(connection, columns_sql) |> result.unwrap([])
  let tables = group_columns(rows)
  let #(count, generator) = random.between(state.random, 1, 4)
  let generator =
    list.fold(tables, generator, fn(generator, table) {
      let #(#(schema_name, table_name), columns) = table
      random.numbers(1, count)
      |> list.fold(generator, fn(generator, _) {
        let #(statement, generator) =
          insert_row(generator, connection, schema_name, table_name, columns)
        let _ = wire.simple_query(connection, statement)
        generator
      })
    })
  State(..state, random: generator)
}

fn group_columns(
  rows: List(List(Option(String))),
) -> List(#(#(String, String), List(FillColumn))) {
  rows
  |> list.filter_map(fn(row) {
    case list.map(row, option.unwrap(_, "")) {
      [
        table,
        name,
        type_name,
        not_null,
        type_kind,
        type_oid,
        schema_name,
        generated,
      ] ->
        Ok(#(
          #(schema_name, table),
          FillColumn(
            name:,
            type_name:,
            not_null: not_null == "t",
            type_kind:,
            type_oid:,
            generated: generated != "",
          ),
        ))
      _ -> Error(Nil)
    }
  })
  |> list.fold([], fn(tables, pair) {
    let #(key, column) = pair
    case list.key_find(tables, key) {
      Ok(columns) -> list.key_set(tables, key, list.append(columns, [column]))
      Error(Nil) -> list.append(tables, [#(key, [column])])
    }
  })
}

fn insert_row(
  generator: Random,
  connection: wire.Connection,
  schema_name: String,
  table_name: String,
  columns: List(FillColumn),
) -> #(String, Random) {
  let #(pairs, generator) =
    columns
    |> list.filter(fn(column) { !column.generated })
    |> list.fold(#([], generator), fn(state, column) {
      let #(pairs, generator) = state
      let #(value, generator) = column_value(generator, connection, column)
      #([#(quote(column.name), value), ..pairs], generator)
    })
  let pairs = list.reverse(pairs)
  #(
    "insert into "
      <> quote(schema_name)
      <> "."
      <> quote(table_name)
      <> " ("
      <> string.join(list.map(pairs, fn(pair) { pair.0 }), ", ")
      <> ") values ("
      <> string.join(list.map(pairs, fn(pair) { pair.1 }), ", ")
      <> ")",
    generator,
  )
}

fn quote(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

fn column_value(
  generator: Random,
  connection: wire.Connection,
  column: FillColumn,
) -> #(String, Random) {
  let #(value, generator) = case
    column.type_kind,
    string.starts_with(column.type_name, "_")
  {
    "e", _ -> enum_value(generator, connection, column.type_oid)
    _, True -> #("'{}'", generator)
    _, False ->
      random.choose(
        generator,
        list.key_find(column_values, column.type_name)
          |> result.unwrap(["null"]),
        "null",
      )
  }
  let #(null, generator) = random.chance(generator, 0.4)
  case !column.not_null && null {
    True -> #("null", generator)
    False -> #(value, generator)
  }
}

fn enum_value(
  generator: Random,
  connection: wire.Connection,
  type_oid: String,
) -> #(String, Random) {
  let labels =
    wire.simple_query(
      connection,
      "select enumlabel from pg_enum where enumtypid = " <> type_oid,
    )
    |> result.unwrap([])
    |> list.filter_map(fn(row) {
      case row {
        [Some(label)] -> Ok("'" <> string.replace(label, "'", "''") <> "'")
        _ -> Error(Nil)
      }
    })
  random.choose(generator, labels, "null")
}

// --- Report ----------------------------------------------------------------

/// Returns the counts as `name value` pairs, in the order of the proof of
/// concept's `corpus-NN.json`.
pub fn stats_pairs(stats: Stats) -> List(#(String, Int)) {
  [
    #("cases", stats.cases),
    #("schema_failed", stats.schema_failed),
    #("queries", stats.queries),
    #("skipped_params", stats.skipped_parameters),
    #("rejected_by_postgres", stats.rejected_by_postgres),
    #("analyzed", stats.analyzed),
    #("analysis_crashes", stats.analysis_crashes),
    #("columns", stats.columns),
    #("table_columns", stats.table_columns),
    #("table_not_null", stats.table_not_null),
    #("table_option", stats.table_option),
    #("computed", stats.computed),
    #("executions", stats.executions),
    #("rows", stats.rows),
    #("breaks", stats.breaks),
    #("params", stats.parameters),
    #("optional_params", stats.optional_parameters),
    #("timeouts", stats.timeouts),
  ]
}

/// Returns the counts on one line, `name value, ...`.
pub fn summary(report: Report) -> String {
  "corpus on PostgreSQL "
  <> int.to_string(report.version)
  <> ": "
  <> stats_pairs(report.stats)
  |> list.map(fn(pair) { pair.0 <> " " <> int.to_string(pair.1) })
  |> string.join(", ")
}

/// Writes the report as JSON to `build/corpus-results/corpus-NN.json`.
pub fn write_report(report: Report) -> Result(Nil, simplifile.FileError) {
  let directory = "build/corpus-results"
  let stats =
    stats_pairs(report.stats)
    |> list.map(fn(pair) {
      json_string(pair.0) <> ": " <> int.to_string(pair.1)
    })
  let reasons =
    dict.to_list(report.reasons)
    |> list.sort(fn(left, right) { int.compare(right.1, left.1) })
    |> list.map(fn(pair) {
      json_string(pair.0) <> ": " <> int.to_string(pair.1)
    })
  let findings = list.map(report.findings, json_string)
  let text =
    "{\n \"stats\": {\n  "
    <> string.join(stats, ",\n  ")
    <> "\n },\n \"reasons\": {\n  "
    <> string.join(reasons, ",\n  ")
    <> "\n },\n \"findings\": [\n  "
    <> string.join(findings, ",\n  ")
    <> "\n ]\n}\n"
  use Nil <- result.try(simplifile.create_directory_all(directory))
  simplifile.write(
    directory <> "/corpus-" <> int.to_string(report.version) <> ".json",
    text,
  )
}

fn json_string(text: String) -> String {
  let escaped =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\r", "\\r")
    |> string.replace("\t", "\\t")
  "\"" <> escaped <> "\""
}
