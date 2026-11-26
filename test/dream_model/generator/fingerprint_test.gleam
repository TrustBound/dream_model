//// Tests for `dream_model/generator/fingerprint`: the hash must equal what
//// dream_postgres's `client.schema_fingerprint` gives on each version.

import dream_model/generator/fingerprint.{text_array_literal}
import dream_model/nullability.{close, connect}
import dream_postgres/client.{from_url, schema_fingerprint}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database.{url}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/generator/fingerprint", [
    group("compute", [
      it("equals client.schema_fingerprint for two tables", fn() {
        // Arrange
        let tables = ["public.posts", "public.users"]

        // Act
        let found = compute(version, tables)

        // Assert
        found
        |> should
        |> be_equal(expected(version, tables))
        |> or_fail_with("Expected the hash of dream_postgres")
      }),
      it("equals client.schema_fingerprint for a quoted name", fn() {
        // Arrange
        let tables = ["public.\"Odd Names\"", "public.events"]

        // Act
        let found = compute(version, tables)

        // Assert
        found
        |> should
        |> be_equal(expected(version, tables))
        |> or_fail_with("Expected the hash of dream_postgres")
      }),
    ]),
    group("text_array_literal", [
      it("quotes and escapes each item", fn() {
        // Act
        let text = text_array_literal(["a", "b\"c", "d\\e", "public.\"x\""])

        // Assert
        text
        |> should
        |> be_equal("{\"a\",\"b\\\"c\",\"d\\\\e\",\"public.\\\"x\\\"\"}")
        |> or_fail_with("Expected the escaped literal")
      }),
    ]),
  ])
}

fn compute(version: Int, tables: List(String)) -> Result(String, Nil) {
  let assert Ok(analyzer) = connect(url(version))
  let found = fingerprint.compute(analyzer, tables)
  let _ = close(analyzer)
  case found {
    Ok(hash) -> Ok(hash)
    Error(_) -> Error(Nil)
  }
}

fn expected(version: Int, tables: List(String)) -> Result(String, Nil) {
  let assert Ok(connection) = from_url(url(version))
  case schema_fingerprint(connection, tables) {
    Ok(hash) -> Ok(hash)
    Error(_) -> Error(Nil)
  }
}
