//// The PostgreSQL servers of docker-compose.yml: one per major version, on
//// port 5400 + version.
////
//// `DREAM_MODEL_TEST_VERSIONS` picks the versions that the database tests
//// run on, for example `DREAM_MODEL_TEST_VERSIONS="16 18"`. The default is
//// every supported version.

import dream_model/postgres/wire
import gleam/int
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "dream_model_test_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

/// The versions that the tests run on when the variable is not set.
pub const default_versions = [16, 17, 18, 19]

/// The database that every server has.
pub const default_database = "dream_test"

/// Returns the versions from `DREAM_MODEL_TEST_VERSIONS`, or the default.
pub fn versions() -> List(Int) {
  get_env("DREAM_MODEL_TEST_VERSIONS")
  |> result.map(fn(text) {
    string.split(text, " ")
    |> list.filter_map(int.parse)
  })
  |> result.unwrap(default_versions)
}

/// Returns the URL of a database on the server of a version.
pub fn url(version: Int, database: String) -> String {
  "postgresql://dream:dream@localhost:"
  <> int.to_string(5400 + version)
  <> "/"
  <> database
}

/// Opens a connection to a database on the server of a version.
pub fn connect(version: Int, database: String) -> wire.Connection {
  let assert Ok(config) = wire.parse_url(url(version, database))
  let assert Ok(connection) = wire.connect(config)
  connection
}

/// Checks that the server of a version accepts connections.
pub fn check_reachable(version: Int) -> Result(Nil, String) {
  let assert Ok(config) = wire.parse_url(url(version, default_database))
  case wire.connect(config) {
    Ok(connection) ->
      wire.close(connection) |> result.map_error(wire.error_to_string)
    Error(error) ->
      Error(
        "PostgreSQL "
        <> int.to_string(version)
        <> " is not reachable ("
        <> wire.error_to_string(error)
        <> "). Start the test servers with `make db-up`.",
      )
  }
}
