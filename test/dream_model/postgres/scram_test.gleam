//// Tests for `dream_model/postgres/scram`, with the test vector of
//// RFC 7677 (SCRAM-SHA-256).

import dream_model/postgres/scram.{
  type ScramError, ClientFinal, MalformedServerMessage, NonceMismatch,
  ServerRejected, ServerSignatureMismatch, TooManyIterations,
  client_final_message, client_first_message_bare, create_nonce, error_to_string,
  md5_password, verify_server_final,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/bit_array.{base64_decode, byte_size}
import gleam/result.{map}
import gleam/string.{inspect}

const client_nonce = "rOprNGfwEbeRWgbNEkqO"

const client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO"

const server_first =
  "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

const client_final =
  "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="

const server_final = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

pub fn tests() -> TestSuite {
  describe("dream_model/postgres/scram", [
    client_final_tests(),
    server_first_error_tests(),
    verify_tests(),
    other_tests(),
    error_to_string_tests(),
  ])
}

fn compute(server_first: String) -> Result(scram.ClientFinal, ScramError) {
  client_final_message("pencil", client_first_bare, client_nonce, server_first)
}

fn client_final_tests() {
  group("client_final_message", [
    it("returns the client-final message of RFC 7677", fn() {
      // Arrange
      let first = server_first

      // Act
      let computed = compute(first) |> map(fn(final) { final.message })

      // Assert
      computed
      |> should
      |> be_equal(Ok(client_final))
      |> or_fail_with("Expected the RFC 7677 client-final message")
    }),
    it("returns the server signature of RFC 7677", fn() {
      // Arrange
      let assert Ok(expected) =
        base64_decode("6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")

      // Act
      let computed =
        compute(server_first)
        |> map(fn(final) { final.server_signature })

      // Assert
      computed
      |> should
      |> be_equal(Ok(expected))
      |> or_fail_with("Expected the RFC 7677 server signature")
    }),
  ])
}

fn server_first_error_tests() {
  group("client_final_message with a bad server-first message", [
    error_case(
      "a server nonce that does not continue the client nonce",
      "r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
      NonceMismatch,
    ),
    error_case(
      "a server nonce equal to the client nonce",
      "r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
      NonceMismatch,
    ),
    error_case(
      "no nonce",
      "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
      MalformedServerMessage("s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"),
    ),
    error_case(
      "a salt that is not base64",
      "r=rOprNGfwEbeRWgbNEkqOx,s=***,i=4096",
      MalformedServerMessage("r=rOprNGfwEbeRWgbNEkqOx,s=***,i=4096"),
    ),
    error_case(
      "no iteration count",
      "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==",
      MalformedServerMessage(
        "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==",
      ),
    ),
    error_case(
      "an iteration count of 0",
      "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0",
      MalformedServerMessage(
        "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0",
      ),
    ),
    error_case(
      "an iteration count above the maximum",
      "r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000001",
      TooManyIterations(1_000_001),
    ),
  ])
}

fn error_case(name: String, message: String, expected: ScramError) {
  it("returns an error for " <> name, fn() {
    // Arrange
    let first = message

    // Act
    let computed = compute(first)

    // Assert
    computed
    |> should
    |> be_equal(Error(expected))
    |> or_fail_with("Expected " <> inspect(expected))
  })
}

fn verify_tests() {
  group("verify_server_final", [
    it("accepts the server-final message of RFC 7677", fn() {
      // Arrange
      let assert Ok(ClientFinal(server_signature:, ..)) = compute(server_first)

      // Act
      let verified = verify_server_final(server_final, server_signature)

      // Assert
      verified
      |> should
      |> be_equal(Ok(Nil))
      |> or_fail_with("Expected the RFC 7677 server signature to match")
    }),
    it("returns ServerSignatureMismatch for another signature", fn() {
      // Arrange
      let assert Ok(ClientFinal(server_signature:, ..)) = compute(server_first)

      // Act
      let verified = verify_server_final("v=AAAA", server_signature)

      // Assert
      verified
      |> should
      |> be_equal(Error(ServerSignatureMismatch))
      |> or_fail_with("Expected ServerSignatureMismatch")
    }),
    it("returns ServerRejected for an e= message", fn() {
      // Arrange
      let message = "e=invalid-proof"

      // Act
      let verified = verify_server_final(message, <<>>)

      // Assert
      verified
      |> should
      |> be_equal(Error(ServerRejected("invalid-proof")))
      |> or_fail_with("Expected ServerRejected")
    }),
    it("returns MalformedServerMessage for another message", fn() {
      // Arrange
      let message = "x=1"

      // Act
      let verified = verify_server_final(message, <<>>)

      // Assert
      verified
      |> should
      |> be_equal(Error(MalformedServerMessage("x=1")))
      |> or_fail_with("Expected MalformedServerMessage")
    }),
  ])
}

fn other_tests() {
  group("other messages", [
    it("client_first_message_bare has an empty user name", fn() {
      // Arrange
      let nonce = "abc"

      // Act
      let message = client_first_message_bare(nonce)

      // Assert
      message
      |> should
      |> be_equal("n=,r=abc")
      |> or_fail_with("Expected n=,r=abc")
    }),
    it("create_nonce returns 18 random bytes in base64", fn() {
      // Arrange
      let count = 18

      // Act
      let nonce = create_nonce()

      // Assert
      base64_decode(nonce)
      |> map(byte_size)
      |> should
      |> be_equal(Ok(count))
      |> or_fail_with("Expected 18 bytes")
    }),
    it(
      "md5_password returns md5 of the md5 of password and user with the salt",
      fn() {
        // Arrange
        let salt = <<1, 2, 3, 4>>

        // Act
        let answer = md5_password("dream", "secret", salt)

        // Assert
        answer
        |> should
        |> be_equal("md529f38861b864472bf5b524749d1f0a88")
        |> or_fail_with("Expected the MD5 answer of PostgreSQL's MD5 method")
      },
    ),
  ])
}

fn error_to_string_tests() {
  group("error_to_string", [
    text_case(
      MalformedServerMessage("x"),
      "the server sent a SCRAM message that is not valid: x",
    ),
    text_case(
      NonceMismatch,
      "the server nonce does not start with the client nonce, so the SCRAM exchange stopped",
    ),
    text_case(
      ServerSignatureMismatch,
      "the server could not prove that it knows the password, so the connection stopped",
    ),
    text_case(
      ServerRejected("invalid-proof"),
      "the server rejected the SCRAM proof: invalid-proof",
    ),
    text_case(
      TooManyIterations(5_000_000),
      "the server asks for 5000000 SCRAM iterations, and dream_model computes at most 1000000; lower scram_iterations on the server and set the password again",
    ),
  ])
}

fn text_case(error: ScramError, expected: String) {
  it("describes " <> inspect(error), fn() {
    // Arrange
    let value = error

    // Act
    let text = error_to_string(value)

    // Assert
    text
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the message of " <> inspect(error))
  })
}
