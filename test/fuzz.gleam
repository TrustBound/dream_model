//// The long fuzz run, for the nightly CI workflow and for runs by hand:
////
//// ```sh
//// gleam run -m fuzz -- --seed 1234 --schemas 100 --queries 60
//// ```
////
//// It runs on each version that `DREAM_MODEL_TEST_VERSIONS` picks (the
//// default is 16 to 19). With no `--seed`, it picks a new seed. It prints
//// the seed first, so that a failure can be replayed with the same seed,
//// then one line of counts for each version and every failure. It exits
//// with status 1 when it finds a failure.
////
//// This module is under test/, so it is not part of the published
//// package.

import fixtures/servers.{versions}
import fuzz/run.{type Report, Settings}
import gleam/int.{parse, to_string}
import gleam/io.{println, println_error}
import gleam/list.{each, flat_map, fold, length, map}
import gleam/result.{replace_error, try}
import gleam/string.{join}

@external(erlang, "dream_model_test_ffi", "get_arguments")
fn get_arguments() -> List(String)

@external(erlang, "dream_model_test_ffi", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "os", "system_time")
fn system_time() -> Int

type Options {
  Options(seed: Int, schemas: Int, queries: Int)
}

pub fn main() -> Nil {
  case parse_options(get_arguments(), default_options()) {
    Error(message) -> {
      println_error(message)
      println_error(
        "Usage: gleam run -m fuzz -- [--seed N] [--schemas S] [--queries Q]",
      )
      halt(2)
    }
    Ok(options) -> run_versions(options)
  }
}

fn default_options() -> Options {
  Options(seed: system_time() % 1_000_000_000, schemas: 100, queries: 60)
}

fn parse_options(
  arguments: List(String),
  options: Options,
) -> Result(Options, String) {
  case arguments {
    [] -> Ok(options)
    [name, value, ..rest] -> {
      use number <- try(
        parse(value)
        |> replace_error("The value of " <> name <> " is not a number"),
      )
      use options <- try(set_option(options, name, number))
      parse_options(rest, options)
    }
    [name] -> Error("The option " <> name <> " has no value")
  }
}

fn set_option(
  options: Options,
  name: String,
  number: Int,
) -> Result(Options, String) {
  case name {
    "--seed" -> Ok(Options(..options, seed: number))
    "--schemas" -> Ok(Options(..options, schemas: number))
    "--queries" -> Ok(Options(..options, queries: number))
    _ -> Error("Unknown option " <> name)
  }
}

fn run_versions(options: Options) -> Nil {
  println(
    "fuzz seed "
    <> to_string(options.seed)
    <> " (replay: gleam run -m fuzz -- --seed "
    <> to_string(options.seed)
    <> " --schemas "
    <> to_string(options.schemas)
    <> " --queries "
    <> to_string(options.queries)
    <> ")",
  )
  let reports =
    map(versions(), fn(version) {
      let started = monotonic_milliseconds()
      let report =
        run.run(Settings(
          version:,
          seed: options.seed,
          schemas: options.schemas,
          queries: options.queries,
        ))
      print_report(report, monotonic_milliseconds() - started)
      report
    })
  let failures = flat_map(reports, fn(report) { report.failures })
  let analyzed = fold(reports, 0, fn(sum, report) { sum + report.analyzed })
  println(
    "total: "
    <> to_string(analyzed)
    <> " queries analyzed, "
    <> to_string(length(failures))
    <> " failures, seed "
    <> to_string(options.seed),
  )
  case failures {
    [] -> halt(0)
    _ -> halt(1)
  }
}

fn print_report(report: Report, milliseconds: Int) -> Nil {
  println(
    "PostgreSQL "
    <> to_string(report.settings.version)
    <> ": "
    <> join(
      [
        "schemas " <> to_string(report.settings.schemas),
        "generated " <> to_string(report.generated),
        "rejected_by_postgres " <> to_string(report.rejected_by_postgres),
        "analyzed " <> to_string(report.analyzed),
        "columns " <> to_string(report.columns),
        "not_null_columns " <> to_string(report.not_null_columns),
        "optional_parameters " <> to_string(report.optional_parameters),
        "run_failed " <> to_string(report.run_failed),
        "failures " <> to_string(length(report.failures)),
        "seconds " <> to_string(milliseconds / 1000),
      ],
      ", ",
    ),
  )
  each(report.failures, println)
}
