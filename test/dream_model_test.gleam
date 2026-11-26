//// The test run. The database tests need the PostgreSQL servers of
//// docker-compose.yml (`make db-up`). Before the tests, this checks that
//// each server answers and creates the attack database and the generator
//// databases on each version that `DREAM_MODEL_TEST_VERSIONS` picks; the
//// run stops with one message when that fails.
////
//// The tests are in groups: one group of the tests that are the same on
//// every version, and one group for each version. Each version has its own
//// server and databases, so the groups run at the same time, each in its
//// own run. The suites of one group run one after the other. The line
//// coverage is measured over all the groups together.
////
//// Environment variables:
////
//// - `DREAM_MODEL_TEST_VERSIONS`: the versions, for example "16 18".
//// - `DREAM_MODEL_TEST_DATABASE_PREFIX`: a prefix for the name of each
////   database that the tests create (see `fixtures/servers`).
//// - `DREAM_MODEL_TEST_MODULES`: only the suites of these test modules, for
////   example "attack_test rules_test". The mutation test uses it. The run
////   then measures no coverage.
//// - `DREAM_MODEL_TEST_COVERAGE=off`: measure no coverage.
////
//// With arguments after `--`, for example `gleam test -- --only ...`, the
//// groups run one after the other in one run, so that `--only` sees every
//// test.
////
//// Each group writes "Finished: <group>, <n> tests, <n> failed, failed
//// modules: [<modules>]" at its end. The mutation test reads that line.

import dream_model/command_test
import dream_model/corpus_test
import dream_model/docs_test
import dream_model/e2e_test
import dream_model/fuzz_test
import dream_model/generator/fingerprint_test
import dream_model/generator/gleam_type_test
import dream_model/generator/model_test
import dream_model/generator/name_test
import dream_model/generator/query_hint_test
import dream_model/generator/query_test
import dream_model/generator/unqualified_test
import dream_model/nullability/attack_test
import dream_model/nullability/hint_test
import dream_model/nullability/reason_test
import dream_model/nullability/rules_test
import dream_model/nullability_test
import dream_model/postgres/catalog_test
import dream_model/postgres/node_test
import dream_model/postgres/parameter_column_test
import dream_model/postgres/scram_test
import dream_model/postgres/tree_test
import dream_model/postgres/wire_test
import dream_test/coverage
import dream_test/matchers.{fail_with, succeed}
import dream_test/parallel
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner.{type RunBuilder}
import dream_test/suite.{type TestSuite}
import dream_test/types
import dream_test/unit.{describe, it}
import fixtures/attack_database
import fixtures/model_database
import fixtures/servers
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "dream_model_test_ffi", "read_environment_variable")
fn read_environment_variable(name: String) -> Result(String, Nil)

@external(erlang, "dream_model_test_ffi", "get_arguments")
fn get_arguments() -> List(String)

/// A suite of a test module: the same on every version, or one for each
/// version.
type Entry {
  Unit(module: String, suite: fn(Int) -> TestSuite)
  PerVersion(module: String, suite: fn(Int) -> TestSuite)
  EndToEnd(module: String, suite: fn(Int) -> TestSuite)
}

/// Each suite, in the order of the run. A `Unit` suite gets the first
/// version: some of them connect to its server.
fn entries() -> List(Entry) {
  [
    Unit("node_test", fn(_) { node_test.tests() }),
    Unit("scram_test", fn(_) { scram_test.tests() }),
    Unit("hint_test", fn(_) { hint_test.tests() }),
    Unit("query_hint_test", fn(_) { query_hint_test.tests() }),
    Unit("name_test", fn(_) { name_test.tests() }),
    Unit("unqualified_test", fn(_) { unqualified_test.tests() }),
    Unit("reason_test", fn(_) { reason_test.tests() }),
    Unit("command_test", fn(_) { command_test.unit_tests() }),
    Unit("wire_test", wire_test.tests),
    Unit("tree_test", tree_test.tests),
    Unit("nullability_test", nullability_test.tests),
    PerVersion("catalog_test", catalog_test.tests),
    PerVersion("rules_test", rules_test.tests),
    PerVersion("attack_test", attack_test.tests),
    PerVersion("gleam_type_test", gleam_type_test.tests),
    PerVersion("parameter_column_test", parameter_column_test.tests),
    PerVersion("query_test", query_test.tests),
    PerVersion("fingerprint_test", fingerprint_test.tests),
    PerVersion("model_test", model_test.tests),
    PerVersion("command_test", command_test.tests),
    PerVersion("docs_test", docs_test.tests),
    PerVersion("fuzz_test", fuzz_test.tests),
    PerVersion("corpus_test", corpus_test.tests),
    EndToEnd("e2e_test", e2e_test.tests),
  ]
}

