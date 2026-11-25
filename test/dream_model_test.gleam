//// The test run. The database tests need the PostgreSQL servers of
//// docker-compose.yml (`make db-up`). Before the tests, this checks that
//// each server that `DREAM_MODEL_TEST_VERSIONS` picks answers; the run
//// stops with one message when one does not.

import dream_model/postgres/scram_test
import dream_model/postgres/wire_test
import dream_test/coverage
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import fixtures/servers
import gleam/io
import gleam/list
import gleam/result

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

pub fn main() -> Nil {
  let versions = servers.versions()
  let prepared = list.try_each(versions, servers.check_reachable)
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
    scram_test.tests(),
    wire_test.tests(first_version),
  ]
  runner.new(unit_suites)
  |> runner.default_timeout_ms(120_000)
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new()])
  |> runner.coverage(coverage_config)
  |> runner.exit_on_failure()
  |> runner.run()
  Nil
}
