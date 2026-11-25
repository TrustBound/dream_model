//// Tests for `dream_model/generator/query`, on the generator database.

import dream_model/generator/gleam_type.{
  IntType, ListType, NumericType, StringType,
}
import dream_model/generator/query.{
  type Problem, type Query, Argument, Field, Model, NoOutput, Problem, Query,
  RecordOutput, Unique, ValueOutput,
}
import dream_model/generator/query_hint.{
  LocalType, ReturnsMany, ReturnsNone, ReturnsOne,
}
import dream_model/nullability
import dream_model/nullability/reason
import dream_model/postgres/tree
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database
import gleam/list
import gleam/result
import gleam/string

const folder = "src/app/models/user/"

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/generator/query", [
    success_tests(version),
    refusal_tests(version),
    parameter_tests(version),
    numeric_tests(version),
    element_hint_tests(version),
    text_tests(),
  ])
}

fn analyze(
  version: Int,
  file: String,
  sql: String,
) -> Result(Query, List(Problem)) {
  let assert Ok(analyzer) = nullability.connect(model_database.url(version))
  let #(found, analyzer) =
    query.analyze(
      analyzer,
      Model(module: "app/models/user", type_name: "User"),
      folder <> file,
      sql,
    )
  let _ = nullability.close(analyzer)
  found
}

/// The problems of a refused file, or `[]` when it was accepted.
fn problems(version: Int, file: String, sql: String) -> List(Problem) {
  case analyze(version, file, sql) {
    Ok(_) -> []
    Error(found) -> found
  }
}

fn problem(file: String, line: Int, message: String) -> Problem {
  Problem(file: folder <> file, line:, message:)
}

const user_fields = [
  Field("id", "id", IntType, False, False, False),
  Field("email", "email", StringType, False, False, False),
  Field("nickname", "nickname", StringType, True, False, False),
]

