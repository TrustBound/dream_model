//// Tests for `dream_model/generator/model`, with SQL files analyzed on the
//// generator database. The end-to-end tests compare whole formatted
//// modules; these tests check the refusals and single parts of the text.

import dream_model/generator/model.{type Unit, Unit}
import dream_model/generator/name
import dream_model/generator/query.{Model, Problem}
import dream_model/nullability
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database
import gleam/list
import gleam/result
import gleam/string

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/generator/model", [
    check_types_tests(version),
    render_tests(version),
  ])
}

/// Analyzes SQL files of one model folder, each as `#(file, sql)`.
fn make_unit(
  version: Int,
  module: String,
  files: List(#(String, String)),
) -> Unit {
  let assert Ok(analyzer) = nullability.connect(model_database.url(version))
  let folder = "src/" <> module
  let folder_name = string.split(module, "/") |> list.last |> result.unwrap("")
  let model_info = Model(module:, type_name: name.to_type_name(folder_name))
  let #(queries, analyzer) =
    list.fold(files, #([], analyzer), fn(state, file) {
      let #(queries, analyzer) = state
      let #(found, analyzer) =
        query.analyze(analyzer, model_info, folder <> "/" <> file.0, file.1)
      let assert Ok(found) = found
      #([found, ..queries], analyzer)
    })
  let _ = nullability.close(analyzer)
  Unit(model: model_info, folder:, queries: list.reverse(queries))
}

const find_user = #(
  "find.sql",
  "-- returns: one User\nselect id, email, nickname from users where id = $1",
)

fn check_types_tests(version: Int) {
  group("check_types", [
    it("accepts two files that give one type the same fields", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #("list.sql", "select id, email, nickname from users"),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([])
      |> or_fail_with("Expected no problem")
    }),
    it("refuses a field with another type", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #(
            "list.sql",
            "-- returns: many User\nselect id, email, coalesce(nickname, '') as nickname from users",
          ),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([
        Problem(
          "src/app/models/user/list.sql",
          1,
          "the type User has the field 'nickname: String' here, and 'nickname: Option(String)' in src/app/models/user/find.sql; every file that returns one type must give it the same fields, in the same order, with the same types",
        ),
      ])
      |> or_fail_with("Expected the field that differs")
    }),
    it("refuses fewer fields", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #("list.sql", "-- returns: many User\nselect id, email from users"),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([
        Problem(
          "src/app/models/user/list.sql",
          1,
          "the type User has no field 'nickname: Option(String)' here, and src/app/models/user/find.sql has it; every file that returns one type must give it the same fields, in the same order, with the same types",
        ),
      ])
      |> or_fail_with("Expected the missing field")
    }),
    it("refuses more fields", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #(
            "list.sql",
            "-- returns: many User\nselect id, email, nickname, created_at from users",
          ),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([
        Problem(
          "src/app/models/user/list.sql",
          1,
          "the type User has the field 'created_at: client.Timestamp' here, and src/app/models/user/find.sql does not; every file that returns one type must give it the same fields, in the same order, with the same types",
        ),
      ])
      |> or_fail_with("Expected the extra field")
    }),
    it("refuses a type of a module that is not a model of the run", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/post", [
          #(
            "authors.sql",
            "-- returns: many app/models/user.User\nselect id, email, nickname from users",
          ),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([
        Problem(
          "src/app/models/post/authors.sql",
          1,
          "app/models/user is not a model that dream_model generates in this run; the type app/models/user.User must come from a model folder",
        ),
      ])
      |> or_fail_with("Expected the unknown model")
    }),
    it("refuses a type that no file of its model returns", fn() {
      // Arrange
      let users =
        make_unit(version, "app/models/user", [
          #("count.sql", "-- returns: one\nselect count(*) as total from users"),
        ])
      let posts =
        make_unit(version, "app/models/post", [
          #(
            "authors.sql",
            "-- returns: many app/models/user.User\nselect id, email, nickname from users",
          ),
        ])

      // Act
      let problems = model.check_types([users, posts])

      // Assert
      problems
      |> should
      |> be_equal([
        Problem(
          "src/app/models/post/authors.sql",
          1,
          "no .sql file of app/models/user returns the type User; name a type that a file of that model returns",
        ),
      ])
      |> or_fail_with("Expected the missing type")
    }),
    it("sorts the problems of every file", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #("list.sql", "-- returns: many User\nselect id, email from users"),
          #(
            "authors.sql",
            "-- returns: many app/models/other.Other\nselect id from users",
          ),
        ])

      // Act
      let files =
        model.check_types([unit])
        |> list.map(fn(problem) { problem.file })

      // Assert
      files
      |> should
      |> be_equal([
        "src/app/models/user/authors.sql",
        "src/app/models/user/list.sql",
      ])
      |> or_fail_with("Expected the problems in the order of the files")
    }),
    it("accepts a type of the model named by its own module", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          find_user,
          #(
            "list.sql",
            "-- returns: many app/models/user.User\nselect id, email, nickname from users",
          ),
        ])

      // Act
      let problems = model.check_types([unit])

      // Assert
      problems
      |> should
      |> be_equal([])
      |> or_fail_with("Expected no problem")
    }),
  ])
}

