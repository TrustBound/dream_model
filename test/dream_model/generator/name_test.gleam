//// Tests for `dream_model/generator/name`.

import dream_model/generator/name.{avoid_keyword, to_type_name, to_value_name}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/list.{map}

pub fn tests() -> TestSuite {
  describe("dream_model/generator/name", [
    group(
      "to_value_name",
      map(
        [
          #("email", Ok("email")),
          #("createdAt", Ok("created_at")),
          #("Total Count", Ok("total_count")),
          #("user2Id", Ok("user2_id")),
          #("__a__b__", Ok("a_b")),
          #("type", Ok("type_")),
          #("?column?", Ok("column")),
          #("2fast", Error(Nil)),
          #("???", Error(Nil)),
          #("", Error(Nil)),
        ],
        fn(example) {
          let #(sql_name, expected) = example
          it(
            "gives " <> string_of(expected) <> " for '" <> sql_name <> "'",
            fn() {
              // Act
              let found = to_value_name(sql_name)

              // Assert
              found
              |> should
              |> be_equal(expected)
              |> or_fail_with("Expected " <> string_of(expected))
            },
          )
        },
      ),
    ),
    group("to_type_name", [
      it("gives UserAccount for user_account", fn() {
        // Act
        let found = to_type_name("user_account")

        // Assert
        found
        |> should
        |> be_equal("UserAccount")
        |> or_fail_with("Expected UserAccount")
      }),
    ]),
    group("avoid_keyword", [
      it("adds _ to a keyword", fn() {
        // Act
        let found = avoid_keyword("use")

        // Assert
        found
        |> should
        |> be_equal("use_")
        |> or_fail_with("Expected use_")
      }),
      it("keeps a name that is not a keyword", fn() {
        // Act
        let found = avoid_keyword("user")

        // Assert
        found
        |> should
        |> be_equal("user")
        |> or_fail_with("Expected user")
      }),
    ]),
  ])
}

fn string_of(found: Result(String, Nil)) -> String {
  case found {
    Ok(value) -> value
    Error(Nil) -> "no name"
  }
}