fn success_tests(version: Int) {
  group("analyze", [
    it("describes find.sql", fn() {
      // Act
      let found =
        analyze(
          version,
          "find.sql",
          "-- returns: one User\n-- not found: No such user\nselect id, email, nickname from users where id = $1\n",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          Query(
            file: "src/app/models/user/find.sql",
            function: "find",
            sql: "select id, email, nickname from users where id = $1",
            returns: ReturnsOne,
            output: RecordOutput(LocalType("User"), user_fields, 1),
            arguments: [Argument("id", IntType, False)],
            not_found: "No such user",
            unique: [],
            relations: ["public.users"],
          ),
        ),
      )
      |> or_fail_with("Expected the description of find.sql")
    }),
    it("describes create.sql with its unique constraint", fn() {
      // Act
      let found =
        analyze(
          version,
          "create.sql",
          "-- returns: one User\n-- unique users_email_key: Email already taken\ninsert into users (email, nickname) values ($1, $2)\nreturning id, email, nickname",
        )

      // Assert
      found
      |> result.map(fn(described) {
        #(described.arguments, described.unique, described.not_found)
      })
      |> should
      |> be_equal(
        Ok(#(
          [
            Argument("email", StringType, False),
            Argument("nickname", StringType, True),
          ],
          [Unique("users_email_key", "Email already taken")],
          "User not found",
        )),
      )
      |> or_fail_with("Expected the arguments and the unique constraint")
    }),
    it("returns the only column of one with no type name", fn() {
      // Act
      let found =
        analyze(
          version,
          "count.sql",
          "-- returns: one\nselect count(*) as total from users",
        )

      // Assert
      found
      |> result.map(fn(described) { described.output })
      |> should
      |> be_equal(
        Ok(ValueOutput(Field("total", "total", IntType, False, False, False))),
      )
      |> or_fail_with("Expected the total column")
    }),
    it("promises a hinted not-null column", fn() {
      // Act
      let found =
        analyze(
          version,
          "total.sql",
          "-- returns: one\n-- not null: total\nselect sum(id)::int as total from posts",
        )

      // Assert
      found
      |> result.map(fn(described) { described.output })
      |> should
      |> be_equal(
        Ok(ValueOutput(Field("total", "total", IntType, False, True, False))),
      )
      |> or_fail_with("Expected the promised total column")
    }),
    it("returns none for a statement with no columns and no hint", fn() {
      // Act
      let found =
        analyze(version, "delete.sql", "delete from posts where id = $1")

      // Assert
      found
      |> result.map(fn(described) { #(described.returns, described.output) })
      |> should
      |> be_equal(Ok(#(ReturnsNone, NoOutput)))
      |> or_fail_with("Expected returns none")
    }),
    it("accepts returns none for a statement with no columns", fn() {
      // Act
      let found =
        analyze(
          version,
          "delete.sql",
          "-- returns: none\ndelete from posts where id = $1",
        )

      // Assert
      found
      |> result.map(fn(described) { described.output })
      |> should
      |> be_equal(Ok(NoOutput))
      |> or_fail_with("Expected no output")
    }),
    it("returns many of the model type with no hint", fn() {
      // Act
      let found =
        analyze(
          version,
          "list.sql",
          "\n-- a comment\n\nselect id, email, nickname from users",
        )

      // Assert
      found
      |> result.map(fn(described) { #(described.returns, described.output) })
      |> should
      |> be_equal(
        Ok(#(ReturnsMany, RecordOutput(LocalType("User"), user_fields, 4))),
      )
      |> or_fail_with("Expected many User at line 4")
    }),
    it("returns the model type for many columns and no type name", fn() {
      // Act
      let found =
        analyze(
          version,
          "list.sql",
          "-- returns: many\nselect id, email, nickname from users",
        )

      // Assert
      found
      |> result.map(fn(described) { described.output })
      |> should
      |> be_equal(Ok(RecordOutput(LocalType("User"), user_fields, 1)))
      |> or_fail_with("Expected many User at line 1")
    }),
    it(
      "maps a unique constraint of a partitioned table and its partitions",
      fn() {
        // Act
        let found =
          analyze(
            version,
            "add_event.sql",
            "-- unique events_pkey: Event taken\ninsert into events values ($1, $2, $3)",
          )

        // Assert
        found
        |> result.map(fn(described) { described.unique })
        |> should
        |> be_equal(
          Ok([
            Unique("events_a_pkey", "Event taken"),
            Unique("events_pkey", "Event taken"),
          ]),
        )
        |> or_fail_with("Expected both index names")
      },
    ),
  ])
}

fn refusal_tests(version: Int) {
  let cases = [
    #("refuses a malformed hint", "find.sql", "-- returns: all\nselect 1", [
      problem(
        "find.sql",
        1,
        "'all' is not a returns form; write one, maybe, many or none",
      ),
    ]),
    #("refuses a file name that is not a Gleam name", "2fast.sql", "select 1", [
      problem(
        "2fast.sql",
        1,
        "the file name does not give a Gleam function name; name the file in snake case, for example find_by_email.sql",
      ),
    ]),
    #(
      "gives the error of PostgreSQL at its line",
      "list.sql",
      "-- returns: many\nselect id,\n  nope\nfrom users",
      [
        problem(
          "list.sql",
          3,
          "PostgreSQL refused the statement: column \"nope\" does not exist",
        ),
      ],
    ),
    #(
      "gives a refused NULL hint at its line",
      "list.sql",
      "-- returns: many\n-- not null: email\nselect email from users",
      [
        problem(
          "list.sql",
          2,
          nullability.hint_error_to_string(nullability.HintNamesTableColumn(
            "email",
            reason.NotNullInSchema,
          )),
        ),
      ],
    ),
    #(
      "gives another error of the analysis at the statement",
      "long.sql",
      "-- returns: one\nselect 1 as \"" <> string.repeat("(", 40) <> "\"",
      [
        problem(
          "long.sql",
          2,
          nullability.error_to_string(nullability.TreeFailed(tree.TokenTooLong)),
        ),
      ],
    ),
    #(
      "refuses a column of an unsupported type",
      "spans.sql",
      "select span from spans",
      [
        problem(
          "spans.sql",
          1,
          "the column 'span' has the PostgreSQL type interval, which dream_model does not support; cast it in the SQL to a supported type, for example span::text",
        ),
      ],
    ),
    #(
      "refuses a parameter of an unsupported type",
      "spans.sql",
      "-- returns: many\nselect id from spans\nwhere span = $1",
      [
        problem(
          "spans.sql",
          3,
          "the parameter $1 has the PostgreSQL type interval, which dream_model does not support; cast it in the SQL from a supported type, for example $1::text::interval",
        ),
      ],
    ),
    #(
      "refuses returns none for a statement with columns",
      "list.sql",
      "-- returns: none\nselect id, email from users",
      [
        problem(
          "list.sql",
          1,
          "'returns: none', and the statement returns the columns id, email; remove the columns or write another returns form",
        ),
      ],
    ),
    #(
      "refuses returns one for a statement with no columns",
      "delete.sql",
      "-- returns: one\ndelete from posts where id = $1",
      [
        problem(
          "delete.sql",
          1,
          "'returns: one' needs result columns, and the statement returns none; write 'returns: none'",
        ),
      ],
    ),
    #(
      "refuses a column with no Gleam name",
      "odd.sql",
      "select 1 as \"2x\", 2 as b",
      [
        problem(
          "odd.sql",
          1,
          "result column 1 ('2x') has no Gleam name; name it with AS in the SQL, for example AS total",
        ),
      ],
    ),
    #(
      "refuses two columns with one field name",
      "odd.sql",
      "-- returns: many\nselect 1, 2",
      [
        problem(
          "odd.sql",
          1,
          "two result columns give the field name 'column'; rename one with AS in the SQL",
        ),
      ],
    ),
    #(
      "refuses a field name that the decoder uses",
      "odd.sql",
      "select 1 as decode, 2 as b",
      [
        problem(
          "odd.sql",
          1,
          "the result column 'decode' gives the field name 'decode', which the generated decoder uses itself; rename it with AS in the SQL",
        ),
      ],
    ),
    #(
      "refuses a unique hint on a statement that writes no table",
      "list.sql",
      "-- returns: many\n-- unique users_email_key: Taken\nselect id from users",
      [
        problem(
          "list.sql",
          2,
          "the statement writes no table, so no unique constraint can fail; remove the hint",
        ),
      ],
    ),
    #(
      "refuses a unique hint that names no unique constraint",
      "rename.sql",
      "-- unique users_nickname_key: Taken\nupdate users set nickname = $1",
      [
        problem(
          "rename.sql",
          1,
          "'users_nickname_key' is not a unique constraint, a primary key or a unique index of public.users",
        ),
      ],
    ),
    #(
      "refuses a unique hint whose name a check constraint of another table has",
      "create.sql",
      "-- unique accounts_handle_key: Handle taken\ninsert into accounts (id, handle) values ($1, $2)",
      [
        problem(
          "create.sql",
          1,
          "the name 'accounts_handle_key' belongs to the unique index public.accounts_handle_key on public.accounts, and also to the check constraint accounts_handle_key on public.audits; PostgreSQL names a violation only by the name of its constraint, so a violation of the other object would give this Conflict; rename one of them",
        ),
      ],
    ),
    #(
      "refuses a unique hint whose name an index of another schema has",
      "create.sql",
      "-- unique badges_code_index: Code taken\ninsert into badges (id, code) values ($1, $2)",
      [
        problem(
          "create.sql",
          1,
          "the name 'badges_code_index' belongs to the unique index public.badges_code_index on public.badges, and also to the index archive.badges_code_index on archive.badges; PostgreSQL names a violation only by the name of its constraint, so a violation of the other object would give this Conflict; rename one of them",
        ),
      ],
    ),
    #(
      "refuses a unique hint whose name a foreign key and a domain constraint have",
      "create.sql",
      "-- unique teams_id_key: Team taken\ninsert into teams (id) values ($1)",
      [
        problem(
          "create.sql",
          1,
          "the name 'teams_id_key' belongs to the unique index public.teams_id_key on public.teams, and also to the check constraint teams_id_key on the domain public.team_code and the foreign key teams_id_key on public.members; PostgreSQL names a violation only by the name of its constraint, so a violation of the other object would give this Conflict; rename one of them",
        ),
      ],
    ),
  ]
  group(
    "analyze refusals",
    list.map(cases, fn(example) {
      let #(title, file, sql, expected) = example
      it(title, fn() {
        // Act
        let found = problems(version, file, sql)

        // Assert
        found
        |> should
        |> be_equal(expected)
        |> or_fail_with("Expected " <> string.inspect(expected))
      })
    }),
  )
}

