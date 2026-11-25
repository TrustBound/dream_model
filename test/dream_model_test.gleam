//// The test run. The database tests need the PostgreSQL servers of
//// docker-compose.yml (`make db-up`). Before the tests, this checks that
//// each server answers and creates the attack database on each version
//// that `DREAM_MODEL_TEST_VERSIONS` picks; the run stops with one message
//// when that fails.

import dream_model/nullability/attack_test
import dream_model/nullability/hint_test
import dream_model/nullability/reason_test
import dream_model/nullability/rules_test
import dream_model/nullability_test
import dream_model/postgres/catalog_test
import dream_model/postgres/node_test
import dream_model/postgres/scram_test
import dream_model/postgres/tree_test
import dream_model/postgres/wire_test
import dream_test/coverage
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import fixtures/attack_database
import fixtures/servers
import gleam/io
import gleam/list
import gleam/result

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

pub fn main() -> Nil {
  let versions = servers.versions()
  let prepared =
    list.try_each([15, ..versions], servers.check_reachable)
    |> result.try(fn(_) { list.try_each(versions, attack_database.create) })
  case prepared {
    Ok(Nil) -> run_tests(versions)
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
  }
}

fn run_tests(versions: List(Int)) -> Nil {
  let coverage_config =
    coverage.new()
    |> coverage.show_missing()
    |> coverage.json_path("build/coverage/coverage.json")
  let coverage_config = case versions == servers.default_versions {
    True -> coverage.minimum_percent(coverage_config, 100.0)
    False -> coverage_config
  }
  let first_version = list.first(versions) |> result.unwrap(16)
  let unit_suites = [
    node_test.tests(),
    scram_test.tests(),
    hint_test.tests(),
    reason_test.tests(),
    wire_test.tests(first_version),
    tree_test.tests(first_version),
    nullability_test.tests(first_version),
  ]
  let version_suites =
    list.flat_map(versions, fn(version) {
      [
        catalog_test.tests(version),
        rules_test.tests(version),
        attack_test.tests(version),
      ]
    })
  runner.new(list.append(unit_suites, version_suites))
  |> runner.default_timeout_ms(120_000)
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.coverage(coverage_config)
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}
