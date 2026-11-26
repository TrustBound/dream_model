//// Runs the fuzzer on one PostgreSQL version, the same way as the proof of
//// concept's `fuzz.py`: for each random schema, it creates the schema in a
//// new database, analyzes random queries, and runs each analyzed query on
//// each data set, inside a transaction that is rolled back.
////
//// A failure is:
////
//// - a column typed never NULL that returns NULL on a data set;
//// - an `Option` parameter for which PostgreSQL rejects NULL;
//// - an analysis that fails for a reason other than PostgreSQL rejecting
////   the query (a crash of the rules);
//// - a schema that cannot be created (a fault of the fuzzer).
////
//// As in the proof of concept, a query that PostgreSQL rejects is counted
//// and skipped, and so is a query whose run fails on a data set with an
//// error that the data checks do not expect, for example a FULL JOIN
//// condition that the planner cannot run.

import dream_model/nullability.{
  type Analysis, type Analyzer, DatabaseFailed, TreeFailed, analyze,
}
import dream_model/postgres/tree.{QueryFailed}
import dream_model/postgres/wire.{type Connection, ServerError, simple_query}
import fixtures/harness.{Broken, PromiseEnforced, RunFailed, Sound, check}
import fixtures/servers.{database_name, default_database}
import fuzz/query.{type Generator, add_schema_facts, add_view, new, view}
import fuzz/random.{type Random}
import fuzz/schema.{type DataSet, type Schema, Relation}
import gleam/int.{to_string}
import gleam/list.{append, flat_map, fold, length, map, reverse, take, try_each}
import gleam/option.{type Option, Some}
import gleam/result.{map_error, replace, try}
import gleam/string.{join}

/// The size of a fuzz run.
pub type Settings {
  Settings(version: Int, seed: Int, schemas: Int, queries: Int)
}

/// What a fuzz run found.
pub type Report {
  Report(
    settings: Settings,
    generated: Int,
    rejected_by_postgres: Int,
    analyzed: Int,
    columns: Int,
    not_null_columns: Int,
    optional_parameters: Int,
    /// The analyzed queries whose run failed on a data set with an error
    /// that the data checks do not expect. They are skipped.
    run_failed: Int,
    failures: List(String),
  )
}

type Analyzed {
  Analyzed(sql: String, analysis: Analysis)
}

/// The name of the database of a fuzz run, with the prefix of
/// `servers.database_name`.
pub fn database(seed: Int) -> String {
  database_name("fuzz_" <> to_string(seed))
}

/// Runs the fuzzer, and drops its database at the end.
pub fn run(settings: Settings) -> Report {
  let empty = Report(settings, 0, 0, 0, 0, 0, 0, 0, [])
  let #(report, _) =
    random.numbers(1, settings.schemas)
    |> fold(#(empty, random.new(settings.seed)), fn(state, number) {
      let #(report, random) = state
      run_schema(report, random, number)
    })
  let _ = drop_database(settings)
  report
}

fn drop_database(settings: Settings) -> Result(Nil, String) {
  let admin = servers.connect(settings.version, default_database)
  let dropped =
    simple_query(
      admin,
      "drop database if exists " <> database(settings.seed) <> " with (force)",
    )
  let _ = wire.close(admin)
  dropped
  |> replace(Nil)
  |> map_error(wire.error_to_string)
}

fn create_database(settings: Settings) -> Result(Nil, String) {
  use Nil <- try(drop_database(settings))
  let admin = servers.connect(settings.version, default_database)
  let created =
    // FILE_COPY does not write the template database into the WAL, so the
    // many databases of a run do not fill the disk with WAL.
    simple_query(
      admin,
      "create database " <> database(settings.seed) <> " strategy = file_copy",
    )
  let _ = wire.close(admin)
  created
  |> replace(Nil)
  |> map_error(wire.error_to_string)
}

fn run_schema(
  report: Report,
  random: Random,
  number: Int,
) -> #(Report, Random) {
  let settings = report.settings
  let #(schema, random) = schema.generate(random, settings.version)
  let label =
    "PostgreSQL "
    <> to_string(settings.version)
    <> ", seed "
    <> to_string(settings.seed)
    <> ", schema "
    <> to_string(number)
  let created = {
    use Nil <- try(create_database(settings))
    let connection = servers.connect(settings.version, database(settings.seed))
    let made =
      try_each(schema.statements, fn(statement) {
        simple_query(connection, statement)
        |> map_error(fn(error) {
          statement <> ": " <> wire.error_to_string(error)
        })
      })
    case made {
      Ok(_) -> Ok(connection)
      Error(message) -> {
        let _ = wire.close(connection)
        Error(message)
      }
    }
  }
  case created {
    Error(message) -> #(
      add_failures(report, [label <> ": the schema failed: " <> message]),
      random,
    )
    Ok(connection) -> {
      let generator =
        new(random, schema.tables, settings.version)
        |> add_schema_facts(schema.column_types, schema.conflict_targets)
      let #(generator, views) = create_views(connection, generator)
      let #(report, analyzed, generator) =
        analyze_queries(report, generator, label)
      let #(data_sets, random) = schema.data_sets(generator.random, schema)
      let outcomes = map(analyzed, check_query(connection, _, data_sets))
      let failures =
        flat_map(outcomes, fn(outcome) { outcome.1 })
        |> map(fn(problem) {
          describe_failure(label, problem, schema, views, data_sets)
        })
      let run_failed = list.count(outcomes, fn(outcome) { outcome.0 })
      let _ = wire.close(connection)
      let report = Report(..report, run_failed: report.run_failed + run_failed)
      #(add_failures(report, failures), random)
    }
  }
}