fn parameter_tests(version: Int) {
  let refusals = [
    #(
      "refuses a params hint with too few names",
      "-- params: a\nselect id from users where id = $1 and email = $2",
      [
        problem(
          "find.sql",
          1,
          "the 'params' hint names 1 parameters, and the statement has 2; name every parameter, in order",
        ),
      ],
    ),
    #(
      "refuses a params name that is not a Gleam name",
      "-- params: userId\nselect id from users where id = $1",
      [
        problem(
          "find.sql",
          1,
          "'userId' is not a Gleam name; write the parameter names in snake case, for example user_id",
        ),
      ],
    ),
    #(
      "refuses a params name that the function uses",
      "-- params: db\nselect id from users where id = $1",
      [
        problem(
          "find.sql",
          1,
          "the parameter name 'db' is a name that the generated function uses itself: its connection, a module, a helper or a decoder; choose another name",
        ),
      ],
    ),
    #(
      "refuses a params name of a helper",
      "-- params: many_rows\nselect id from users where id = $1",
      [
        problem(
          "find.sql",
          1,
          "the parameter name 'many_rows' is a name that the generated function uses itself: its connection, a module, a helper or a decoder; choose another name",
        ),
      ],
    ),
    #(
      "refuses a params name of a decoder",
      "\n-- params: user_decoder\nselect id from users where id = $1",
      [
        problem(
          "find.sql",
          2,
          "the parameter name 'user_decoder' is a name that the generated function uses itself: its connection, a module, a helper or a decoder; choose another name",
        ),
      ],
    ),
    #(
      "refuses two params with one name",
      "-- params: a, a\nselect id from users where id = $1 and email = $2",
      [
        problem(
          "find.sql",
          1,
          "the parameters $1 and $2 would all be named 'a'; name every parameter, in order, with a line like '-- params: a, a'",
        ),
      ],
    ),
    #(
      "refuses a parameter with no column",
      "-- returns: none\nupdate users set nickname = $1\nwhere id = $2 and $3::int = 1",
      [
        problem(
          "find.sql",
          3,
          "the parameter $3 is not stored into or compared with a table column, so it has no name; name every parameter, in order, with a line like '-- params: nickname?, id, value_3'",
        ),
      ],
    ),
    #(
      "refuses a parameter with two columns",
      "select id from users where nickname = $1 or email = $1",
      [
        problem(
          "find.sql",
          1,
          "the parameter $1 is used with the columns nickname and email, so its name is not clear; name every parameter, in order, with a line like '-- params: value_1'",
        ),
      ],
    ),
    #(
      "refuses two parameters that get one name",
      "select id from users\nwhere id = $1 or id = $2",
      [
        problem(
          "find.sql",
          2,
          "the parameters $1 and $2 would all be named 'id'; name every parameter, in order, with a line like '-- params: id, id_2'",
        ),
      ],
    ),
    #(
      "refuses a parameter named after a reserved column",
      "select db from reserved_names where db = $1",
      [
        problem(
          "find.sql",
          1,
          "the parameter $1 would be named 'db', which the generated function uses itself; name every parameter, in order, with a line like '-- params: db'",
        ),
      ],
    ),
    #(
      "refuses a parameter whose column gives no Gleam name",
      "select db from reserved_names where \"9lives\" = $1",
      [
        problem(
          "find.sql",
          1,
          "the column '9lives' of the parameter $1 gives no Gleam name; name every parameter, in order, with a line like '-- params: value_1'",
        ),
      ],
    ),
  ]
  group(
    "parameter names",
    list.append(
      [
        it("names the parameters with the params hint", fn() {
          // Act
          let found =
            analyze(
              version,
              "search.sql",
              "-- returns: many User\n-- params: pattern, nickname?\nselect id, email, nickname from users\nwhere email like $1 and ($2::text is null or nickname = $2)",
            )

          // Assert
          found
          |> result.map(fn(described) { described.arguments })
          |> should
          |> be_equal(
            Ok([
              Argument("pattern", StringType, False),
              Argument("nickname", StringType, True),
            ]),
          )
          |> or_fail_with("Expected pattern and nickname?")
        }),
        it("gives a keyword column name an underscore", fn() {
          // Act
          let found =
            analyze(
              version,
              "odd.sql",
              "-- returns: none\nupdate \"Odd Names\" set \"type\" = $1",
            )

          // Assert
          found
          |> result.map(fn(described) { described.arguments })
          |> should
          |> be_equal(Ok([Argument("type_", StringType, True)]))
          |> or_fail_with("Expected type_")
        }),
      ],
      list.map(refusals, fn(example) {
        let #(title, sql, expected) = example
        it(title, fn() {
          // Act
          let found = problems(version, "find.sql", sql)

          // Assert
          found
          |> should
          |> be_equal(expected)
          |> or_fail_with("Expected " <> string.inspect(expected))
        })
      }),
    ),
  )
}

