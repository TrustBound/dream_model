//// Tests for `dream_model/generator/query_hint`.

import dream_model/generator/query_hint.{
  HintError, LocalType, ModuleType, NamedLine, NotFoundHint, QueryHints,
  ReturnsHint, ReturnsMany, ReturnsMaybe, ReturnsNone, ReturnsOne, UniqueHint,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn tests() -> TestSuite {
  describe("dream_model/generator/query_hint", [
    parse_tests(),
    refusal_tests(),
    name_tests(),
  ])
}

fn parse_tests() {
  group("parse", [
    it("returns no hints for SQL without hint lines", fn() {
      // Arrange
      let sql = "-- a comment\nselect 1"

      // Act
      let hints = query_hint.parse(sql)

      // Assert
      hints
      |> should
      |> be_equal(
        Ok(
          QueryHints(
            returns: None,
            not_found: None,
            unique: [],
            params_line: None,
            column_names: [],
          ),
        ),
      )
      |> or_fail_with("Expected no hints")
    }),
    it("reads every hint with its line", fn() {
      // Arrange
      let sql =
        "-- Returns: One User\n  -- NOT FOUND: No such user \n-- unique users_email_key: Email already taken\n-- unique users_pkey: Id taken\n-- not null: a, b\n-- nullable: c\n-- params: id\n-- other: x\nselect 1"

      // Act
      let hints = query_hint.parse(sql)

      // Assert
      hints
      |> should
      |> be_equal(
        Ok(
          QueryHints(
            returns: Some(ReturnsHint(ReturnsOne, Some(LocalType("User")), 1)),
            not_found: Some(NotFoundHint("No such user", 2)),
            unique: [
              UniqueHint("users_email_key", "Email already taken", 3),
              UniqueHint("users_pkey", "Id taken", 4),
            ],
            params_line: Some(7),
            column_names: [
              NamedLine("a", 5),
              NamedLine("b", 5),
              NamedLine("c", 6),
            ],
          ),
        ),
      )
      |> or_fail_with("Expected every hint")
    }),
    it("reads maybe with a type of another model", fn() {
      // Arrange
      let sql = "-- returns: maybe app/models/user.User"

      // Act
      let returns =
        query_hint.parse(sql) |> result.map(fn(hints) { hints.returns })

      // Assert
      returns
      |> should
      |> be_equal(
        Ok(
          Some(ReturnsHint(
            ReturnsMaybe,
            Some(ModuleType("app/models/user", "User")),
            1,
          )),
        ),
      )
      |> or_fail_with("Expected maybe app/models/user.User")
    }),
    it("reads many without a type", fn() {
      // Arrange
      let sql = "--returns:many"

      // Act
      let returns =
        query_hint.parse(sql) |> result.map(fn(hints) { hints.returns })

      // Assert
      returns
      |> should
      |> be_equal(Ok(Some(ReturnsHint(ReturnsMany, None, 1))))
      |> or_fail_with("Expected many")
    }),
    it("reads none", fn() {
      // Arrange
      let sql = "-- returns: none"

      // Act
      let returns =
        query_hint.parse(sql) |> result.map(fn(hints) { hints.returns })

      // Assert
      returns
      |> should
      |> be_equal(Ok(Some(ReturnsHint(ReturnsNone, None, 1))))
      |> or_fail_with("Expected none")
    }),
  ])
}

fn refused(
  sql: String,
) -> Result(query_hint.QueryHints, List(query_hint.HintError)) {
  query_hint.parse(sql)
}

fn refusal_tests() {
  group("parse refusals", [
    it("refuses an unknown returns form", fn() {
      // Act
      let hints = refused("select 1\n-- returns: all User")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            2,
            "'all' is not a returns form; write one, maybe, many or none",
          ),
        ]),
      )
      |> or_fail_with("Expected the unknown form")
    }),
    it("refuses a returns hint with three words", fn() {
      // Act
      let hints = refused("-- returns: one User please")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'returns: one User please' is not a returns hint; write 'returns: one', 'maybe', 'many' or 'none', with a type name after it, for example 'returns: one User'",
          ),
        ]),
      )
      |> or_fail_with("Expected the malformed hint")
    }),
    it("refuses an empty returns hint", fn() {
      // Act
      let hints = refused("-- returns:")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'returns: ' is not a returns hint; write 'returns: one', 'maybe', 'many' or 'none', with a type name after it, for example 'returns: one User'",
          ),
        ]),
      )
      |> or_fail_with("Expected the empty hint")
    }),
    it("refuses an unknown form before a type", fn() {
      // Act
      let hints = refused("-- returns: some User")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'some' is not a returns form; write one, maybe, many or none",
          ),
        ]),
      )
      |> or_fail_with("Expected the unknown form")
    }),
    it("refuses a type name after none", fn() {
      // Act
      let hints = refused("-- returns: none User")

      // Assert
      hints
      |> should
      |> be_equal(Error([HintError(1, "'returns: none' takes no type name")]))
      |> or_fail_with("Expected the refused type of none")
    }),
    it("refuses a type name in lowercase", fn() {
      // Act
      let hints = refused("-- returns: one user")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'user' is not a type name; a type name starts with a capital letter and has only letters and digits, for example User",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused type name")
    }),
    it("refuses a type with an empty name", fn() {
      // Act
      let hints = refused("-- returns: one app/models/user.")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'app/models/user.' is not a type name; a type name starts with a capital letter and has only letters and digits, for example User",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused type name")
    }),
    it("refuses a module path that is not a Gleam module", fn() {
      // Act
      let hints = refused("-- returns: many App/models/user.User")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'App/models/user.User' is not a type name; a type of another model is its module and its type, for example app/models/user.User",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused module path")
    }),
    it("refuses a second returns hint", fn() {
      // Act
      let hints = refused("-- returns: one\n-- returns: many")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(2, "a second 'returns' hint; the first one is on line 1"),
        ]),
      )
      |> or_fail_with("Expected the second hint to be refused")
    }),
    it("refuses an empty not found message and not found without one", fn() {
      // Act
      let hints = refused("-- not found:\n-- not found: Gone")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(1, "the 'not found' hint has no message"),
          HintError(
            2,
            "the 'not found' hint needs 'returns: one'; only 'one' fails when there is no row",
          ),
        ]),
      )
      |> or_fail_with("Expected both refusals")
    }),
    it("refuses a second not found hint", fn() {
      // Act
      let hints = refused("-- returns: one\n-- not found: A\n-- not found: B")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(3, "a second 'not found' hint; the first one is on line 2"),
        ]),
      )
      |> or_fail_with("Expected the second hint to be refused")
    }),
    it("refuses not found with returns many", fn() {
      // Act
      let hints = refused("-- not found: Gone\n-- returns: many")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "the 'not found' hint needs 'returns: one'; only 'one' fails when there is no row",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused not found")
    }),
    it("refuses a unique hint without a constraint", fn() {
      // Act
      let hints = refused("-- unique: Taken")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "the 'unique' hint names no constraint; write 'unique <constraint>: <message>'",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused unique hint")
    }),
    it("refuses a unique hint without a message", fn() {
      // Act
      let hints = refused("-- unique users_email_key:")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([HintError(1, "the 'unique users_email_key' hint has no message")]),
      )
      |> or_fail_with("Expected the refused unique hint")
    }),
    it("refuses a second unique hint for one constraint", fn() {
      // Act
      let hints = refused("-- unique a_key: A\n-- unique a_key: B")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            2,
            "a second 'unique a_key' hint; the first one is on line 1",
          ),
        ]),
      )
      |> or_fail_with("Expected the second unique hint to be refused")
    }),
  ])
}