fn render_tests(version: Int) {
  group("render", [
    it("writes a module with one scalar function", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          #("count.sql", "-- returns: one\nselect count(*) as total from users"),
        ])

      // Act
      let text = model.render(unit, "abc")

      // Assert
      text
      |> should
      |> be_equal(Ok(count_module))
      |> or_fail_with("Expected the count module")
    }),
    it("gives a file with a promise a decoder of its own", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          #(
            "count.sql",
            "-- returns: one Total\nselect count(*) as total from users",
          ),
          #(
            "sum.sql",
            "-- returns: one Total\n-- not null: total\nselect sum(id)::int as total from users",
          ),
        ])

      // Act
      let text = model.render(unit, "abc") |> result.unwrap("")

      // Assert
      #(
        string.contains(text, "|> client.returning(sum_decoder())"),
        string.contains(
          text,
          "client.promised_not_null(decode.int, \"src/app/models/user/sum.sql\", \"total\")",
        ),
      )
      |> should
      |> be_equal(#(True, True))
      |> or_fail_with("Expected sum_decoder with the promise")
    }),
    it("refuses a function name that a helper uses", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/user", [
          #(
            "one_row.sql",
            "-- returns: one\nselect count(*) as total from users",
          ),
        ])

      // Act
      let text = model.render(unit, "abc")

      // Assert
      text
      |> should
      |> be_equal(
        Error([
          Problem(
            "src/app/models/user/one_row.sql",
            1,
            "the function name 'one_row' is a name that the generated module uses itself; rename the file",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused function name")
    }),
    it("refuses an import whose alias another import uses", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/client", [
          #(
            "authors.sql",
            "-- returns: many app/models/user.User\nselect id, email, nickname from users",
          ),
          #(
            "admins.sql",
            "-- returns: many admin/client.Client\nselect id from users",
          ),
        ])

      // Act
      let text = model.render(unit, "abc")

      // Assert
      text
      |> should
      |> be_equal(
        Error([
          Problem(
            "src/app/models/client/admins.sql",
            1,
            "the module admin/client would be imported as 'client', which another import of this model uses; name the type of another model whose module ends in another name",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused alias")
    }),
    it("refuses a field with the name of an imported module", fn() {
      // Arrange
      let unit =
        make_unit(version, "app/models/post", [
          #(
            "authors.sql",
            "-- returns: many app/models/user.User\nselect id, email as user from users",
          ),
        ])

      // Act
      let text = model.render(unit, "abc")

      // Assert
      text
      |> should
      |> be_equal(
        Error([
          Problem(
            "src/app/models/post/authors.sql",
            1,
            "the field 'user' has the name of the imported module app/models/user, which its decoder uses; rename the column with AS in the SQL",
          ),
        ]),
      )
      |> or_fail_with("Expected the refused field")
    }),
    it("string_literal escapes quotes and backslashes", fn() {
      // Act
      let text = model.string_literal("a \"b\" \\c")

      // Assert
      text
      |> should
      |> be_equal("\"a \\\"b\\\" \\\\c\"")
      |> or_fail_with("Expected the escaped literal")
    }),
  ])
}

const count_module =
  "//// Generated by dream_model from src/app/models/user/*.sql. Do not edit.

import dream/http/error.{type Error}
import dream_postgres/client
import gleam/dynamic/decode

/// The tables that the functions of this module read and write, and the
/// fingerprint of their schema when dream_model generated the module. Give
/// it to `client.check_schema` when the application starts, to stop with a
/// clear message when the schema changed after the generation.
pub const schema_fingerprint = client.SchemaFingerprint(
  module: \"app/models/user\",
  tables: [\"public.users\"],
  hash: \"abc\",
)

/// Generated from count.sql.
pub fn count(db: client.Connection) -> Result(Int, Error) {
  \"select count(*) as total from users\"
  |> client.query
  |> client.returning(decode.at([0], decode.int))
  |> client.execute(db)
  |> one_row(\"user.count\", \"User not found\", [])
}

fn one_row(
  executed: Result(client.Returned(row), client.QueryError),
  query_name: String,
  not_found: String,
  unique: List(#(String, String)),
) -> Result(row, Error) {
  case executed {
    Ok(returned) -> single_row(returned.rows, query_name, not_found)
    Error(query_error) ->
      Error(query_error_to_error(query_error, query_name, unique))
  }
}

fn single_row(
  rows: List(row),
  query_name: String,
  not_found: String,
) -> Result(row, Error) {
  case rows {
    [row] -> Ok(row)
    [] -> Error(error.NotFound(not_found))
    _ -> Error(error.InternalServerError(query_name <> \" returned more than one row\"))
  }
}

fn query_error_to_error(
  query_error: client.QueryError,
  query_name: String,
  unique: List(#(String, String)),
) -> Error {
  let conflict = unique_message(client.violated_constraint(query_error), unique)
  case conflict, client.broken_promise(query_error) {
    Ok(message), _ -> error.Conflict(message)
    Error(Nil), Ok(message) -> error.InternalServerError(message)
    Error(Nil), Error(Nil) -> error.InternalServerError(query_name <> \" failed\")
  }
}

fn unique_message(
  constraint: Result(String, Nil),
  unique: List(#(String, String)),
) -> Result(String, Nil) {
  case constraint, unique {
    Ok(violated), [#(name, message), ..] if name == violated -> Ok(message)
    Ok(_), [_, ..rest] -> unique_message(constraint, rest)
    _, _ -> Error(Nil)
  }
}
"
