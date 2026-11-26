//// Gleam names for SQL names: record fields and arguments from columns,
//// functions from file names, types from folder names.

import gleam/list.{filter, fold, map, reverse}
import gleam/string.{
  capitalise, concat, join, lowercase, slice, split, to_graphemes,
}

/// The words that Gleam reserves. A name that is one of them gets `_` at
/// its end, for example `type_`.
pub const keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const uppercase_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const digits = "0123456789"

type Kind {
  Lower
  Upper
  Digit
  Other
}

/// Returns the Gleam value name of a SQL name, in snake case: `createdAt`
/// gives `created_at`, `Total Count` gives `total_count`, and `type` gives
/// `type_`. Returns `Error(Nil)` when no letter or digit is left, or the
/// name starts with a digit.
pub fn to_value_name(sql_name: String) -> Result(String, Nil) {
  let snake =
    to_graphemes(sql_name)
    |> fold(#([], Other), add_character)
    |> fn(state: #(List(String), Kind)) { reverse(state.0) }
    |> concat
    |> collapse_underscores
  let starts_with_digit = string.contains(digits, slice(snake, 0, 1))
  case snake == "" || starts_with_digit {
    True -> Error(Nil)
    False -> Ok(avoid_keyword(snake))
  }
}

/// Returns the Gleam type name of a folder name in snake case:
/// `user_account` gives `UserAccount`.
pub fn to_type_name(folder: String) -> String {
  split(folder, "_")
  |> map(capitalise)
  |> concat
}

/// Returns the name with `_` at its end when it is a Gleam keyword.
pub fn avoid_keyword(name: String) -> String {
  case list.contains(keywords, name) {
    True -> name <> "_"
    False -> name
  }
}

fn add_character(
  state: #(List(String), Kind),
  character: String,
) -> #(List(String), Kind) {
  let #(output, previous) = state
  let kind = kind_of(character)
  let lower = lowercase(character)
  case kind, previous {
    Upper, Lower | Upper, Digit -> #([lower, "_", ..output], kind)
    Upper, _ | Lower, _ | Digit, _ -> #([lower, ..output], kind)
    Other, _ -> #(["_", ..output], kind)
  }
}

fn kind_of(character: String) -> Kind {
  let is_lower = string.contains(lowercase_letters, character)
  let is_upper = string.contains(uppercase_letters, character)
  let is_digit = string.contains(digits, character)
  case is_lower, is_upper, is_digit {
    True, _, _ -> Lower
    _, True, _ -> Upper
    _, _, True -> Digit
    _, _, _ -> Other
  }
}

fn collapse_underscores(text: String) -> String {
  split(text, "_")
  |> filter(fn(part) { part != "" })
  |> join("_")
}
