//// Tests for `dream_model/nullability`: connecting, the refusals, the
//// messages and the row check. The attack tests check `analyze`.

import dream_model/nullability.{
  type AnalysisError, BrokenPromise, Column, ColumnCountMismatch, DatabaseFailed,
  HintNamesTableColumn, HintNamesUnknownColumn, HintNotNeeded, HintsRefused,
  TreeFailed, analyze, broken_promise_to_string, check_row, error_to_string,
}
import dream_model/nullability/reason.{
  ColumnAllowsNull, Computed, CountAggregate, NotNullHint, NotNullInSchema,
  Table,
}
import dream_model/postgres/tree.{TokenTooLong, VersionNotTested, VersionTooOld}
import dream_model/postgres/wire.{
  ConnectFailed, InvalidUrl, TlsRefused, get_parameter,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/fake_server.{
  type Step, ReceiveMessage, ReceiveStartup, Send, authentication_ok, message,
  ready, start, start_for_connections,
}
import fixtures/servers.{default_database}
import gleam/option.{None, Some}
import gleam/result.{replace}
import gleam/string.{inspect}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/nullability", [
    connect_tests(version),
    check_row_tests(),
    error_to_string_tests(),
  ])
}

fn startup(server_version: String) -> List(Step) {
  [
    ReceiveStartup,
    Send(authentication_ok()),
    Send(message("S", <<"server_version":utf8, 0, server_version:utf8, 0>>)),
    Send(ready()),
  ]
}

fn connect_tests(version: Int) {
  group("connect", [
    it("returns the version of the server", fn() {
      // Arrange
      let url = servers.url(version, default_database)

      // Act
      let assert Ok(analyzer) = nullability.connect(url)
      let connected = nullability.version(analyzer)
      let _ = nullability.close(analyzer)

      // Assert
      connected
      |> should
      |> be_equal(version)
      |> or_fail_with("Expected the server version")
    }),
    it("refuses PostgreSQL 15", fn() {
      // Arrange
      let admin = servers.connect(15, default_database)
      let assert Ok(server_version) = get_parameter(admin, "server_version")
      let _ = wire.close(admin)

      // Act
      let connected = nullability.connect(servers.url(15, default_database))

      // Assert
      connected
      |> replace(Nil)
      |> should
      |> be_equal(Error(TreeFailed(VersionTooOld(server_version))))
      |> or_fail_with("Expected PostgreSQL 15 to be refused")
    }),
    it("refuses a version newer than the newest tested one", fn() {
      // Arrange
      let url = start(startup("20.0"))

      // Act
      let connected = nullability.connect(url)

      // Assert
      connected
      |> replace(Nil)
      |> should
      |> be_equal(Error(TreeFailed(VersionNotTested("20.0"))))
      |> or_fail_with("Expected PostgreSQL 20 to be refused")
    }),
    it("returns DatabaseFailed for a URL that cannot be used", fn() {
      // Arrange
      let url = "http://example.com"

      // Act
      let connected = nullability.connect(url)

      // Assert
      connected
      |> replace(Nil)
      |> should
      |> be_equal(
        Error(
          DatabaseFailed(InvalidUrl(
            "the scheme must be postgresql:// or postgres://",
          )),
        ),
      )
      |> or_fail_with("Expected the URL to be refused")
    }),
    it("returns DatabaseFailed when the server is not reachable", fn() {
      // Arrange
      let url = "postgresql://u:p@127.0.0.1:1/d"

      // Act
      let connected = nullability.connect(url)

      // Assert
      connected
      |> replace(Nil)
      |> should
      |> be_equal(
        Error(DatabaseFailed(ConnectFailed("127.0.0.1", 1, "econnrefused"))),
      )
      |> or_fail_with("Expected the connection to fail")
    }),
    it("returns DatabaseFailed when the second connection fails", fn() {
      // Arrange
      let url = start(startup("16.0"))

      // Act
      let connected = nullability.connect(url)

      // Assert
      case connected {
        Error(DatabaseFailed(ConnectFailed(..))) -> True
        _ -> False
      }
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected the tree connection to fail")
    }),
    it("analyze refuses a tree and a Describe that disagree", fn() {
      // Arrange
      let tree_text =
        "({QUERY :commandType 1 :canSetTag true :rtable <> :targetList ({TARGETENTRY :expr {CONST :constisnull false} :resno 1 :resjunk false}) :returningList <>})"
      let row_description =
        message("T", <<
          2:16, "a":utf8, 0, 0:32, 0:16, 23:32, 4:16, -1:32, 0:16, "b":utf8, 0,
          0:32, 0:16, 23:32, 4:16, -1:32, 0:16,
        >>)
      let url =
        start_for_connections([
          startup("16.0"),
          list_append(startup("16.0"), [
            ReceiveMessage,
            ReceiveMessage,
            ReceiveMessage,
            Send(
              message("N", <<
                "M":utf8, "rewritten parse tree:":utf8, 0, "D":utf8,
                tree_text:utf8, 0, 0,
              >>),
            ),
            Send(message("t", <<0:16>>)),
            Send(row_description),
            Send(ready()),
          ]),
        ])
      let assert Ok(analyzer) = nullability.connect(url)

      // Act
      let analyzed = analyze(analyzer, "select 1 as a, 2 as b")
      let _ = nullability.close(analyzer)

      // Assert
      analyzed
      |> replace(Nil)
      |> should
      |> be_equal(
        Error(ColumnCountMismatch(tree_columns: 1, described_columns: 2)),
      )
      |> or_fail_with("Expected ColumnCountMismatch")
    }),
  ])
}

