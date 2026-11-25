//// A fake PostgreSQL server that follows a script, for the protocol cases
//// that a real server never sends: other authentication methods, TLS, and
//// malformed messages.

import gleam/bit_array
import gleam/int

/// One step of the script.
pub type Step {
  /// Send these bytes.
  Send(bytes: BitArray)
  /// Read the startup message.
  ReceiveStartup
  /// Read one typed message.
  ReceiveMessage
  /// Read one typed message, and close the connection when it differs.
  ExpectMessage(bytes: BitArray)
  /// Read the SSLRequest, answer `S` and do the TLS handshake with a test
  /// certificate.
  AcceptTls
  /// Read the SSLRequest and answer with this byte.
  AnswerSslRequest(byte: Int)
  /// Read the SASLInitialResponse and send a server-first message that
  /// continues the client nonce.
  ScramServerFirst(salt: BitArray, iterations: Int)
  /// Close the connection.
  Close
}

@external(erlang, "dream_model_test_ffi", "start_fake_server")
fn start_fake_server(scripts: List(List(Step))) -> Int

/// Starts a server that accepts one connection and runs the steps on it.
/// Returns its URL.
pub fn start(steps: List(Step)) -> String {
  start_for_connections([steps])
}

/// Starts a server that accepts one connection for each script, in order,
/// and runs the script on it. Returns its URL.
pub fn start_for_connections(scripts: List(List(Step))) -> String {
  "postgresql://dream:secret@127.0.0.1:"
  <> int.to_string(start_fake_server(scripts))
  <> "/fake"
}

/// Starts a server and returns its URL with a query string, for example
/// `"?sslmode=require"`.
pub fn start_with_query(steps: List(Step), query: String) -> String {
  start(steps) <> query
}

/// Returns a backend message.
pub fn message(kind: String, body: BitArray) -> BitArray {
  <<kind:utf8, { bit_array.byte_size(body) + 4 }:32, body:bits>>
}

/// AuthenticationOk
pub fn authentication_ok() -> BitArray {
  message("R", <<0:32>>)
}

/// ReadyForQuery (idle)
pub fn ready() -> BitArray {
  message("Z", <<"I":utf8>>)
}

/// The steps of a startup with trust authentication.
pub fn trusted_startup() -> List(Step) {
  [ReceiveStartup, Send(authentication_ok()), Send(ready())]
}
