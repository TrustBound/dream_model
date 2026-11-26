//// Tests for `dream_model/postgres/wire`.
////
//// `parse_url` is pure. The connection tests run on a real PostgreSQL
//// server, and on a fake server for what a real server never sends: other
//// authentication methods, TLS, and malformed messages.

import dream_model/postgres/scram.{
  MalformedServerMessage, NonceMismatch, ServerSignatureMismatch,
}
import dream_model/postgres/wire.{
  type Connection, type WireError, CleartextWithoutTls, Config, ConnectFailed,
  Description, Field, InvalidUrl, NoTls, Notice, PasswordMissing,
  ProtocolViolation, ScramFailed, ServerError, SocketFailed, TlsFailed,
  TlsRefused, TlsWithVerification, TlsWithoutVerification,
  UnsupportedAuthentication, close, error_to_string, execute, get_field,
  get_parameter, parse_url, simple_query,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/fake_server.{
  type Step, AcceptTls, AnswerSslRequest, Close, ExpectMessage, ReceiveMessage,
  ReceiveStartup, ScramServerFirst, Send, authentication_ok, message, ready,
  start, start_with_query,
}
import fixtures/servers.{default_database}
import gleam/list.{append, filter_map}
import gleam/option.{None, Some}
import gleam/result.{map_error, try, unwrap}
import gleam/string.{inspect}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/postgres/wire", [
    parse_url_tests(),
    parse_url_error_tests(),
    server_tests(version),
    authentication_tests(),
    tls_tests(version),
    malformed_message_tests(),
    error_to_string_tests(),
  ])
}

// --- parse_url -------------------------------------------------------------

fn url_case(name: String, url: String, expected: wire.Config) {
  it(name, fn() {
    // Arrange
    let text = url

    // Act
    let parsed = parse_url(text)

    // Assert
    parsed
    |> should
    |> be_equal(Ok(expected))
    |> or_fail_with("Expected the config of " <> url)
  })
}

fn parse_url_tests() {
  group("parse_url", [
    url_case(
      "reads every part of a full URL",
      "postgresql://dream:dream@localhost:5416/dream_test",
      Config("localhost", 5416, "dream", Some("dream"), "dream_test", NoTls, ""),
    ),
    url_case(
      "takes port 5432 and the user's database by default",
      "postgres://alice@db.example.com",
      Config("db.example.com", 5432, "alice", None, "alice", NoTls, ""),
    ),
    url_case(
      "takes the user's database for the path /",
      "postgres://alice@db.example.com/",
      Config("db.example.com", 5432, "alice", None, "alice", NoTls, ""),
    ),
    url_case(
      "decodes percent escapes",
      "postgresql://a%40b:p%3Ass@h/d%20b",
      Config("h", 5432, "a@b", Some("p:ss"), "d b", NoTls, ""),
    ),
    url_case(
      "reads sslmode=require",
      "postgresql://u@h/d?sslmode=require",
      Config("h", 5432, "u", None, "d", TlsWithoutVerification, ""),
    ),
    url_case(
      "reads sslmode=verify-full",
      "postgresql://u@h/d?sslmode=verify-full",
      Config("h", 5432, "u", None, "d", TlsWithVerification, ""),
    ),
    url_case(
      "ends the password at the last @ before the path",
      "postgresql://app:p@ss@db.example.com:6543/app?sslmode=require",
      Config(
        "db.example.com",
        6543,
        "app",
        Some("p@ss"),
        "app",
        TlsWithoutVerification,
        "",
      ),
    ),
    url_case(
      "reads sslmode=disable",
      "postgresql://u@h/d?sslmode=disable",
      Config("h", 5432, "u", None, "d", NoTls, ""),
    ),
  ])
}

fn url_error_case(name: String, url: String, reason: String) {
  it(name, fn() {
    // Arrange
    let text = url

    // Act
    let parsed = parse_url(text)

    // Assert
    parsed
    |> should
    |> be_equal(Error(InvalidUrl(reason)))
    |> or_fail_with("Expected " <> url <> " to be refused")
  })
}