fn output_of(version: Int, file: String, sql: String) {
  analyze(version, file, sql)
  |> result.map(fn(described) { described.output })
}

fn arguments_of(version: Int, file: String, sql: String) {
  analyze(version, file, sql)
  |> result.map(fn(described) { described.arguments })
}

fn numeric_tests(version: Int) {
  group("numeric", [
    it("types a numeric column as an exact String", fn() {
      // Act
      let found =
        output_of(
          version,
          "amount.sql",
          "-- returns: one\nselect amount from prices where id = $1",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          ValueOutput(Field(
            "amount",
            "amount",
            NumericType,
            False,
            False,
            False,
          )),
        ),
      )
      |> or_fail_with("Expected a numeric amount field")
    }),
    it("types a domain over numeric as numeric", fn() {
      // Act
      let found =
        output_of(
          version,
          "cost.sql",
          "-- returns: one\nselect cost from prices where id = $1",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(ValueOutput(Field("cost", "cost", NumericType, True, False, False))),
      )
      |> or_fail_with("Expected a numeric cost field")
    }),
    it("types a numeric parameter as numeric", fn() {
      // Act
      let found =
        arguments_of(
          version,
          "cheaper.sql",
          "select id from prices where amount < $1",
        )

      // Assert
      found
      |> should
      |> be_equal(Ok([Argument("amount", NumericType, False)]))
      |> or_fail_with("Expected a numeric amount argument")
    }),
    it("refuses a numeric[] parameter at its line", fn() {
      // Act
      let found =
        problems(
          version,
          "history.sql",
          "-- returns: none\nupdate prices\nset history = $1\nwhere id = $2",
        )

      // Assert
      found
      |> should
      |> be_equal([
        problem(
          "history.sql",
          3,
          "the parameter $1 is an array of numeric, which dream_model cannot send exactly; take a text array and cast it in the SQL, for example $1::text[]::numeric[], and the parameter is a List(Option(String))",
        ),
      ])
      |> or_fail_with("Expected the refusal of the numeric[] parameter")
    }),
    it("takes a text[] parameter that the SQL casts to numeric[]", fn() {
      // Act
      let found =
        arguments_of(
          version,
          "history.sql",
          "-- returns: none\n-- params: history, id\nupdate prices set history = $1::text[]::numeric[] where id = $2",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok([
          Argument("history", ListType(StringType), False),
          Argument("id", IntType, False),
        ]),
      )
      |> or_fail_with("Expected a text list argument and the id")
    }),
  ])
}