fn add_failures(report: Report, failures: List(String)) -> Report {
  Report(..report, failures: append(report.failures, failures))
}

fn create_views(
  connection: Connection,
  generator: Generator,
) -> #(Generator, List(String)) {
  let #(count, random) = random.between(generator.random, 0, 2)
  let generator = query.Generator(..generator, random:)
  random.numbers(0, count - 1)
  |> take(count)
  |> fold(#(generator, []), fn(state, index) {
    let #(generator, views) = state
    let #(#(sql, columns), generator) = view(generator)
    let name = "v" <> to_string(index)
    let statement = "create view " <> name <> " as " <> sql
    case simple_query(connection, statement) {
      Ok(_) -> #(
        add_view(generator, Relation(name, columns)),
        append(views, [statement]),
      )
      Error(_) -> #(generator, views)
    }
  })
}

fn analyze_queries(
  report: Report,
  generator: Generator,
  label: String,
) -> #(Report, List(Analyzed), Generator) {
  let settings = report.settings
  let url = servers.url(settings.version, database(settings.seed))
  case nullability.connect(url) {
    Error(error) -> #(
      add_failures(report, [
        label
        <> ": the analyzer did not connect: "
        <> nullability.error_to_string(error),
      ]),
      [],
      generator,
    )
    Ok(analyzer) -> {
      let #(report, analyzed, generator, analyzer) =
        random.numbers(1, settings.queries)
        |> fold(#(report, [], generator, analyzer), fn(state, _) {
          let #(report, analyzed, generator, analyzer) = state
          let #(depth, random) = random.between(generator.random, 1, 3)
          let generator = query.Generator(..generator, random:)
          let #(sql, generator) = query.statement(generator, depth)
          let #(report, found, analyzer) =
            analyze_one(report, analyzer, sql, label)
          #(report, append(found, analyzed), generator, analyzer)
        })
      let _ = nullability.close(analyzer)
      #(report, reverse(analyzed), generator)
    }
  }
}

fn analyze_one(
  report: Report,
  analyzer: Analyzer,
  sql: String,
  label: String,
) -> #(Report, List(Analyzed), Analyzer) {
  let report = Report(..report, generated: report.generated + 1)
  case analyze(analyzer, sql) {
    Ok(#(analysis, analyzer)) -> #(
      count_analysis(report, analysis),
      [Analyzed(sql, analysis)],
      analyzer,
    )
    Error(DatabaseFailed(ServerError(_)))
    | Error(TreeFailed(QueryFailed(ServerError(_)))) -> #(
      Report(..report, rejected_by_postgres: report.rejected_by_postgres + 1),
      [],
      analyzer,
    )
    Error(error) -> #(
      add_failures(report, [
        label
        <> ": the analysis crashed: "
        <> nullability.error_to_string(error)
        <> "\n  query: "
        <> sql,
      ]),
      [],
      analyzer,
    )
  }
}

fn count_analysis(report: Report, analysis: Analysis) -> Report {
  let not_null = list.count(analysis.columns, fn(column) { column.not_null })
  let optional =
    list.count(analysis.parameters, fn(parameter) { parameter.optional })
  Report(
    ..report,
    analyzed: report.analyzed + 1,
    columns: report.columns + length(analysis.columns),
    not_null_columns: report.not_null_columns + not_null,
    optional_parameters: report.optional_parameters + optional,
  )
}

fn check_query(
  connection: Connection,
  analyzed: Analyzed,
  data_sets: List(DataSet),
) -> #(Bool, List(String)) {
  let outcome =
    check(
      connection,
      analyzed.analysis,
      "fuzz",
      analyzed.sql,
      data_sets,
      Some([base_parameters(analyzed.analysis)]),
      "select 1",
    )
  let #(run_failed, problems) = case outcome {
    Sound -> #(False, [])
    Broken(problems) -> #(False, problems)
    PromiseEnforced(message) -> #(False, [message])
    RunFailed(_) -> #(True, [])
  }
  #(
    run_failed,
    map(problems, fn(problem) { problem <> "\n  query: " <> analyzed.sql }),
  )
}

/// A value for each parameter that its type accepts: the checks run the
/// query with these values, then with NULL in place of each `Option`
/// parameter.
fn base_parameters(analysis: Analysis) -> List(Option(String)) {
  map(analysis.parameters, fn(parameter) {
    Some(base_value(parameter.type_oid))
  })
}

fn base_value(type_oid: Int) -> String {
  case type_oid {
    // timestamp
    1114 -> "2024-01-01 10:00:00"
    // int4[]
    1007 -> "{1,NULL}"
    _ -> "1"
  }
}

fn describe_failure(
  label: String,
  problem: String,
  schema: Schema,
  views: List(String),
  data_sets: List(DataSet),
) -> String {
  let data =
    map(data_sets, fn(data_set) {
      "  data " <> data_set.0 <> ": " <> data_set.1
    })
  [
    label <> ": " <> problem,
    "  schema: " <> join(append(schema.statements, views), ";\n    "),
    ..data
  ]
  |> join("\n")
}
