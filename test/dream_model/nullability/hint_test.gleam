//// Tests for `dream_model/nullability/hint`.

import dream_model/nullability/hint.{Hints, is_optional_parameter, parse_hints}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/option.{None, Some}

pub fn tests() -> TestSuite {
  describe("dream_model/nullability/hint", [
    group("parse_hints", [
      it("returns no hints for SQL without hint lines", fn() {
        // Arrange
        let sql = "-- just a comment\nselect 1"

        // Act
        let hints = parse_hints(sql)

        // Assert
        hints
        |> should
        |> be_equal(Hints(not_null: [], nullable: [], parameters: None))
        |> or_fail_with("Expected no hints")
      }),
      it("reads every hint kind, in any case, without duplicates", fn() {
        // Arrange
        let sql =
          "  --NOT NULL: a, b\n-- not null : b,,c\n-- Nullable: d\n-- params: x, y?\n-- other: z\nselect 1"

        // Act
        let hints = parse_hints(sql)

        // Assert
        hints
        |> should
        |> be_equal(Hints(
          not_null: ["a", "b", "c"],
          nullable: ["d"],
          parameters: Some(["x", "y?"]),
        ))
        |> or_fail_with("Expected every hint")
      }),
      it("reads only the comment block at the top of the file", fn() {
        // Arrange
        let sql =
          "-- not null: a\n\n-- nullable: b\nselect a, b\n-- params: id?\n-- nullable: email\nfrom t"

        // Act
        let hints = parse_hints(sql)

        // Assert
        hints
        |> should
        |> be_equal(Hints(not_null: ["a"], nullable: ["b"], parameters: None))
        |> or_fail_with("Expected only the hints before the statement")
      }),
      it("takes the last params line", fn() {
        // Arrange
        let sql = "-- params: a?\n-- params: b"

        // Act
        let hints = parse_hints(sql)

        // Assert
        hints.parameters
        |> should
        |> be_equal(Some(["b"]))
        |> or_fail_with("Expected the last params line")
      }),
    ]),
    group("is_optional_parameter", [
      it("is True for a name with ?", fn() {
        // Arrange
        let hints = parse_hints("-- params: a, b?")

        // Act
        let optional = is_optional_parameter(hints, 2)

        // Assert
        optional
        |> should
        |> be_equal(True)
        |> or_fail_with("Expected b? to be optional")
      }),
      it("is False for a name without ?", fn() {
        // Arrange
        let hints = parse_hints("-- params: a, b?")

        // Act
        let optional = is_optional_parameter(hints, 1)

        // Assert
        optional
        |> should
        |> be_equal(False)
        |> or_fail_with("Expected a to be required")
      }),
      it("is False for a position after the last name", fn() {
        // Arrange
        let hints = parse_hints("-- params: a?")

        // Act
        let optional = is_optional_parameter(hints, 2)

        // Assert
        optional
        |> should
        |> be_equal(False)
        |> or_fail_with("Expected no hint for $2")
      }),
      it("is False without a params line", fn() {
        // Arrange
        let hints = parse_hints("select $1")

        // Act
        let optional = is_optional_parameter(hints, 1)

        // Assert
        optional
        |> should
        |> be_equal(False)
        |> or_fail_with("Expected no hint")
      }),
    ]),
  ])
}