fn parse_url_error_tests() {
  group("parse_url errors", [
    url_error_case(
      "refuses text that is not a URL",
      "postgresql://h:port/d",
      "it is not a URL",
    ),
    url_error_case(
      "refuses another scheme",
      "http://u@h/d",
      "the scheme must be postgresql:// or postgres://",
    ),
    url_error_case(
      "refuses a URL without a host",
      "postgresql:",
      "it has no host",
    ),
    url_error_case(
      "refuses a URL with an empty host",
      "postgresql://u@/d",
      "it has no host",
    ),
    url_error_case(
      "refuses a URL without a user",
      "postgresql://h/d",
      "it has no user name",
    ),
    url_error_case(
      "refuses a URL with an empty user",
      "postgresql://:secret@h/d",
      "it has no user name",
    ),
    url_error_case(
      "refuses a bad escape in the user",
      "postgresql://%zz@h/d",
      "it has a bad percent escape",
    ),
    url_error_case(
      "refuses a bad escape in the password",
      "postgresql://u:%zz@h/d",
      "it has a bad percent escape",
    ),
    url_error_case(
      "refuses a bad escape in the database",
      "postgresql://u@h/%zz",
      "it has a bad percent escape",
    ),
    url_error_case(
      "refuses a query string that cannot be read",
      "postgresql://u@h/d?sslmode=%zz",
      "its query string cannot be read",
    ),
    url_error_case(
      "refuses an @ after the host, and names no part of the password",
      "postgresql://app:p/ss@db.example.com/app",
      "it has an @ after the host; write @, /, ? and # in the user name and the password as %40, %2F, %3F and %23",
    ),
    url_error_case(
      "refuses query keys that it does not support",
      "postgresql://u@h/d?sslmode=require&options=-c%20search_path%3Dapp&sslrootcert=ca.pem&options=x",
      "its query string has the keys options, sslrootcert, which dream_model does not support; the only supported key is sslmode",
    ),
    url_error_case(
      "refuses an sslmode that is not supported",
      "postgresql://u@h/d?sslmode=prefer",
      "sslmode prefer is not supported; use disable, require or verify-full",
    ),
  ])
}

// --- A real server ---------------------------------------------------------

fn connect_url(url: String) -> Result(Connection, WireError) {
  parse_url(url) |> try(wire.connect)
}

fn server_case(
  name: String,
  version: Int,
  run: fn(Connection) -> a,
  expected: a,
) {
  it(name, fn() {
    // Arrange
    let connection = servers.connect(version, default_database)

    // Act
    let actual = run(connection)
    let _ = close(connection)

    // Assert
    actual
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the server's answer")
  })
}

fn error_code(error: WireError) -> String {
  case error {
    ServerError(fields) -> get_field(fields, "C") |> unwrap("")
    other -> inspect(other)
  }
}

