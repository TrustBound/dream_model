//// sqlc's PostgreSQL end-to-end test queries on each PostgreSQL version,
//// as in the proof of concept's `corpus.py`. Run
//// `sh scripts/fetch-corpus.sh` first: without the corpus in build/corpus
//// the test fails.
////
//// The counts of each run are in build/corpus-results/corpus-NN.json.

import corpus/run.{summary, write_report}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/int.{to_string}
import gleam/io.{println}
import gleam/result.{map}

/// The corpus test on one PostgreSQL version.
pub fn tests(version: Int) -> TestSuite {
  describe("sqlc corpus on PostgreSQL " <> to_string(version), [
    it("finds no wrong never-NULL type and no analysis crash", fn() {
      // Arrange
      let version = version

      // Act
      let findings =
        run.run(version)
        |> map(fn(report) {
          let _ = write_report(report)
          println(summary(report))
          report.findings
        })

      // Assert
      findings
      |> should
      |> be_equal(Ok([]))
      |> or_fail_with(
        "Expected no findings in the sqlc corpus on PostgreSQL "
        <> to_string(version),
      )
    }),
  ])
}
