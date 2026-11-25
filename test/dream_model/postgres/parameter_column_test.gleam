//// Tests for `dream_model/postgres/parameter_column`, through the columns,
//// relations and written relations of `nullability.analyze`, on the
//// generator database.

import dream_model/nullability.{type Analysis, TableColumn}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database
import gleam/list
import gleam/string

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/postgres/parameter_column", [
    group(
      "the columns of each parameter",
      list.map(column_cases(), fn(example) {
        let #(title, sql, expected) = example
        it(title, fn() {
          // Act
          let columns =
            analyze(version, sql).parameters
            |> list.map(fn(parameter) {
              list.map(parameter.columns, fn(column) {
                column.table <> "." <> column.column
              })
            })

          // Assert
          columns
          |> should
          |> be_equal(expected)
          |> or_fail_with("Expected " <> string.inspect(expected))
        })
      }),
    ),
    group(
      "written relations",
      list.map(written_cases(), fn(example) {
        let #(title, sql, expected) = example
        it(title, fn() {
          // Act
          let written = analyze(version, sql).written_relations

          // Assert
          written
          |> should
          |> be_equal(expected)
          |> or_fail_with("Expected " <> string.inspect(expected))
        })
      }),
    ),
    group("relations", [
      it("holds every table of the statement with its partitions", fn() {
        // Act
        let relations =
          analyze(
            version,
            "select e.id from events e join users u on u.id = e.id",
          ).relations

        // Assert
        relations
        |> should
        |> be_equal(["public.events", "public.events_a", "public.users"])
        |> or_fail_with("Expected events, events_a and users")
      }),
      it("quotes a name as quote_ident does", fn() {
        // Act
        let relations =
          analyze(version, "select \"Mixed Case\" from \"Odd Names\"").relations

        // Assert
        relations
        |> should
        |> be_equal(["public.\"Odd Names\""])
        |> or_fail_with("Expected the quoted name")
      }),
      it("names a stored column of a quoted table", fn() {
        // Act
        let columns =
          analyze(version, "insert into \"Odd Names\" values ($1, $2)").parameters
          |> list.flat_map(fn(parameter) { parameter.columns })

        // Assert
        columns
        |> should
        |> be_equal([
          TableColumn("public.\"Odd Names\"", "Mixed Case"),
          TableColumn("public.\"Odd Names\"", "type"),
        ])
        |> or_fail_with("Expected the two columns")
      }),
    ]),
  ])
}

fn analyze(version: Int, sql: String) -> Analysis {
  let assert Ok(analyzer) = nullability.connect(model_database.url(version))
  let assert Ok(#(analysis, analyzer)) = nullability.analyze(analyzer, sql)
  let _ = nullability.close(analyzer)
  analysis
}

fn column_cases() -> List(#(String, String, List(List(String)))) {
  [
    #("a column = $1", "select id from users where id = $1", [
      ["public.users.id"],
    ]),
    #("$1 = a column", "select id from users where $1 = email", [
      ["public.users.email"],
    ]),
    #("IN with two parameters", "select id from users where id in ($1, $2)", [
      ["public.users.id"],
      ["public.users.id"],
    ]),
    #(
      "= ANY of an array parameter",
      "select id from users where id = any ($1)",
      [["public.users.id"]],
    ),
    #(
      "IS DISTINCT FROM",
      "select id from users where nickname is distinct from $1",
      [["public.users.nickname"]],
    ),
    #("LIKE", "select id from users where email like $1", [
      ["public.users.email"],
    ]),
    #("a cast of the parameter", "select id from users where id = $1::int", [
      ["public.users.id"],
    ]),
    #(
      "INSERT, through the length coercion of a varchar",
      "insert into posts (user_id, title, body) values ($1, $2, $3)",
      [["public.posts.user_id"], ["public.posts.title"], ["public.posts.body"]],
    ),
    #("UPDATE SET and WHERE", "update users set nickname = $2 where id = $1", [
      ["public.users.id"],
      ["public.users.nickname"],
    ]),
    #(
      "ON CONFLICT DO UPDATE SET",
      "insert into users (email) values ($1) on conflict (email) do update set nickname = $2",
      [["public.users.email"], ["public.users.nickname"]],
    ),
    #("a column of a view", "select id from user_emails where email = $1", [
      ["public.users.email"],
    ]),
    #(
      "a column of a join alias",
      "select 1 from (users join posts using (id)) as joined where joined.id = $1",
      [["public.users.id"]],
    ),
    #(
      "no column for the merged column of a FULL JOIN",
      "select 1 from users full join posts using (id) where id = $1",
      [[]],
    ),
    #(
      "a column of a subquery in FROM",
      "select found.id from (select id, email from users) as found where found.email = $1",
      [["public.users.email"]],
    ),
    #(
      "a column of the outer query in a subquery",
      "select id from users where exists (select 1 from posts where users.email = $1)",
      [["public.users.email"]],
    ),
    #("two columns", "select id from users where nickname = $1 or email = $1", [
      ["public.users.nickname", "public.users.email"],
    ]),
    #("no column for a computed value", "select $1::int + 1 as total", [[]]),
    #(
      "no column for a constant on the other side",
      "select id from users where $1::int = 1",
      [[]],
    ),
    #(
      "no column for a CTE column",
      "with found as (select id from users) select id from found where id = $1",
      [[]],
    ),
    #("no column for a system column", "select id from users where ctid = $1", [
      [],
    ]),
    #(
      "a parameter in an array with other values",
      "select id from users where id = any (array[$1, id])",
      [["public.users.id"]],
    ),
  ]
}

fn written_cases() -> List(#(String, String, List(String))) {
  [
    #("a SELECT writes nothing", "select id from users", []),
    #("a DELETE writes its table", "delete from posts where id = 1", [
      "public.posts",
    ]),
    #(
      "a data-modifying CTE writes its table",
      "with moved as (update users set nickname = 'x' returning id) select id from moved",
      ["public.users"],
    ),
  ]
}
