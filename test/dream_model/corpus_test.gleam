//// sqlc's PostgreSQL end-to-end test queries on each PostgreSQL version,
//// as in the proof of concept's `corpus.py`. Run
//// `sh scripts/fetch-corpus.sh` first: without the corpus in build/corpus
//// the test fails.
////
//// The counts of each run are in build/corpus-results/corpus-NN.json.

import corpus/run
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/int
import gleam/io
import gleam/result

/// The corpus test on one PostgreSQL version.
pub fn tests(version: Int) -> TestSuite {
  describe("sqlc corpus on PostgreSQL " <> int.to_string(version), [
    it("finds no wrong never-NULL type and no analysis crash", fn() {
      // Arrange
      let version = version

      // Act
      let findings =
        run.run(version)
        |> result.map(fn(report) {
          let _ = run.write_report(report)
          io.println(run.summary(report))
          report.findings
        })

      // Assert
      findings
      |> should
      |> be_equal(Ok([]))
      |> or_fail_with(
        "Expected no findings in the sqlc corpus on PostgreSQL "
        <> int.to_string(version),
      )
    }),
  ])
}