fn server_tests(version: Int) {
  group("on a real server", [
    server_case(
      "get_parameter returns a parameter that the server reported",
      version,
      get_parameter(_, "client_encoding"),
      Ok("UTF8"),
    ),
    server_case(
      "get_parameter returns an error for an unknown parameter",
      version,
      get_parameter(_, "no_such_parameter"),
      Error(Nil),
    ),
    server_case(
      "simple_query returns each value as text, and NULL as None",
      version,
      simple_query(_, "select 1, null::int, 'a'"),
      Ok([[Some("1"), None, Some("a")]]),
    ),
    server_case(
      "simple_query returns the rows of every statement",
      version,
      simple_query(_, "select 1; select 2"),
      Ok([[Some("1")], [Some("2")]]),
    ),
    server_case(
      "simple_query returns the server error with its fields",
      version,
      fn(connection) {
        simple_query(connection, "select 1 / 0")
        |> map_error(error_code)
      },
      Error("22012"),
    ),
    server_case(
      "the connection stays usable after an error",
      version,
      fn(connection) {
        let _ = simple_query(connection, "select 1 / 0")
        simple_query(connection, "select 3")
      },
      Ok([[Some("3")]]),
    ),
    server_case(
      "execute binds text parameters and NULL",
      version,
      execute(_, "select $1::int + 1, $2::text is null", [Some("41"), None]),
      Ok([[Some("42"), Some("t")]]),
    ),
    server_case(
      "describe returns the parameter types and the result columns",
      version,
      fn(connection) {
        wire.describe(
          connection,
          "select oid, relname from pg_class where oid = $1",
        )
        |> result.map(fn(description) {
          #(description.parameter_types, description.fields)
        })
      },
      Ok(
        #([26], [
          Field("oid", 1259, 1, 26),
          Field("relname", 1259, 2, 19),
        ]),
      ),
    ),
    server_case(
      "describe returns no columns for a statement without a result",
      version,
      fn(connection) {
        wire.describe(connection, "create temporary table t (a int)")
        |> result.map(fn(description) { description.fields })
      },
      Ok([]),
    ),
    server_case(
      "describe returns the notices that the server sent",
      version,
      fn(connection) {
        let _ = simple_query(connection, "set client_min_messages = log")
        let _ = simple_query(connection, "set debug_print_parse = on")
        wire.describe(connection, "select 1")
        |> result.map(fn(description) {
          filter_map(description.notices, fn(notice) {
            get_field(notice.fields, "M")
          })
        })
      },
      Ok(["parse tree:"]),
    ),
    it("connect sends the startup options", fn() {
      // Arrange
      let assert Ok(config) = parse_url(servers.url(version, default_database))
      let config = wire.Config(..config, options: "-c search_path=custom")
      let assert Ok(connection) = wire.connect(config)

      // Act
      let rows = simple_query(connection, "show search_path")
      let _ = close(connection)

      // Assert
      rows
      |> should
      |> be_equal(Ok([[Some("custom")]]))
      |> or_fail_with("Expected the search_path of the options")
    }),
    it("connect returns the server error for a wrong password", fn() {
      // Arrange
      let url =
        string.replace(
          servers.url(version, default_database),
          "dream:dream@",
          "dream:wrong@",
        )

      // Act
      let connected = connect_url(url)

      // Assert
      connected
      |> map_error(error_code)
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("28P01"))
      |> or_fail_with("Expected invalid_password")
    }),
    it("connect returns the server error for an unknown database", fn() {
      // Arrange
      let url = servers.url(version, "no_such_database")

      // Act
      let connected = connect_url(url)

      // Assert
      connected
      |> map_error(error_code)
      |> result.replace(Nil)
      |> should
      |> be_equal(Error("3D000"))
      |> or_fail_with("Expected invalid_catalog_name")
    }),
    it("connect returns ConnectFailed when nothing listens", fn() {
      // Arrange
      let url = "postgresql://u:p@127.0.0.1:1/d"

      // Act
      let connected = connect_url(url)

      // Assert
      connected
      |> result.replace(Nil)
      |> should
      |> be_equal(Error(ConnectFailed("127.0.0.1", 1, "econnrefused")))
      |> or_fail_with("Expected the connection to be refused")
    }),
  ])
}

// --- Authentication on a fake server ---------------------------------------

fn fake_case(name: String, steps: List(Step), expected) {
  fake_url_case(name, start(steps), expected)
}

fn fake_url_case(name: String, url: String, expected) {
  it(name, fn() {
    // Arrange
    let address = url

    // Act
    let connected = connect_url(address)
    let _ = result.map(connected, close)

    // Assert
    connected
    |> result.replace(Nil)
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the connection result")
  })
}

fn after_startup(answer: List(Step)) -> List(Step) {
  [ReceiveStartup, ..answer]
}

fn ready_steps() -> List(Step) {
  [
    Send(authentication_ok()),
    Send(message("S", <<"server_version":utf8, 0, "16.0":utf8, 0>>)),
    Send(message("K", <<1:32, 2:32>>)),
    Send(ready()),
  ]
}

