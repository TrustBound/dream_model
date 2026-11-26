//// The PostgreSQL servers of docker-compose.yml: one per major version, on
//// port 5400 + version.
////
//// `DREAM_MODEL_TEST_VERSIONS` picks the versions that the database tests
//// run on, for example `DREAM_MODEL_TEST_VERSIONS="16 18"`. The default is
//// every supported version.
////
//// `DREAM_MODEL_TEST_DATABASE_PREFIX` puts a prefix before the name of each
//// database that the tests create, for example
//// `DREAM_MODEL_TEST_DATABASE_PREFIX=w1_`. Two test runs with different
//// prefixes can then use the same servers at the same time. The default is
//// no prefix. The prefix can hold only lowercase letters, digits and `_`.

import dream_model/postgres/wire.{
  type Connection, close, error_to_string, parse_url,
}
import gleam/int.{parse, to_string}
import gleam/list.{all, filter_map}
import gleam/result.{map, map_error, unwrap}
import gleam/string.{contains, length, split, to_graphemes}

@external(erlang, "dream_model_test_ffi", "read_environment_variable")
fn read_environment_variable(name: String) -> Result(String, Nil)

/// The versions that the tests run on when the variable is not set.
pub const default_versions = [16, 17, 18, 19]

/// The database that every server has.
pub const default_database = "dream_test"

/// Returns the versions from `DREAM_MODEL_TEST_VERSIONS`, or the default.
pub fn versions() -> List(Int) {
  read_environment_variable("DREAM_MODEL_TEST_VERSIONS")
  |> map(fn(text) {
    split(text, " ")
    |> filter_map(parse)
  })
  |> unwrap(default_versions)
}

/// Returns the prefix of the databases that the tests create, from
/// `DREAM_MODEL_TEST_DATABASE_PREFIX`, or "" when the variable is not set.
pub fn database_prefix() -> String {
  let prefix =
    read_environment_variable("DREAM_MODEL_TEST_DATABASE_PREFIX")
    |> unwrap("")
  let allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
  let valid =
    length(prefix) <= 20 && all(to_graphemes(prefix), contains(allowed, _))
  case valid {
    True -> prefix
    False ->
      panic as {
        "DREAM_MODEL_TEST_DATABASE_PREFIX can hold at most 20 lowercase letters, digits and _, not "
        <> prefix
      }
  }
}

/// Returns the name of a database that the tests create, with the prefix
/// of `DREAM_MODEL_TEST_DATABASE_PREFIX` before it.
pub fn database_name(name: String) -> String {
  database_prefix() <> name
}

/// Returns the URL of a database on the server of a version.
pub fn url(version: Int, database: String) -> String {
  "postgresql://dream:dream@localhost:"
  <> to_string(5400 + version)
  <> "/"
  <> database
}

/// Opens a connection to a database on the server of a version.
pub fn connect(version: Int, database: String) -> Connection {
  let assert Ok(config) = parse_url(url(version, database))
  let assert Ok(connection) = wire.connect(config)
  connection
}

/// Checks that the server of a version accepts connections.
pub fn check_reachable(version: Int) -> Result(Nil, String) {
  let assert Ok(config) = parse_url(url(version, default_database))
  case wire.connect(config) {
    Ok(connection) -> close(connection) |> map_error(error_to_string)
    Error(error) ->
      Error(
        "PostgreSQL "
        <> to_string(version)
        <> " is not reachable ("
        <> error_to_string(error)
        <> "). Start the test servers with `make db-up`.",
      )
  }
}