fn element_hint_tests(version: Int) {
  let refusals = [
    #(
      "refuses a column that is not an array",
      "-- not null elements: amount\nselect id, amount from prices",
      [
        problem(
          "find.sql",
          1,
          "hint 'not null elements: amount' names a column that is not an array: its Gleam type is String; the hint is only for array columns",
        ),
      ],
    ),
    #(
      "refuses an unknown column",
      "-- returns: many\n-- not null elements: nothing\nselect id, tags from prices",
      [
        problem(
          "find.sql",
          2,
          "hint 'not null elements: nothing' names an unknown column; the result columns are id, tags",
        ),
      ],
    ),
    #(
      "refuses a table column that is not in the result",
      "-- not null elements: labels\nselect id, tags from prices",
      [
        problem(
          "find.sql",
          1,
          "hint 'not null elements: labels' names public.prices.labels, which is not in the result of the statement; return it, or remove it from the hint (the result columns are id, tags)",
        ),
      ],
    ),
    #(
      "refuses a name when the statement returns no columns",
      "-- not null elements: tags\ndelete from prices where id = $1",
      [
        problem(
          "find.sql",
          1,
          "hint 'not null elements: tags' names public.prices.tags, which is not in the result of the statement; return it, or remove it from the hint (the statement returns no columns)",
        ),
      ],
    ),
  ]
  group("not null elements", [
    it("promises the elements of a NOT NULL array column", fn() {
      // Act
      let found =
        output_of(
          version,
          "tags.sql",
          "-- returns: one\n-- not null elements: tags\nselect tags from prices where id = $1",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          ValueOutput(Field(
            "tags",
            "tags",
            ListType(StringType),
            False,
            False,
            True,
          )),
        ),
      )
      |> or_fail_with("Expected promised elements of a NOT NULL column")
    }),
    it("keeps a nullable array column optional", fn() {
      // Act
      let found =
        output_of(
          version,
          "labels.sql",
          "-- returns: one\n-- not null elements: labels\nselect labels from prices where id = $1",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          ValueOutput(Field(
            "labels",
            "labels",
            ListType(StringType),
            True,
            False,
            True,
          )),
        ),
      )
      |> or_fail_with("Expected promised elements of an optional column")
    }),
    it("leaves the other array columns alone", fn() {
      // Act
      let found =
        output_of(
          version,
          "both.sql",
          "-- returns: one Price\n-- not null elements: tags\nselect tags, labels from prices where id = $1",
        )

      // Assert
      found
      |> should
      |> be_equal(
        Ok(RecordOutput(
          LocalType("Price"),
          [
            Field("tags", "tags", ListType(StringType), False, False, True),
            Field("labels", "labels", ListType(StringType), True, False, False),
          ],
          1,
        )),
      )
      |> or_fail_with("Expected only tags with promised elements")
    }),
    ..list.map(refusals, fn(example) {
      let #(title, sql, expected) = example
      it(title, fn() {
        // Act
        let found = problems(version, "find.sql", sql)

        // Assert
        found
        |> should
        |> be_equal(expected)
        |> or_fail_with("Expected " <> string.inspect(expected))
      })
    })
  ])
}

fn text_tests() {
  group("texts", [
    it("problem_to_string writes file:line: message", fn() {
      // Act
      let text = query.problem_to_string(Problem("a.sql", 3, "wrong"))

      // Assert
      text
      |> should
      |> be_equal("a.sql:3: wrong")
      |> or_fail_with("Expected a.sql:3: wrong")
    }),
    it("function_name gives the snake case name of the file", fn() {
      // Act
      let found = query.function_name("src/app/models/user/findByEmail.sql")

      // Assert
      found
      |> should
      |> be_equal(Ok("find_by_email"))
      |> or_fail_with("Expected find_by_email")
    }),
    it("strip_leading_comments keeps the statement and its line", fn() {
      // Act
      let found =
        query.strip_leading_comments("-- a\n\n  -- b\nselect 1\n-- c\n\n")

      // Assert
      found
      |> should
      |> be_equal(#(4, "select 1\n-- c"))
      |> or_fail_with("Expected line 4")
    }),
  ])
}