fn authentication_tests() {
  group("authentication", [
    fake_case("accepts trust", after_startup(ready_steps()), Ok(Nil)),
    fake_url_case(
      "sends the cleartext password over TLS",
      start_with_query(
        [
          AcceptTls,
          ReceiveStartup,
          Send(message("R", <<3:32>>)),
          ExpectMessage(message("p", <<"secret":utf8, 0>>)),
          ..ready_steps()
        ],
        "?sslmode=require",
      ),
      Ok(Nil),
    ),
    fake_case(
      "refuses to send the cleartext password without TLS",
      after_startup([Send(message("R", <<3:32>>))]),
      Error(CleartextWithoutTls),
    ),
    fake_case(
      "sends the MD5 password",
      after_startup([
        Send(message("R", <<5:32, 1, 2, 3, 4>>)),
        ExpectMessage(
          message("p", <<
            "md529f38861b864472bf5b524749d1f0a88":utf8,
            0,
          >>),
        ),
        ..ready_steps()
      ]),
      Ok(Nil),
    ),
    fake_url_case(
      "returns PasswordMissing when the URL has no password",
      string.replace(
        start(after_startup([Send(message("R", <<5:32, 1, 2, 3, 4>>))])),
        "dream:secret@",
        "dream@",
      ),
      Error(PasswordMissing),
    ),
    fake_case(
      "refuses an authentication method it does not support",
      after_startup([Send(message("R", <<7:32>>))]),
      Error(UnsupportedAuthentication("7")),
    ),
    fake_case(
      "refuses SASL without SCRAM-SHA-256",
      after_startup([
        Send(message("R", <<10:32, "SCRAM-SHA-256-PLUS":utf8, 0, 0>>)),
      ]),
      Error(UnsupportedAuthentication("SASL SCRAM-SHA-256-PLUS")),
    ),
    fake_case(
      "refuses a malformed SCRAM server-first message",
      after_startup([
        Send(message("R", <<10:32, "SCRAM-SHA-256":utf8, 0, 0>>)),
        ReceiveMessage,
        Send(message("R", <<11:32, "garbage":utf8>>)),
      ]),
      Error(ScramFailed(MalformedServerMessage("garbage"))),
    ),
    fake_case(
      "refuses another message during SCRAM",
      after_startup([
        Send(message("R", <<10:32, "SCRAM-SHA-256":utf8, 0, 0>>)),
        ReceiveMessage,
        Send(authentication_ok()),
      ]),
      Error(ProtocolViolation(
        "unexpected message R during SCRAM authentication",
      )),
    ),
    fake_case(
      "refuses a server that cannot prove it knows the password",
      after_startup([
        Send(message("R", <<10:32, "SCRAM-SHA-256":utf8, 0, 0>>)),
        ScramServerFirst(<<"salt":utf8>>, 4096),
        ReceiveMessage,
        Send(message("R", <<12:32, "v=AAAA":utf8>>)),
      ]),
      Error(ScramFailed(ServerSignatureMismatch)),
    ),
    fake_case(
      "refuses another message during authentication",
      after_startup([Send(ready())]),
      Error(ProtocolViolation("unexpected message Z during authentication")),
    ),
    fake_case(
      "returns the server error during authentication",
      after_startup([
        Send(message("E", <<"C":utf8, "28000":utf8, 0, 0>>)),
      ]),
      Error(ServerError([#("C", "28000")])),
    ),
    fake_case(
      "returns the server error after authentication",
      after_startup([
        Send(authentication_ok()),
        Send(message("E", <<"C":utf8, "53300":utf8, 0, 0>>)),
      ]),
      Error(ServerError([#("C", "53300")])),
    ),
    fake_case(
      "returns SocketFailed when the server closes the connection",
      after_startup([Close]),
      Error(SocketFailed("closed")),
    ),
    fake_case(
      "refuses a message length below 4",
      after_startup([Send(<<"R":utf8, 0:32>>)]),
      Error(ProtocolViolation("a message length is below 4")),
    ),
    fake_case(
      "refuses a parameter without its terminator",
      after_startup([
        Send(authentication_ok()),
        Send(message("S", <<"abc":utf8>>)),
      ]),
      Error(ProtocolViolation("a string has no terminator")),
    ),
    fake_case(
      "refuses an error field without its terminator",
      after_startup([Send(message("E", <<"C":utf8, "28000":utf8>>))]),
      Error(ProtocolViolation("a string has no terminator")),
    ),
  ])
}

// --- TLS -------------------------------------------------------------------

fn tls_tests(version: Int) {
  group("TLS", [
    it("runs queries over TLS with sslmode=require", fn() {
      // Arrange
      let url =
        start_with_query(
          [
            AcceptTls,
            ReceiveStartup,
            ..append(ready_steps(), [
              ReceiveMessage,
              Send(message("D", <<1:16, 1:32, "7":utf8>>)),
              Send(ready()),
            ])
          ],
          "?sslmode=require",
        )
      let assert Ok(connection) = connect_url(url)

      // Act
      let rows = simple_query(connection, "select 7")
      let _ = close(connection)

      // Assert
      rows
      |> should
      |> be_equal(Ok([[Some("7")]]))
      |> or_fail_with("Expected the row over TLS")
    }),
    it(
      "returns TlsFailed when sslmode=verify-full cannot verify the server",
      fn() {
        // Arrange
        let url = start_with_query([AcceptTls], "?sslmode=verify-full")

        // Act
        let connected = connect_url(url)

        // Assert
        case connected {
          Error(TlsFailed(_)) -> True
          _ -> False
        }
        |> should
        |> be_equal(True)
        |> or_fail_with("Expected the TLS handshake to fail")
      },
    ),
    fake_url_case(
      "returns TlsRefused when the server does not offer TLS",
      servers.url(version, default_database) <> "?sslmode=require",
      Error(TlsRefused),
    ),
    fake_url_case(
      "refuses another answer to the TLS request",
      start_with_query([AnswerSslRequest(88)], "?sslmode=require"),
      Error(ProtocolViolation("unexpected answer to the TLS request")),
    ),
  ])
}

// --- Malformed messages ----------------------------------------------------

fn query_case(name: String, answer: List(BitArray), expected) {
  it(name, fn() {
    // Arrange
    let steps =
      [ReceiveStartup, ..ready_steps()]
      |> append([ReceiveMessage, ..list.map(answer, Send)])
      |> append([Send(ready())])
    let assert Ok(connection) = connect_url(start(steps))

    // Act
    let rows = simple_query(connection, "select 1")
    let _ = close(connection)

    // Assert
    rows
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the answer to the query")
  })
}

fn describe_case(name: String, answer: List(BitArray), expected) {
  it(name, fn() {
    // Arrange
    let steps =
      [ReceiveStartup, ..ready_steps()]
      |> append([
        ReceiveMessage,
        ReceiveMessage,
        ReceiveMessage,
        ..list.map(answer, Send)
      ])
      |> append([Send(ready())])
    let assert Ok(connection) = connect_url(start(steps))

    // Act
    let described = wire.describe(connection, "select 1")
    let _ = close(connection)

    // Assert
    described
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the answer to Describe")
  })
}

fn malformed(name: String) -> WireError {
  ProtocolViolation("malformed " <> name <> " message")
}

fn malformed_message_tests() {
  group("malformed messages", [
    it("closes the connection after a malformed response", fn() {
      // Arrange
      let steps =
        [ReceiveStartup, ..ready_steps()]
        |> append([
          ReceiveMessage,
          Send(message("D", <<>>)),
          Send(ready()),
          ReceiveMessage,
          Send(message("D", <<1:16, 1:32, "2":utf8>>)),
          Send(ready()),
        ])
      let assert Ok(connection) = connect_url(start(steps))

      // Act
      let first = simple_query(connection, "select 1")
      let second = simple_query(connection, "select 2")
      let _ = close(connection)

      // Assert
      #(first, second)
      |> should
      |> be_equal(#(Error(malformed("DataRow")), Error(SocketFailed("closed"))))
      |> or_fail_with("Expected the second query to fail on a closed socket")
    }),
    query_case(
      "refuses an empty DataRow",
      [message("D", <<>>)],
      Error(malformed("DataRow")),
    ),
    query_case(
      "refuses a DataRow with fewer values than its count",
      [message("D", <<2:16, 1:32, "1":utf8>>)],
      Error(malformed("DataRow")),
    ),
    query_case(
      "refuses a value that is not UTF-8",
      [message("D", <<1:16, 1:32, 255>>)],
      Error(ProtocolViolation("a text value is not UTF-8")),
    ),
    query_case(
      "refuses an empty RowDescription",
      [message("T", <<>>)],
      Error(malformed("RowDescription")),
    ),
    query_case(
      "refuses a RowDescription without its field data",
      [message("T", <<1:16, "a":utf8, 0, 1:32>>)],
      Error(malformed("RowDescription")),
    ),
    query_case(
      "refuses a NoticeResponse field without its terminator",
      [message("N", <<"M":utf8, "x":utf8>>)],
      Error(ProtocolViolation("a string has no terminator")),
    ),
    query_case(
      "returns the first error of a response",
      [
        message("E", <<"C":utf8, "1":utf8, 0, 0>>),
        message("E", <<"C":utf8, "2":utf8, 0, 0>>),
      ],
      Error(ServerError([#("C", "1")])),
    ),
    describe_case(
      "refuses an empty ParameterDescription",
      [message("t", <<>>)],
      Error(malformed("ParameterDescription")),
    ),
    describe_case(
      "refuses a ParameterDescription with fewer oids than its count",
      [message("t", <<2:16, 23:32>>)],
      Error(malformed("ParameterDescription")),
    ),
    describe_case(
      "returns the notices of Describe",
      [
        message("N", <<"M":utf8, "hello":utf8, 0, 0>>),
        message("n", <<>>),
      ],
      Ok(Description([], [], [Notice([#("M", "hello")])])),
    ),
  ])
}

// --- error_to_string -------------------------------------------------------

fn text_case(error: WireError, expected: String) {
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
    text_case(InvalidUrl("x"), "the PostgreSQL URL cannot be used: x"),
    text_case(
      ConnectFailed("h", 1, "econnrefused"),
      "cannot connect to PostgreSQL at h:1: econnrefused",
    ),
    text_case(
      SocketFailed("closed"),
      "the PostgreSQL connection failed: closed",
    ),
    text_case(
      TlsRefused,
      "the URL asks for TLS (sslmode), and the PostgreSQL server does not offer it",
    ),
    text_case(TlsFailed("x"), "the TLS handshake with PostgreSQL failed: x"),
    text_case(
      PasswordMissing,
      "PostgreSQL asks for a password, and the URL has none",
    ),
    text_case(
      CleartextWithoutTls,
      "PostgreSQL asks for the password in cleartext, and the connection has no TLS; add sslmode=require or sslmode=verify-full to the URL, or use SCRAM-SHA-256 on the server",
    ),
    text_case(
      UnsupportedAuthentication("7"),
      "PostgreSQL asks for an authentication method that dream_model does not support: 7",
    ),
    text_case(
      ScramFailed(NonceMismatch),
      "the server nonce does not start with the client nonce, so the SCRAM exchange stopped",
    ),
    text_case(
      ProtocolViolation("x"),
      "PostgreSQL sent a message that the protocol does not allow: x",
    ),
    text_case(
      ServerError([
        #("S", "FATAL"),
        #("C", "28P01"),
        #("M", "password authentication failed"),
        #("D", "more"),
      ]),
      "PostgreSQL FATAL 28P01: password authentication failed (more)",
    ),
    text_case(ServerError([]), "PostgreSQL ERROR : "),
  ])
}