/// The suites of a group, each with the name of its test module, and the
/// suites of the group that run one test at a time.
type Group {
  Group(
    name: String,
    suites: List(#(String, TestSuite)),
    one_at_a_time: List(#(String, TestSuite)),
  )
}

pub fn main() -> Nil {
  let versions = servers.versions()
  let selected = select(entries())
  let groups = make_groups(selected, versions)
  let needs_databases =
    list.any(selected, fn(entry) {
      case entry {
        Unit(..) -> False
        PerVersion(..) | EndToEnd(..) -> True
      }
    })
  let prepared = {
    use Nil <- result.try(list.try_each(
      [15, ..versions],
      servers.check_reachable,
    ))
    case needs_databases {
      True -> {
        use Nil <- result.try(list.try_each(versions, attack_database.create))
        list.try_each(versions, model_database.create)
      }
      False -> Ok(Nil)
    }
  }
  case prepared {
    Ok(Nil) ->
      run_groups(
        groups,
        versions,
        read_environment_variable("DREAM_MODEL_TEST_MODULES") != Error(Nil),
      )
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
  }
}

/// The entries of the modules of `DREAM_MODEL_TEST_MODULES`, or every entry.
/// Stops the run when a name is not the name of a test module.
fn select(all: List(Entry)) -> List(Entry) {
  case read_environment_variable("DREAM_MODEL_TEST_MODULES") {
    Error(Nil) -> all
    Ok(text) -> {
      let names =
        string.split(text, " ")
        |> list.filter(fn(name) { name != "" })
      let known = list.map(all, fn(entry) { entry.module })
      case list.filter(names, fn(name) { !list.contains(known, name) }) {
        [] -> list.filter(all, fn(entry) { list.contains(names, entry.module) })
        unknown -> {
          io.println_error(
            "DREAM_MODEL_TEST_MODULES names no test module: "
            <> string.join(unknown, " "),
          )
          halt(1)
          []
        }
      }
    }
  }
}

fn make_groups(selected: List(Entry), versions: List(Int)) -> List(Group) {
  let first_version = list.first(versions) |> result.unwrap(16)
  let unit_suites =
    list.filter_map(selected, fn(entry) {
      case entry {
        Unit(module:, suite:) -> Ok(#(module, suite(first_version)))
        _ -> Error(Nil)
      }
    })
  let version_groups =
    list.map(versions, fn(version) {
      let suites =
        list.filter_map(selected, fn(entry) {
          case entry {
            PerVersion(module:, suite:) -> Ok(#(module, suite(version)))
            _ -> Error(Nil)
          }
        })
      // The end-to-end tests of one version share a copy of the app, so
      // they run one at a time.
      let one_at_a_time =
        list.filter_map(selected, fn(entry) {
          case entry {
            EndToEnd(module:, suite:) -> Ok(#(module, suite(version)))
            _ -> Error(Nil)
          }
        })
      Group("PostgreSQL " <> int.to_string(version), suites, one_at_a_time)
    })
  [Group("the tests of every version", unit_suites, []), ..version_groups]
  |> list.filter(fn(group) { group.suites != [] || group.one_at_a_time != [] })
}

fn suites_of(pairs: List(#(String, TestSuite))) -> List(TestSuite) {
  list.map(pairs, fn(pair) { pair.1 })
}

/// Adds the suites of a group to a run, with the settings of the run.
fn add_group(builder: RunBuilder, group: Group) -> RunBuilder {
  builder
  |> runner.add_suites(suites_of(group.suites))
  |> runner.add_suites_with_config(
    parallel.ParallelConfig(max_concurrency: 1, default_timeout_ms: 300_000),
    suites_of(group.one_at_a_time),
  )
}

/// Runs the groups. Without arguments after `--`, each group runs in a run
/// of its own, and the runs go at the same time. With arguments, the
/// groups run one after the other in one run.
fn run_groups(groups: List(Group), versions: List(Int), filtered: Bool) -> Nil {
  let coverage_off =
    filtered
    || read_environment_variable("DREAM_MODEL_TEST_COVERAGE") == Ok("off")
  let builder = case get_arguments() {
    [_, ..] ->
      list.fold(groups, runner.new([]), add_group)
      |> runner.default_timeout_ms(120_000)
      |> runner.progress_reporter(progress.new())
      |> runner.results_reporters([bdd.new()])
    [] ->
      runner.new([describe("the test groups", list.map(groups, group_test))])
      |> runner.max_concurrency(list.length(groups))
      |> runner.default_timeout_ms(3_600_000)
  }
  let builder = case coverage_off {
    True -> builder
    False -> runner.coverage(builder, coverage_config(versions))
  }
  builder
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}

/// A test that runs the suites of a group in a run of its own, and fails
/// when a test of the group fails. The run of the group writes its own
/// report. The last line names the test modules with a failed test.
fn group_test(group: Group) {
  it(group.name, fn() {
    io.println("Started: " <> group.name)
    let report =
      add_group(runner.new([]), group)
      |> runner.default_timeout_ms(120_000)
      |> runner.results_reporters([bdd.new()])
      |> runner.with_arguments([])
      |> runner.run()
    let failures =
      types.report_tests(report)
      |> list.filter(fn(result) { types.is_failure(result.status) })
    let modules =
      list.flat_map(failures, fn(result) {
        let suite_name = list.first(result.groups) |> result.unwrap("")
        list.append(group.suites, group.one_at_a_time)
        |> list.filter(fn(pair) { suite.name(pair.1) == suite_name })
        |> list.map(fn(pair) { pair.0 })
      })
      |> list.unique
    let count = int.to_string(list.length(failures))
    io.println(
      "Finished: "
      <> group.name
      <> ", "
      <> int.to_string(list.length(types.report_tests(report)))
      <> " tests, "
      <> count
      <> " failed, failed modules: ["
      <> string.join(modules, " ")
      <> "]",
    )
    case types.failed(report) {
      False -> Ok(succeed())
      True ->
        Ok(fail_with(
          group.name
          <> ": "
          <> count
          <> " failed; the report of the group is above",
        ))
    }
  })
}

fn coverage_config(versions: List(Int)) -> coverage.CoverageConfig {
  let config =
    coverage.new()
    |> coverage.show_missing()
    |> coverage.json_path("build/coverage/coverage.json")
  case versions == servers.default_versions {
    True -> coverage.minimum_percent(config, 100.0)
    False -> config
  }
}
