//// Gets PostgreSQL's analyzed and rewritten query for a SQL text.
////
//// A connection opened with `tree_options` in its startup `options` makes
//// PostgreSQL send the rewritten query tree of each statement it parses, in
//// a LOG notice. `capture` parses and describes the statement on such a
//// connection, and reads the tree from that notice.

import dream_model/postgres/node.{
  type Node, type ParseError, items, parse_error_to_string,
}
import dream_model/postgres/wire.{
  type Connection, type Description, type Notice, type WireError, describe,
}
import gleam/bit_array.{from_string}
import gleam/int.{max, to_string}
import gleam/list.{filter, filter_map, last, length, take_while}
import gleam/result.{is_ok, map_error, replace_error, try}
import gleam/string.{concat, to_graphemes}

/// The startup `options` of a connection that sends the rewritten query
/// tree of each statement as a LOG notice.
pub const tree_options =
  "-c debug_print_rewritten=on -c debug_pretty_print=off -c client_min_messages=log"

/// The oldest PostgreSQL major version that dream_model supports.
pub const oldest_version = 16

/// The newest PostgreSQL major version that dream_model is tested on.
pub const newest_version = 19

/// The analyzed query, and what Describe told about the statement.
pub type Captured {
  Captured(
    query: Node,
    description: Description,
    /// The number of queries that rewriting gave. It is more than 1 when a
    /// rule adds queries, for example a `DO ALSO` rule. The other queries
    /// run too, and can use each parameter anywhere.
    queries: Int,
  )
}

/// Why the query tree cannot be used.
pub type TreeError {
  /// The server version is older than `oldest_version`.
  VersionTooOld(version: String)
  /// The server version is newer than `newest_version`.
  VersionNotTested(version: String)
  /// The `server_version` parameter does not start with a number.
  UnknownVersion(version: String)
  /// PostgreSQL did not accept the statement, or the connection failed.
  QueryFailed(error: WireError)
  /// The connection did not get the notice with the query tree. It was not
  /// opened with `tree_options`.
  NoTreeNotice
  /// The tree holds a token too long to read safely. PostgreSQL breaks the
  /// notice text into lines of 78 bytes, and in a token longer than that it
  /// puts a line break inside the token.
  TokenTooLong
  /// The notice text is not valid node text.
  UnreadableTree(error: ParseError)
  /// Rewriting gave `queries` queries, and `main` of them return the
  /// statement's result. dream_model needs exactly one.
  WrongQueryCount(queries: Int, main: Int)
}

/// Reads the major version from the `server_version` parameter, for
/// example 16 from `"16.16"` or 19 from `"19beta1"`, and checks that
/// dream_model supports it.
pub fn check_version(server_version: String) -> Result(Int, TreeError) {
  let digits =
    to_graphemes(server_version)
    |> take_while(fn(character) { is_ok(int.parse(character)) })
    |> concat
  use major <- try(
    int.parse(digits) |> replace_error(UnknownVersion(server_version)),
  )
  case major < oldest_version, major > newest_version {
    True, _ -> Error(VersionTooOld(server_version))
    _, True -> Error(VersionNotTested(server_version))
    False, False -> Ok(major)
  }
}

/// Parses and describes `sql` on a connection opened with `tree_options`,
/// and returns the one rewritten query that returns the statement's
/// result.
pub fn capture(
  connection: Connection,
  sql: String,
) -> Result(Captured, TreeError) {
  use description <- try(describe(connection, sql) |> map_error(QueryFailed))
  use text <- try(find_tree_text(description.notices))
  use Nil <- try(check_token_lengths(text))
  use parsed <- try(node.parse(text) |> map_error(UnreadableTree))
  let queries = items(parsed)
  let main =
    filter(queries, fn(query) {
      node.text(node.get_field(query, "canSetTag")) == "true"
    })
  case main {
    [query] -> Ok(Captured(query:, description:, queries: length(queries)))
    _ -> Error(WrongQueryCount(length(queries), length(main)))
  }
}

/// Returns a readable message for a tree error.
pub fn error_to_string(error: TreeError) -> String {
  case error {
    VersionTooOld(version) ->
      "PostgreSQL "
      <> version
      <> " is not supported: dream_model needs PostgreSQL "
      <> to_string(oldest_version)
      <> " or newer, because older versions do not record which columns an outer join can make NULL"
    VersionNotTested(version) ->
      "PostgreSQL "
      <> version
      <> " is not supported yet: dream_model is tested on PostgreSQL "
      <> to_string(oldest_version)
      <> " to "
      <> to_string(newest_version)
      <> ", and it reads PostgreSQL's analyzed query, whose form can change in each major version"
    UnknownVersion(version) ->
      "cannot read the PostgreSQL version from \"" <> version <> "\""
    QueryFailed(error) -> wire.error_to_string(error)
    NoTreeNotice ->
      "PostgreSQL sent no analyzed query; the connection must use the options "
      <> tree_options
    TokenTooLong ->
      "the query has a name that is too long to read from PostgreSQL's analyzed query (77 bytes or more with its escapes); use a shorter name"
    UnreadableTree(error) ->
      "cannot read PostgreSQL's analyzed query: "
      <> parse_error_to_string(error)
    WrongQueryCount(queries, main) ->
      "rewriting gave "
      <> to_string(queries)
      <> " queries, and "
      <> to_string(main)
      <> " of them return the result; dream_model needs exactly one (rules can cause this)"
  }
}

fn find_tree_text(notices: List(Notice)) -> Result(String, TreeError) {
  notices
  |> filter_map(fn(notice) {
    case wire.get_field(notice.fields, "M") {
      Ok("rewritten parse tree" <> _) -> wire.get_field(notice.fields, "D")
      _ -> Error(Nil)
    }
  })
  |> last
  |> replace_error(NoTreeNotice)
}

/// PostgreSQL's `format_node_dump` breaks the tree text into lines of at
/// most 78 bytes. It breaks at a space when the line has one, so a line
/// break is then only white space. A token of 78 bytes or more gets a line
/// break inside it, which changes the token. This refuses any run of 77
/// bytes or more without a space or a line break.
fn check_token_lengths(text: String) -> Result(Nil, TreeError) {
  case longest_run(from_string(text), 0, 0) >= 77 {
    True -> Error(TokenTooLong)
    False -> Ok(Nil)
  }
}

fn longest_run(bytes: BitArray, current: Int, longest: Int) -> Int {
  case bytes {
    <<32, rest:bytes>> | <<10, rest:bytes>> | <<9, rest:bytes>> ->
      longest_run(rest, 0, longest)
    <<_, rest:bytes>> ->
      longest_run(rest, current + 1, max(longest, current + 1))
    _ -> longest
  }
}
