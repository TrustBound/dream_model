//// The fuzzer with fixed seeds, on each PostgreSQL version: random schemas,
//// data and queries, as in the proof of concept's `fuzz.py`. The long run
//// with a new seed is `gleam run -m fuzz` (see test/fuzz.gleam).

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fuzz/run.{Settings}
import gleam/int.{to_string}
import gleam/list.{map}

/// The seeds of the normal test run.
pub const seeds = [101, 202, 303]

/// The random schemas for each seed.
pub const schemas = 15

/// The random queries for each schema.
pub const queries = 40

/// The fuzz tests on one PostgreSQL version.
pub fn tests(version: Int) -> TestSuite {
  describe(
    "fuzzer on PostgreSQL " <> to_string(version),
    map(seeds, fn(seed) {
      it("seed " <> to_string(seed) <> " finds no wrong decision", fn() {
        // Arrange
        let settings = Settings(version:, seed:, schemas:, queries:)

        // Act
        let report = run.run(settings)

        // Assert
        report.failures
        |> should
        |> be_equal([])
        |> or_fail_with(
          "Expected no failures; replay with DREAM_MODEL_TEST_VERSIONS="
          <> to_string(version)
          <> " gleam run -m fuzz -- --seed "
          <> to_string(seed)
          <> " --schemas "
          <> to_string(schemas)
          <> " --queries "
          <> to_string(queries),
        )
      })
    }),
  )
}