fn list_append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..list_append(rest, second)]
  }
}

fn hinted_column() -> nullability.Column {
  Column("n", 23, True, Computed, NotNullHint)
}

fn check_row_tests() {
  group("check_row", [
    it("returns BrokenPromise for NULL in a hinted column", fn() {
      // Arrange
      let columns = [
        Column("a", 23, False, Table, ColumnAllowsNull),
        hinted_column(),
      ]

      // Act
      let checked = check_row(columns, "newest", [None, None])

      // Assert
      checked
      |> should
      |> be_equal(Error(BrokenPromise("newest", "n")))
      |> or_fail_with("Expected the broken promise")
    }),
    it("accepts NULL in a column without a hint", fn() {
      // Arrange
      let columns = [
        Column("a", 23, False, Table, ColumnAllowsNull),
        hinted_column(),
      ]

      // Act
      let checked = check_row(columns, "newest", [None, Some("1")])

      // Assert
      checked
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the row to pass")
    }),
    it("broken_promise_to_string names the query and the column", fn() {
      // Arrange
      let promise = BrokenPromise("newest", "n")

      // Act
      let text = broken_promise_to_string(promise)

      // Assert
      text
      |> should
      |> be_equal(
        "newest: the SQL file promised 'n' is never NULL, and PostgreSQL returned NULL",
      )
      |> or_fail_with("Expected the promise message")
    }),
  ])
}

fn text_case(error: AnalysisError, expected: String) {
  it("describes " <> inspect(error), fn() {
    // Arrange
    let value = error

    // Act
    let text = error_to_string(value)

    // Assert
    text
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the message")
  })
}

fn error_to_string_tests() {
  group("error_to_string", [
    text_case(
      DatabaseFailed(TlsRefused),
      "the URL asks for TLS (sslmode), and the PostgreSQL server does not offer it",
    ),
    text_case(
      TreeFailed(TokenTooLong),
      "the query has a name that is too long to read from PostgreSQL's analyzed query (77 bytes or more with its escapes); use a shorter name",
    ),
    text_case(
      ColumnCountMismatch(1, 2),
      "the analyzed query has 1 result columns, and Describe reported 2",
    ),
    text_case(
      HintsRefused([
        HintNamesTableColumn("email", NotNullInSchema),
        HintNotNeeded("n", CountAggregate),
        HintNamesUnknownColumn("nope"),
      ]),
      "hint 'not null: email' names a table column; the schema decides it (NOT NULL in schema); hint 'not null: n' is not needed: the column is never NULL by rule (count(...) never returns NULL); remove the hint; hint names 'nope', which is not a result column",
    ),
  ])
}