fn name_tests() {
  group("names", [
    it("type_name_to_string writes a local type", fn() {
      // Act
      let text = query_hint.type_name_to_string(LocalType("User"))

      // Assert
      text
      |> should
      |> be_equal("User")
      |> or_fail_with("Expected User")
    }),
    it("type_name_to_string writes a type of another model", fn() {
      // Act
      let text =
        query_hint.type_name_to_string(ModuleType("app/models/user", "User"))

      // Assert
      text
      |> should
      |> be_equal("app/models/user.User")
      |> or_fail_with("Expected app/models/user.User")
    }),
    it("returns_to_string writes each form", fn() {
      // Act
      let words =
        [ReturnsOne, ReturnsMaybe, ReturnsMany, ReturnsNone]
        |> list.map(query_hint.returns_to_string)

      // Assert
      words
      |> should
      |> be_equal(["one", "maybe", "many", "none"])
      |> or_fail_with("Expected the four words")
    }),
    it("is_type_name refuses an empty name", fn() {
      // Act
      let accepted = query_hint.is_type_name("")

      // Assert
      accepted
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected False")
    }),
    it("is_module_segment accepts snake case", fn() {
      // Act
      let accepted = query_hint.is_module_segment("user_2")

      // Assert
      accepted
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected True")
    }),
    it("is_module_segment refuses an empty segment", fn() {
      // Act
      let accepted = query_hint.is_module_segment("")

      // Assert
      accepted
      |> should
      |> be_equal(False)
      |> or_fail_with("Expected False")
    }),
  ])
}
