//// A small PostgreSQL client for the frontend/backend protocol 3.0.
////
//// dream_model needs things that a general client hides: every
//// NoticeResponse (PostgreSQL sends the analyzed query in one), and the
//// table oid and column number of each result column from Describe. This
//// client gives exactly that, and nothing more:
////
//// - startup with the `options` parameter, over TCP or TLS
//// - trust, cleartext, MD5 and SCRAM-SHA-256 authentication
//// - simple queries, with each value as text
//// - Parse and Describe of an unnamed statement
//// - Parse, Bind and Execute with text parameters
////
//// Every failure is an `Error` value. A PostgreSQL ErrorResponse keeps all
//// of its fields.

import dream_model/postgres/scram
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// How the connection uses TLS. It comes from the `sslmode` of the URL.
pub type TlsMode {
  /// No TLS (`sslmode=disable`, or no `sslmode`).
  NoTls
  /// TLS, without a check of the server certificate (`sslmode=require`).
  TlsWithoutVerification
  /// TLS, with a check of the certificate chain against the system CA
  /// certificates and of the host name (`sslmode=verify-full`).
  TlsWithVerification
}

/// The settings of one connection.
pub type Config {
  Config(
    host: String,
    port: Int,
    user: String,
    password: Option(String),
    database: String,
    tls: TlsMode,
    /// The value of the startup `options` parameter, for example
    /// `-c client_min_messages=log`. Empty means no `options` parameter.
    options: String,
  )
}

/// A result column of a described statement, from RowDescription.
pub type Field {
  Field(
    name: String,
    /// The oid of the table of the column, or 0 when the column is not a
    /// plain table column.
    table_oid: Int,
    /// The column number in that table, or 0.
    column_number: Int,
    type_oid: Int,
  )
}

