//// Tests for `dream_model/postgres/tree`.

import dream_model/postgres/node
import dream_model/postgres/tree.{
  NoTreeNotice, QueryFailed, TokenTooLong, UnknownVersion, UnreadableTree,
  VersionNotTested, VersionTooOld, WrongQueryCount,
}
import dream_model/postgres/wire
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/fake_server.{ReceiveMessage, ReceiveStartup, Send}
import fixtures/servers
import gleam/list
import gleam/result
import gleam/string

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/postgres/tree", [
    check_version_tests(),
    capture_tests(version),
    error_to_string_tests(),
  ])
}

fn version_case(text: String, expected: Result(Int, tree.TreeError)) {
  it("check_version reads " <> string.inspect(text), fn() {
    // Arrange
    let server_version = text

    // Act
    let checked = tree.check_version(server_version)

    // Assert
    checked
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the version check of " <> text)
  })
}

fn check_version_tests() {
  group("check_version", [
    version_case("16.16", Ok(16)),
    version_case("19beta1", Ok(19)),
    version_case("15.20", Error(VersionTooOld("15.20"))),
    version_case("20.0", Error(VersionNotTested("20.0"))),
    version_case("devel", Error(UnknownVersion("devel"))),
  ])
}

fn tree_connection(version: Int) -> wire.Connection {
  let assert Ok(config) =
    wire.parse_url(servers.url(version, servers.default_database))
  let assert Ok(connection) =
    wire.connect(wire.Config(..config, options: tree.tree_options))
  connection
}

fn capture_case(
  name: String,
  version: Int,
  setup: String,
  sql: String,
  expected: Result(String, tree.TreeError),
) {
  it(name, fn() {
    // Arrange
    let connection = tree_connection(version)
    let _ = wire.simple_query(connection, setup)

    // Act
    let captured = tree.capture(connection, sql)
    let _ = wire.close(connection)

    // Assert
    captured
    |> result.map(fn(captured) { node.node_name(captured.query) })
    |> result.map_error(without_server_fields)
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the capture result")
  })
}

/// Keeps only the SQLSTATE of a server error, so the test does not depend
/// on the file and line that PostgreSQL reports.
fn without_server_fields(error: tree.TreeError) -> tree.TreeError {
  case error {
    QueryFailed(wire.ServerError(fields)) ->
      QueryFailed(
        wire.ServerError(list.filter(fields, fn(field) { field.0 == "C" })),
      )
    other -> other
  }
}

fn capture_tests(version: Int) {
  group("capture", [
    capture_case(
      "returns the query that returns the result",
      version,
      "select 1",
      "select 1 as a",
      Ok("QUERY"),
    ),
    capture_case(
      "skips the other notices",
      version,
      "set debug_print_parse = on",
      "select 1 as a",
      Ok("QUERY"),
    ),
    capture_case(
      "returns QueryFailed when PostgreSQL rejects the statement",
      version,
      "select 1",
      "select nope",
      Error(QueryFailed(wire.ServerError([#("C", "42703")]))),
    ),
    capture_case(
      "returns TokenTooLong for a name of 77 bytes or more with escapes",
      version,
      "select 1",
      "select 1 as \"" <> string.repeat("(", 40) <> "\"",
      Error(TokenTooLong),
    ),
    capture_case(
      "returns WrongQueryCount when a rule leaves no query",
      version,
      "create temporary table quiet (a int); create rule quiet_nothing as on insert to quiet do instead nothing",
      "insert into quiet values (1)",
      Error(WrongQueryCount(0, 0)),
    ),
    it("returns NoTreeNotice on a connection without the tree options", fn() {
      // Arrange
      let connection = servers.connect(version, servers.default_database)

      // Act
      let captured = tree.capture(connection, "select 1")
      let _ = wire.close(connection)

      // Assert
      captured
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(NoTreeNotice))
      |> or_fail_with("Expected NoTreeNotice")
    }),
    it("returns UnreadableTree for a notice that is not node text", fn() {
      // Arrange
      let notice =
        fake_server.message("N", <<
          "M":utf8, "rewritten parse tree:":utf8, 0, "D":utf8, "({QUERY":utf8, 0,
          0,
        >>)
      let url =
        fake_server.start([
          ReceiveStartup,
          Send(fake_server.authentication_ok()),
          Send(fake_server.ready()),
          ReceiveMessage,
          ReceiveMessage,
          ReceiveMessage,
          Send(notice),
          Send(fake_server.ready()),
        ])
      let assert Ok(connection) =
        wire.parse_url(url) |> result.try(wire.connect)

      // Act
      let captured = tree.capture(connection, "select 1")
      let _ = wire.close(connection)

      // Assert
      captured
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(UnreadableTree(node.UnexpectedEnd)))
      |> or_fail_with("Expected UnreadableTree")
    }),
  ])
}

fn text_case(error: tree.TreeError, expected: String) {
  it("describes " <> string.inspect(error), fn() {
    // Arrange
    let value = error

    // Act
    let text = tree.error_to_string(value)

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
      VersionTooOld("15.20"),
      "PostgreSQL 15.20 is not supported: dream_model needs PostgreSQL 16 or newer, because older versions do not record which columns an outer join can make NULL",
    ),
    text_case(
      VersionNotTested("20.0"),
      "PostgreSQL 20.0 is not supported yet: dream_model is tested on PostgreSQL 16 to 19, and it reads PostgreSQL's analyzed query, whose form can change in each major version",
    ),
    text_case(
      UnknownVersion("devel"),
      "cannot read the PostgreSQL version from \"devel\"",
    ),
    text_case(
      QueryFailed(wire.TlsRefused),
      "the URL asks for TLS (sslmode), and the PostgreSQL server does not offer it",
    ),
    text_case(
      NoTreeNotice,
      "PostgreSQL sent no analyzed query; the connection must use the options -c debug_print_rewritten=on -c debug_pretty_print=off -c client_min_messages=log",
    ),
    text_case(
      TokenTooLong,
      "the query has a name that is too long to read from PostgreSQL's analyzed query (77 bytes or more with its escapes); use a shorter name",
    ),
    text_case(
      UnreadableTree(node.UnexpectedEnd),
      "cannot read PostgreSQL's analyzed query: the node text ends too early",
    ),
    text_case(
      UnreadableTree(node.UnexpectedToken(")")),
      "cannot read PostgreSQL's analyzed query: unexpected token ) in the node text",
    ),
    text_case(
      UnreadableTree(node.NotAnInteger("x")),
      "cannot read PostgreSQL's analyzed query: x in a list of numbers is not a number",
    ),
    text_case(
      WrongQueryCount(2, 0),
      "rewriting gave 2 queries, and 0 of them return the result; dream_model needs exactly one (rules can cause this)",
    ),
  ])
}
