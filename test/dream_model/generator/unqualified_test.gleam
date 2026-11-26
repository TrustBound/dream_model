//// Tests for `dream_model/generator/unqualified`.

import dream_model/generator/unqualified.{Import, unqualify}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}

const client =
  Import(
    path: "dream_postgres/client",
    alias: "client",
    constructors: ["SchemaFingerprint"],
    records: [],
  )

const decode =
  Import(
    path: "gleam/dynamic/decode",
    alias: "decode",
    constructors: [],
    records: [],
  )

const errors =
  Import(
    path: "dream_errors",
    alias: "dream_errors",
    constructors: ["NotFound"],
    records: [],
  )

const user =
  Import(
    path: "app/models/user",
    alias: "user",
    constructors: [],
    records: ["User"],
  )

pub fn tests() -> TestSuite {
  describe("dream_model/generator/unqualified", [
    it("imports each used name bare, types before values", fn() {
      // Act
      let found =
        unqualify(
          "fn f(db: client.Connection) {\n  client.SchemaFingerprint(client.query(db))\n}",
          [client],
        )

      // Assert
      found
      |> should
      |> be_equal(#(
        [
          "import dream_postgres/client.{type Connection, SchemaFingerprint, query}",
        ],
        "fn f(db: Connection) {\n  SchemaFingerprint(query(db))\n}",
      ))
      |> or_fail_with("Expected the bare names")
    }),
    it("keeps the module of a name that the code uses bare", fn() {
      // Act
      let found =
        unqualify(
          "pub fn query(db) {\n  db |> client.query |> client.execute\n}",
          [
            client,
          ],
        )

      // Assert
      found
      |> should
      |> be_equal(#(
        ["import dream_postgres/client.{execute}"],
        "pub fn query(db) {\n  db |> client.query |> execute\n}",
      ))
      |> or_fail_with("Expected client.query to keep its module")
    }),
    it("gives a name of two imports to the first import", fn() {
      // Act
      let found =
        unqualify("client.int(id) decode.int decode.field", [client, decode])

      // Assert
      found
      |> should
      |> be_equal(#(
        [
          "import dream_postgres/client.{int}",
          "import gleam/dynamic/decode.{field}",
        ],
        "int(id) decode.int field",
      ))
      |> or_fail_with("Expected decode.int to keep its module")
    }),
    it("imports a type that a prelude constructor has the name of", fn() {
      // Act
      let found =
        unqualify("Error(dream_errors.NotFound(x)): dream_errors.Error", [
          errors,
        ])

      // Assert
      found
      |> should
      |> be_equal(#(
        ["import dream_errors.{type Error, NotFound}"],
        "Error(NotFound(x)): Error",
      ))
      |> or_fail_with("Expected the type Error to be bare")
    }),
    it("keeps the module of a type that a type of the code has", fn() {
      // Act
      let found = unqualify("Connection(a: client.Connection)", [client])

      // Assert
      found
      |> should
      |> be_equal(#(
        ["import dream_postgres/client"],
        "Connection(a: client.Connection)",
      ))
      |> or_fail_with("Expected client.Connection to keep its module")
    }),
    it("imports a record of another model as a type and a constructor", fn() {
      // Act
      let found = unqualify("Decoder(user.User) user.User(id:)", [user])

      // Assert
      found
      |> should
      |> be_equal(#(
        ["import app/models/user.{type User, User}"],
        "Decoder(User) User(id:)",
      ))
      |> or_fail_with("Expected the type and the constructor User")
    }),
    it("changes no string, comment or field", fn() {
      // Act
      let found =
        unqualify(
          "\"client.query \\\" client.int\" // client.text\nreturned.query [_, ..query] client.query client.int",
          [client],
        )

      // Assert
      found
      |> should
      |> be_equal(#(
        ["import dream_postgres/client.{int}"],
        "\"client.query \\\" client.int\" // client.text\nreturned.query [_, ..query] client.query int",
      ))
      |> or_fail_with(
        "Expected the string, the comment and the field to stay, and ..query to take the name",
      )
    }),
    it("leaves out an import that the code does not use", fn() {
      // Act
      let found = unqualify("1 + client", [client, decode])

      // Assert
      found
      |> should
      |> be_equal(#([], "1 + client"))
      |> or_fail_with("Expected no import")
    }),
    it("reads to the end of an open string, comment or name", fn() {
      // Act
      let found = #(
        unqualify("\"client.query", [client]),
        unqualify("// client.query", [client]),
        unqualify("client.query", [client]),
        unqualify("client..query", [client]),
      )

      // Assert
      found
      |> should
      |> be_equal(#(
        #([], "\"client.query"),
        #([], "// client.query"),
        #(["import dream_postgres/client.{query}"], "query"),
        #([], "client..query"),
      ))
      |> or_fail_with("Expected each text to end where the code ends")
    }),
  ])
}