/// A NoticeResponse: each field as its one-letter code and its value, for
/// example `#("M", "rewritten parse tree:")`.
pub type Notice {
  Notice(fields: List(#(String, String)))
}

/// What Parse and Describe tell about a statement.
pub type Description {
  Description(
    parameter_types: List(Int),
    fields: List(Field),
    notices: List(Notice),
  )
}

/// A connection failure or an error that PostgreSQL reported.
pub type WireError {
  /// The connection URL cannot be used.
  InvalidUrl(reason: String)
  /// The TCP connection failed.
  ConnectFailed(host: String, port: Int, reason: String)
  /// Sending or receiving on an open connection failed.
  SocketFailed(reason: String)
  /// The URL asks for TLS, and the server does not offer it.
  TlsRefused
  /// The TLS handshake failed.
  TlsFailed(reason: String)
  /// The server asks for a password, and the URL has none.
  PasswordMissing
  /// The server asks for an authentication method that this client does
  /// not support. The value is the code of the authentication request.
  UnsupportedAuthentication(method: String)
  /// The SCRAM exchange failed on the client side.
  ScramFailed(error: scram.ScramError)
  /// The server sent something that the protocol does not allow.
  ProtocolViolation(reason: String)
  /// PostgreSQL sent an ErrorResponse. Each field is its one-letter code
  /// and its value: `C` is the SQLSTATE code, `M` the message, `D` the
  /// detail, and so on.
  ServerError(fields: List(#(String, String)))
}

/// An open connection.
pub opaque type Connection {
  Connection(socket: Socket, parameters: Dict(String, String))
}

type Socket

@external(erlang, "dream_model_wire_ffi", "connect")
fn connect_socket(
  host: String,
  port: Int,
  timeout_milliseconds: Int,
) -> Result(Socket, String)

@external(erlang, "dream_model_wire_ffi", "send")
fn send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "dream_model_wire_ffi", "receive_exactly")
fn receive_exactly(
  socket: Socket,
  length: Int,
  timeout_milliseconds: Int,
) -> Result(BitArray, String)

@external(erlang, "dream_model_wire_ffi", "start_tls")
fn start_tls(
  socket: Socket,
  host: String,
  verify_host: Bool,
  timeout_milliseconds: Int,
) -> Result(Socket, String)

@external(erlang, "dream_model_wire_ffi", "close")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "dream_model_wire_ffi", "split_at_zero")
fn split_at_zero(bytes: BitArray) -> Result(#(BitArray, BitArray), Nil)

const timeout_milliseconds = 60_000

const protocol_version = 196_608

const ssl_request_code = 80_877_103

/// Reads a `postgresql://` or `postgres://` URL:
/// `postgresql://user:password@host:port/database?sslmode=require`.
///
/// The port is 5432 when the URL has none, and the database is the user
/// name when the URL has none. `sslmode` can be `disable`, `require` or
/// `verify-full`.
pub fn parse_url(url: String) -> Result(Config, WireError) {
  use parsed <- result.try(
    uri.parse(url) |> result.replace_error(InvalidUrl("it is not a URL")),
  )
  use Nil <- result.try(check_scheme(parsed.scheme))
  use host <- result.try(
    option.to_result(parsed.host, InvalidUrl("it has no host"))
    |> result.try(require_text(_, "it has no host")),
  )
  use #(user, password) <- result.try(parse_user_information(parsed.userinfo))
  use database <- result.try(parse_database(parsed.path, user))
  use tls <- result.try(parse_tls_mode(parsed.query))
  Ok(Config(
    host:,
    port: option.unwrap(parsed.port, 5432),
    user:,
    password:,
    database:,
    tls:,
    options: "",
  ))
}

/// Opens a connection and logs in.
pub fn connect(config: Config) -> Result(Connection, WireError) {
  use socket <- result.try(
    connect_socket(config.host, config.port, timeout_milliseconds)
    |> result.map_error(ConnectFailed(config.host, config.port, _)),
  )
  let started = {
    use socket <- result.try(negotiate_tls(socket, config))
    use Nil <- result.try(send_bytes(socket, startup_message(config)))
    use Nil <- result.try(authenticate(socket, config))
    use parameters <- result.try(receive_parameters(socket, dict.new()))
    Ok(Connection(socket:, parameters:))
  }
  result.map_error(started, close_after_failure(socket, _))
}

/// Returns a run-time parameter that the server reported at startup, for
/// example `server_version`.
pub fn get_parameter(
  connection: Connection,
  name: String,
) -> Result(String, Nil) {
  dict.get(connection.parameters, name)
}

/// Runs SQL with the simple query protocol. The text may hold more than one
/// statement. Returns the rows of every statement, each value as text, or
/// the first error.
pub fn simple_query(
  connection: Connection,
  sql: String,
) -> Result(List(List(Option(String))), WireError) {
  use response <- result.try(request(connection, message("Q", c_string(sql))))
  Ok(response.rows)
}

/// Parses and describes `sql` as the unnamed statement. Returns the
/// parameter types, the result columns and every notice that the server
/// sent meanwhile.
pub fn describe(
  connection: Connection,
  sql: String,
) -> Result(Description, WireError) {
  let messages =
    bit_array.concat([
      parse_message(sql),
      message("D", <<"S":utf8, 0>>),
      message("S", <<>>),
    ])
  use response <- result.try(request(connection, messages))
  Ok(Description(
    parameter_types: response.parameter_types,
    fields: response.fields,
    notices: response.notices,
  ))
}

/// Runs one statement with the extended protocol. Each parameter is text,
/// and `None` is NULL. Returns the rows, each value as text.
pub fn execute(
  connection: Connection,
  sql: String,
  parameters: List(Option(String)),
) -> Result(List(List(Option(String))), WireError) {
  let messages =
    bit_array.concat([
      parse_message(sql),
      message("B", bind_body(parameters)),
      message("E", <<0, 0:32>>),
      message("S", <<>>),
    ])
  use response <- result.try(request(connection, messages))
  Ok(response.rows)
}

/// Says goodbye to the server and closes the connection. Returns the
/// error when the goodbye message cannot be sent, for example because the
/// server already closed the connection; the socket is closed either way.
pub fn close(connection: Connection) -> Result(Nil, WireError) {
  let sent = send_bytes(connection.socket, message("X", <<>>))
  close_socket(connection.socket)
  sent
}

/// Returns the value of one field of an ErrorResponse or NoticeResponse,
/// for example `"C"` for the SQLSTATE code.
pub fn get_field(
  fields: List(#(String, String)),
  code: String,
) -> Result(String, Nil) {
  list.key_find(fields, code)
}

/// Returns a readable message for a connection or server error.
pub fn error_to_string(error: WireError) -> String {
  case error {
    InvalidUrl(reason) -> "the PostgreSQL URL cannot be used: " <> reason
    ConnectFailed(host, port, reason) ->
      "cannot connect to PostgreSQL at "
      <> host
      <> ":"
      <> int.to_string(port)
      <> ": "
      <> reason
    SocketFailed(reason) -> "the PostgreSQL connection failed: " <> reason
    TlsRefused ->
      "the URL asks for TLS (sslmode), and the PostgreSQL server does not offer it"
    TlsFailed(reason) -> "the TLS handshake with PostgreSQL failed: " <> reason
    PasswordMissing -> "PostgreSQL asks for a password, and the URL has none"
    UnsupportedAuthentication(method) ->
      "PostgreSQL asks for an authentication method that dream_model does not support: "
      <> method
    ScramFailed(error) -> scram.error_to_string(error)
    ProtocolViolation(reason) ->
      "PostgreSQL sent a message that the protocol does not allow: " <> reason
    ServerError(fields) -> server_error_to_string(fields)
  }
}

fn server_error_to_string(fields: List(#(String, String))) -> String {
  let severity = get_field(fields, "S") |> result.unwrap("ERROR")
  let code = get_field(fields, "C") |> result.unwrap("")
  let text = get_field(fields, "M") |> result.unwrap("")
  let detail =
    get_field(fields, "D")
    |> result.map(fn(detail) { " (" <> detail <> ")" })
    |> result.unwrap("")
  "PostgreSQL " <> severity <> " " <> code <> ": " <> text <> detail
}

// --- URL -------------------------------------------------------------------

fn check_scheme(scheme: Option(String)) -> Result(Nil, WireError) {
  case scheme {
    Some("postgresql") | Some("postgres") -> Ok(Nil)
    _ -> Error(InvalidUrl("the scheme must be postgresql:// or postgres://"))
  }
}

fn require_text(text: String, reason: String) -> Result(String, WireError) {
  case text {
    "" -> Error(InvalidUrl(reason))
    _ -> Ok(text)
  }
}

fn parse_user_information(
  information: Option(String),
) -> Result(#(String, Option(String)), WireError) {
  let no_user = InvalidUrl("it has no user name")
  use information <- result.try(option.to_result(information, no_user))
  let #(user, password) = case string.split_once(information, ":") {
    Ok(#(user, password)) -> #(user, Some(password))
    Error(Nil) -> #(information, None)
  }
  use user <- result.try(percent_decode(user))
  use user <- result.try(require_text(user, "it has no user name"))
  use password <- result.try(case password {
    Some(password) -> percent_decode(password) |> result.map(Some)
    None -> Ok(None)
  })
  Ok(#(user, password))
}

/// With a host in the URL, the path is empty or starts with `/`.
fn parse_database(path: String, user: String) -> Result(String, WireError) {
  case path {
    "" | "/" -> Ok(user)
    _ -> percent_decode(string.drop_start(path, 1))
  }
}

fn percent_decode(text: String) -> Result(String, WireError) {
  uri.percent_decode(text)
  |> result.replace_error(InvalidUrl("it has a bad percent escape"))
}

fn parse_tls_mode(query: Option(String)) -> Result(TlsMode, WireError) {
  use pairs <- result.try(
    uri.parse_query(option.unwrap(query, ""))
    |> result.replace_error(InvalidUrl("its query string cannot be read")),
  )
  case list.key_find(pairs, "sslmode") {
    Error(Nil) | Ok("disable") -> Ok(NoTls)
    Ok("require") -> Ok(TlsWithoutVerification)
    Ok("verify-full") -> Ok(TlsWithVerification)
    Ok(mode) ->
      Error(InvalidUrl(
        "sslmode "
        <> mode
        <> " is not supported; use disable, require or verify-full",
      ))
  }
}

// --- Startup ---------------------------------------------------------------

fn close_after_failure(socket: Socket, error: WireError) -> WireError {
  close_socket(socket)
  error
}

fn negotiate_tls(socket: Socket, config: Config) -> Result(Socket, WireError) {
  case config.tls {
    NoTls -> Ok(socket)
    TlsWithoutVerification -> upgrade_to_tls(socket, config.host, False)
    TlsWithVerification -> upgrade_to_tls(socket, config.host, True)
  }
}

fn upgrade_to_tls(
  socket: Socket,
  host: String,
  verify_host: Bool,
) -> Result(Socket, WireError) {
  use Nil <- result.try(send_bytes(socket, <<8:32, ssl_request_code:32>>))
  use answer <- result.try(receive_bytes(socket, 1))
  case answer {
    <<"S":utf8>> ->
      start_tls(socket, host, verify_host, timeout_milliseconds)
      |> result.map_error(TlsFailed)
    <<"N":utf8>> -> Error(TlsRefused)
    _ -> Error(ProtocolViolation("unexpected answer to the TLS request"))
  }
}

fn startup_message(config: Config) -> BitArray {
  let options = case config.options {
    "" -> []
    options -> [#("options", options)]
  }
  let parameters =
    [
      #("user", config.user),
      #("database", config.database),
      #("client_encoding", "UTF8"),
      #("application_name", "dream_model"),
      ..options
    ]
    |> list.map(fn(pair) { <<c_string(pair.0):bits, c_string(pair.1):bits>> })
    |> bit_array.concat
  let body = <<protocol_version:32, parameters:bits, 0>>
  <<{ bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn authenticate(socket: Socket, config: Config) -> Result(Nil, WireError) {
  use #(kind, body) <- result.try(receive_message(socket))
  case kind, body {
    "R", <<0:32>> -> Ok(Nil)
    "R", <<3:32>> -> {
      use password <- result.try(require_password(config))
      use Nil <- result.try(send_bytes(socket, message("p", c_string(password))))
      authenticate(socket, config)
    }
    "R", <<5:32, salt:bytes-size(4)>> -> {
      use password <- result.try(require_password(config))
      let answer = scram.md5_password(config.user, password, salt)
      use Nil <- result.try(send_bytes(socket, message("p", c_string(answer))))
      authenticate(socket, config)
    }
    "R", <<10:32, mechanisms:bytes>> -> {
      use Nil <- result.try(authenticate_with_scram(socket, config, mechanisms))
      authenticate(socket, config)
    }
    "R", <<code:32, _:bytes>> ->
      Error(UnsupportedAuthentication(int.to_string(code)))
    "E", _ -> Error(server_error(body))
    _, _ -> Error(unexpected_message(kind, "authentication"))
  }
}

fn require_password(config: Config) -> Result(String, WireError) {
  option.to_result(config.password, PasswordMissing)
}

fn authenticate_with_scram(
  socket: Socket,
  config: Config,
  mechanisms: BitArray,
) -> Result(Nil, WireError) {
  use Nil <- result.try(check_scram_offered(mechanisms))
  use password <- result.try(require_password(config))
  let nonce = scram.create_nonce()
  let client_first_bare = scram.client_first_message_bare(nonce)
  let client_first =
    bit_array.from_string(scram.gs2_header <> client_first_bare)
  use Nil <- result.try(send_bytes(
    socket,
    message("p", <<
      c_string("SCRAM-SHA-256"):bits,
      { bit_array.byte_size(client_first) }:32,
      client_first:bits,
    >>),
  ))
  use server_first <- result.try(receive_sasl(socket, 11))
  use client_final <- result.try(
    scram.client_final_message(password, client_first_bare, nonce, server_first)
    |> result.map_error(ScramFailed),
  )
  use Nil <- result.try(send_bytes(
    socket,
    message("p", bit_array.from_string(client_final.message)),
  ))
  use server_final <- result.try(receive_sasl(socket, 12))
  scram.verify_server_final(server_final, client_final.server_signature)
  |> result.map_error(ScramFailed)
}

fn check_scram_offered(mechanisms: BitArray) -> Result(Nil, WireError) {
  let offered =
    bit_array.to_string(mechanisms)
    |> result.unwrap("")
    |> string.split("\u{0}")
  case list.contains(offered, "SCRAM-SHA-256") {
    True -> Ok(Nil)
    False ->
      Error(UnsupportedAuthentication(
        "SASL "
        <> string.join(list.filter(offered, fn(name) { name != "" }), ", "),
      ))
  }
}

fn receive_sasl(socket: Socket, code: Int) -> Result(String, WireError) {
  use #(kind, body) <- result.try(receive_message(socket))
  case kind, body {
    "R", <<received:32, data:bytes>> if received == code -> decode_text(data)
    "E", _ -> Error(server_error(body))
    _, _ -> Error(unexpected_message(kind, "SCRAM authentication"))
  }
}

fn receive_parameters(
  socket: Socket,
  parameters: Dict(String, String),
) -> Result(Dict(String, String), WireError) {
  use #(kind, body) <- result.try(receive_message(socket))
  case kind {
    "Z" -> Ok(parameters)
    "S" -> {
      use #(name, rest) <- result.try(read_c_string(body))
      use #(value, _rest) <- result.try(read_c_string(rest))
      receive_parameters(socket, dict.insert(parameters, name, value))
    }
    "E" -> Error(server_error(body))
    _ -> receive_parameters(socket, parameters)
  }
}

// --- Requests --------------------------------------------------------------

type Response {
  Response(
    rows: List(List(Option(String))),
    parameter_types: List(Int),
    fields: List(Field),
    notices: List(Notice),
    error: Option(WireError),
  )
}

fn request(
  connection: Connection,
  messages: BitArray,
) -> Result(Response, WireError) {
  use Nil <- result.try(send_bytes(connection.socket, messages))
  use response <- result.try(collect_response(
    connection.socket,
    Response(
      rows: [],
      parameter_types: [],
      fields: [],
      notices: [],
      error: None,
    ),
  ))
  case response.error {
    Some(error) -> Error(error)
    None ->
      Ok(
        Response(
          ..response,
          rows: list.reverse(response.rows),
          notices: list.reverse(response.notices),
        ),
      )
  }
}

fn collect_response(
  socket: Socket,
  response: Response,
) -> Result(Response, WireError) {
  use #(kind, body) <- result.try(receive_message(socket))
  case kind {
    "Z" -> Ok(response)
    _ -> {
      use response <- result.try(add_message(response, kind, body))
      collect_response(socket, response)
    }
  }
}

fn add_message(
  response: Response,
  kind: String,
  body: BitArray,
) -> Result(Response, WireError) {
  case kind {
    "D" -> {
      use row <- result.try(decode_data_row(body))
      Ok(Response(..response, rows: [row, ..response.rows]))
    }
    "T" -> {
      use fields <- result.try(decode_row_description(body))
      Ok(Response(..response, fields:))
    }
    "t" -> {
      use parameter_types <- result.try(decode_parameter_description(body))
      Ok(Response(..response, parameter_types:))
    }
    "N" -> {
      use fields <- result.try(decode_fields(body, []))
      Ok(Response(..response, notices: [Notice(fields), ..response.notices]))
    }
    "E" ->
      Ok(
        Response(
          ..response,
          error: option.or(response.error, Some(server_error(body))),
        ),
      )
    _ -> Ok(response)
  }
}

fn parse_message(sql: String) -> BitArray {
  message("P", <<0, c_string(sql):bits, 0:16>>)
}

fn bind_body(parameters: List(Option(String))) -> BitArray {
  let values =
    list.map(parameters, fn(parameter) {
      case parameter {
        None -> <<-1:32>>
        Some(text) -> {
          let bytes = bit_array.from_string(text)
          <<{ bit_array.byte_size(bytes) }:32, bytes:bits>>
        }
      }
    })
    |> bit_array.concat
  <<0, 0, 0:16, { list.length(parameters) }:16, values:bits, 0:16>>
}

// --- Messages --------------------------------------------------------------

fn message(kind: String, body: BitArray) -> BitArray {
  <<kind:utf8, { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

fn c_string(text: String) -> BitArray {
  <<text:utf8, 0>>
}

fn send_bytes(socket: Socket, data: BitArray) -> Result(Nil, WireError) {
  send(socket, data)
  |> result.map_error(SocketFailed)
}

fn receive_bytes(socket: Socket, length: Int) -> Result(BitArray, WireError) {
  receive_exactly(socket, length, timeout_milliseconds)
  |> result.map_error(SocketFailed)
}

fn receive_message(socket: Socket) -> Result(#(String, BitArray), WireError) {
  use header <- result.try(receive_bytes(socket, 5))
  case header {
    <<kind, length:32>> if length >= 4 -> {
      use body <- result.try(receive_bytes(socket, length - 4))
      Ok(#(byte_to_string(kind), body))
    }
    _ -> Error(ProtocolViolation("a message length is below 4"))
  }
}

fn byte_to_string(byte: Int) -> String {
  bit_array.to_string(<<byte>>)
  |> result.unwrap("?")
}

fn unexpected_message(kind: String, during: String) -> WireError {
  ProtocolViolation("unexpected message " <> kind <> " during " <> during)
}

fn malformed(name: String) -> WireError {
  ProtocolViolation("malformed " <> name <> " message")
}

fn decode_text(bytes: BitArray) -> Result(String, WireError) {
  bit_array.to_string(bytes)
  |> result.replace_error(ProtocolViolation("a text value is not UTF-8"))
}

fn read_c_string(bytes: BitArray) -> Result(#(String, BitArray), WireError) {
  use #(text, rest) <- result.try(
    split_at_zero(bytes)
    |> result.replace_error(ProtocolViolation("a string has no terminator")),
  )
  use text <- result.try(decode_text(text))
  Ok(#(text, rest))
}

fn decode_fields(
  body: BitArray,
  fields: List(#(String, String)),
) -> Result(List(#(String, String)), WireError) {
  case body {
    <<code, rest:bytes>> if code != 0 -> {
      use #(value, rest) <- result.try(read_c_string(rest))
      decode_fields(rest, [#(byte_to_string(code), value), ..fields])
    }
    _ -> Ok(list.reverse(fields))
  }
}

fn server_error(body: BitArray) -> WireError {
  case decode_fields(body, []) {
    Ok(fields) -> ServerError(fields)
    Error(error) -> error
  }
}

fn decode_data_row(body: BitArray) -> Result(List(Option(String)), WireError) {
  case body {
    <<count:16, values:bytes>> -> decode_values(values, count, [])
    _ -> Error(malformed("DataRow"))
  }
}

fn decode_values(
  body: BitArray,
  count: Int,
  values: List(Option(String)),
) -> Result(List(Option(String)), WireError) {
  case count, body {
    0, _ -> Ok(list.reverse(values))
    _, <<-1:32-signed, rest:bytes>> ->
      decode_values(rest, count - 1, [None, ..values])
    _, <<length:32, value:bytes-size(length), rest:bytes>> -> {
      use text <- result.try(decode_text(value))
      decode_values(rest, count - 1, [Some(text), ..values])
    }
    _, _ -> Error(malformed("DataRow"))
  }
}

fn decode_row_description(body: BitArray) -> Result(List(Field), WireError) {
  case body {
    <<count:16, fields:bytes>> -> decode_field_list(fields, count, [])
    _ -> Error(malformed("RowDescription"))
  }
}

fn decode_field_list(
  body: BitArray,
  count: Int,
  fields: List(Field),
) -> Result(List(Field), WireError) {
  case count {
    0 -> Ok(list.reverse(fields))
    _ -> {
      use #(name, rest) <- result.try(read_c_string(body))
      decode_field(name, rest, count, fields)
    }
  }
}

fn decode_field(
  name: String,
  body: BitArray,
  count: Int,
  fields: List(Field),
) -> Result(List(Field), WireError) {
  case body {
    <<
      table_oid:32,
      column_number:16,
      type_oid:32,
      _size:16,
      _modifier:32,
      _format:16,
      rest:bytes,
    >> ->
      decode_field_list(rest, count - 1, [
        Field(name:, table_oid:, column_number:, type_oid:),
        ..fields
      ])
    _ -> Error(malformed("RowDescription"))
  }
}

fn decode_parameter_description(
  body: BitArray,
) -> Result(List(Int), WireError) {
  case body {
    <<count:16, types:bytes>> -> decode_oids(types, count, [])
    _ -> Error(malformed("ParameterDescription"))
  }
}

fn decode_oids(
  body: BitArray,
  count: Int,
  oids: List(Int),
) -> Result(List(Int), WireError) {
  case count, body {
    0, _ -> Ok(list.reverse(oids))
    _, <<oid:32, rest:bytes>> -> decode_oids(rest, count - 1, [oid, ..oids])
    _, _ -> Error(malformed("ParameterDescription"))
  }
}
