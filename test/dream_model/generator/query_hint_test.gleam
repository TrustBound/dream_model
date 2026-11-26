//// Tests for `dream_model/generator/query_hint`.

import dream_model/generator/query_hint.{
  HintError, LocalType, ModuleType, NamedLine, QueryHints, ReturnsHint,
  ReturnsMany, ReturnsMaybe, ReturnsNone, ReturnsOne, UniqueHint,
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
            unique: [],
            parameters_line: None,
            column_names: [],
            element_names: [],
          ),
        ),
      )
      |> or_fail_with("Expected no hints")
    }),
    it("reads every hint with its line", fn() {
      // Arrange
      let sql =
        "-- Returns: One User\n  -- UNIQUE: users_email_key, , users_name_key \n-- unique: users_pkey\n-- not null: a, b\n-- nullable: c\n-- params: id\n-- other: x\n-- Not Null Elements: tags, , scores\n-- not null elements: labels\nselect 1"

      // Act
      let hints = query_hint.parse(sql)

      // Assert
      hints
      |> should
      |> be_equal(
        Ok(
          QueryHints(
            returns: Some(ReturnsHint(ReturnsOne, Some(LocalType("User")), 1)),
            unique: [
              UniqueHint("users_email_key", 2),
              UniqueHint("users_name_key", 2),
              UniqueHint("users_pkey", 3),
            ],
            parameters_line: Some(6),
            column_names: [
              NamedLine("a", 4),
              NamedLine("b", 4),
              NamedLine("c", 5),
            ],
            element_names: [
              NamedLine("tags", 8),
              NamedLine("scores", 8),
              NamedLine("labels", 9),
            ],
          ),
        ),
      )
      |> or_fail_with("Expected every hint")
    }),
    it("reads only the comment block at the top of the file", fn() {
      // Arrange
      let sql =
        "-- returns: many\n\nselect email\n-- returns: one User\n-- unique: users_email_key\n-- not null elements: tags\nfrom users"

      // Act
      let hints = query_hint.parse(sql)

      // Assert
      hints
      |> should
      |> be_equal(
        Ok(
          QueryHints(
            returns: Some(ReturnsHint(ReturnsMany, None, 1)),
            unique: [],
            parameters_line: None,
            column_names: [],
            element_names: [],
          ),
        ),
      )
      |> or_fail_with("Expected only the hints before the statement")
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
      let hints = refused("-- a comment\n-- returns: all User")

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
    it("refuses the old not found hint", fn() {
      // Act
      let hints = refused("-- returns: one\n-- not found: No such user")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            2,
            "the 'not found' hint is gone: no row gives dream_errors.NotFound; remove this line and write the text for the user where the app maps dream_errors.NotFound",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused not found hint")
    }),
    it("refuses the old unique hint with a message", fn() {
      // Act
      let hints = refused("-- unique users_email_key: Email already taken")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'unique users_email_key: Email already taken' is the old form of the unique hint, and a hint holds no message now; write 'unique: users_email_key' and write the text for the user where the app maps dream_errors.Conflict",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused old unique hint")
    }),
    it("refuses the old unique hint without a message", fn() {
      // Act
      let hints = refused("-- unique  a_key :")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "'unique  a_key:' is the old form of the unique hint, and a hint holds no message now; write 'unique: a_key' and write the text for the user where the app maps dream_errors.Conflict",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused old unique hint")
    }),
    it("refuses a unique hint without a constraint", fn() {
      // Act
      let hints = refused("-- unique: , ")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            1,
            "the 'unique' hint names no constraint; write 'unique: <constraint>', for example 'unique: users_email_key'",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused unique hint")
    }),
    it("refuses one constraint in two unique hints", fn() {
      // Act
      let hints = refused("-- unique: a_key\n-- unique: b_key, a_key")

      // Assert
      hints
      |> should
      |> be_equal(
        Error([
          HintError(
            2,
            "the constraint 'a_key' is in a 'unique' hint a second time; the first one is on line 1",
          ),
        ]),
      )
      |> or_fail_with("Expected the second name to be refused")
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
