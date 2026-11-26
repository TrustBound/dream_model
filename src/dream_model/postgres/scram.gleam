//// The client side of SCRAM-SHA-256 (RFC 5802 and RFC 7677), the password
//// method that PostgreSQL uses by default since version 14, and the older
//// MD5 password method.
////
//// The functions here only compute messages. `dream_model/postgres/wire`
//// sends them.

import gleam/bit_array.{
  append, base16_encode, base64_decode, base64_encode, from_string,
}
import gleam/int.{parse, to_string}
import gleam/list.{filter_map, key_find}
import gleam/result.{replace_error, try}
import gleam/string.{lowercase, split, split_once, starts_with}

/// A server message that the SCRAM exchange cannot accept.
pub type ScramError {
  /// The server-first or server-final message does not have the form of
  /// RFC 5802.
  MalformedServerMessage(message: String)
  /// The server nonce does not start with the client nonce.
  NonceMismatch
  /// The server proof does not match the password, so the server does not
  /// know the password and may be an impostor.
  ServerSignatureMismatch
  /// The server reported an error in its final message (`e=...`).
  ServerRejected(reason: String)
  /// The server asks for more iterations than `maximum_iterations`. Each
  /// iteration costs time on the client, so a server could make the
  /// client hang.
  TooManyIterations(iterations: Int)
}

/// The most PBKDF2 iterations that the client computes. PostgreSQL uses
/// 4096 by default (`scram_iterations`).
pub const maximum_iterations = 1_000_000

/// The client-final message and the server signature that the server must
/// send back in its final message.
pub type ClientFinal {
  ClientFinal(message: String, server_signature: BitArray)
}

type HashAlgorithm {
  Sha256
  Md5
}

type MacKind {
  Hmac
}

@external(erlang, "crypto", "hash")
fn hash(algorithm: HashAlgorithm, data: BitArray) -> BitArray

@external(erlang, "crypto", "mac")
fn mac(
  kind: MacKind,
  algorithm: HashAlgorithm,
  key: BitArray,
  data: BitArray,
) -> BitArray

@external(erlang, "crypto", "pbkdf2_hmac")
fn pbkdf2_hmac(
  algorithm: HashAlgorithm,
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> BitArray

@external(erlang, "crypto", "strong_rand_bytes")
fn strong_random_bytes(count: Int) -> BitArray

@external(erlang, "crypto", "exor")
fn exclusive_or(first: BitArray, second: BitArray) -> BitArray

/// The GS2 header of a client that does not use channel binding.
pub const gs2_header = "n,,"

/// Returns a new random client nonce: 18 random bytes in base64.
pub fn create_nonce() -> String {
  strong_random_bytes(18)
  |> base64_encode(True)
}

/// Returns the client-first message without its GS2 header. PostgreSQL
/// takes the user name from the startup message, so the user name here is
/// empty, the same as libpq sends.
pub fn client_first_message_bare(nonce nonce: String) -> String {
  "n=,r=" <> nonce
}

/// Computes the client-final message from the password, the client-first
/// message without its header, the client nonce and the server-first
/// message.
pub fn client_final_message(
  password password: String,
  client_first_bare client_first_bare: String,
  client_nonce client_nonce: String,
  server_first server_first: String,
) -> Result(ClientFinal, ScramError) {
  use attributes <- try(parse_server_first(server_first))
  let #(server_nonce, salt, iterations) = attributes
  use Nil <- try(check_nonce(server_nonce, client_nonce))
  let salted_password =
    pbkdf2_hmac(Sha256, from_string(password), salt, iterations, 32)
  let client_key = hmac(salted_password, "Client Key")
  let stored_key = hash(Sha256, client_key)
  let without_proof =
    "c="
    <> base64_encode(from_string(gs2_header), True)
    <> ",r="
    <> server_nonce
  let authentication_message =
    client_first_bare <> "," <> server_first <> "," <> without_proof
  let client_signature = hmac(stored_key, authentication_message)
  let proof = exclusive_or(client_key, client_signature)
  let server_key = hmac(salted_password, "Server Key")
  Ok(ClientFinal(
    message: without_proof <> ",p=" <> base64_encode(proof, True),
    server_signature: hmac(server_key, authentication_message),
  ))
}

/// Checks the server-final message against the server signature that
/// `client_final_message` computed.
pub fn verify_server_final(
  server_final server_final: String,
  server_signature server_signature: BitArray,
) -> Result(Nil, ScramError) {
  case server_final {
    "v=" <> encoded -> check_signature(encoded, server_signature)
    "e=" <> reason -> Error(ServerRejected(reason))
    _ -> Error(MalformedServerMessage(server_final))
  }
}

/// Returns the answer to PostgreSQL's MD5 password request:
/// `"md5" <> md5_hex(md5_hex(password <> user) <> salt)`.
pub fn md5_password(
  user user: String,
  password password: String,
  salt salt: BitArray,
) -> String {
  let inner = md5_hex(from_string(password <> user))
  "md5" <> md5_hex(append(from_string(inner), salt))
}

/// Returns a readable message for a SCRAM error.
pub fn error_to_string(error: ScramError) -> String {
  case error {
    MalformedServerMessage(message) ->
      "the server sent a SCRAM message that is not valid: " <> message
    NonceMismatch ->
      "the server nonce does not start with the client nonce, so the SCRAM exchange stopped"
    ServerSignatureMismatch ->
      "the server could not prove that it knows the password, so the connection stopped"
    ServerRejected(reason) -> "the server rejected the SCRAM proof: " <> reason
    TooManyIterations(iterations) ->
      "the server asks for "
      <> to_string(iterations)
      <> " SCRAM iterations, and dream_model computes at most "
      <> to_string(maximum_iterations)
      <> "; lower scram_iterations on the server and set the password again"
  }
}

fn md5_hex(data: BitArray) -> String {
  hash(Md5, data)
  |> base16_encode
  |> lowercase
}

fn hmac(key: BitArray, data: String) -> BitArray {
  mac(Hmac, Sha256, key, from_string(data))
}

fn check_signature(
  encoded: String,
  expected: BitArray,
) -> Result(Nil, ScramError) {
  case base64_decode(encoded) == Ok(expected) {
    True -> Ok(Nil)
    False -> Error(ServerSignatureMismatch)
  }
}

fn check_nonce(
  server_nonce: String,
  client_nonce: String,
) -> Result(Nil, ScramError) {
  case starts_with(server_nonce, client_nonce) && server_nonce != client_nonce {
    True -> Ok(Nil)
    False -> Error(NonceMismatch)
  }
}

fn parse_server_first(
  message: String,
) -> Result(#(String, BitArray, Int), ScramError) {
  let attributes =
    split(message, ",")
    |> filter_map(split_once(_, "="))
  let malformed = MalformedServerMessage(message)
  use nonce <- try(key_find(attributes, "r") |> replace_error(malformed))
  use salt <- try(
    key_find(attributes, "s")
    |> try(base64_decode)
    |> replace_error(malformed),
  )
  use iterations <- try(
    key_find(attributes, "i")
    |> try(parse)
    |> replace_error(malformed),
  )
  case iterations > 0, iterations > maximum_iterations {
    False, _ -> Error(malformed)
    True, True -> Error(TooManyIterations(iterations))
    True, False -> Ok(#(nonce, salt, iterations))
  }
}
