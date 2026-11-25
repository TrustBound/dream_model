//// A reader for PostgreSQL's node text format: the text that
//// `nodeToString` writes, and that `debug_print_rewritten` sends in a LOG
//// notice.
////
//// The format has five kinds of value:
////
//// - a node: `{NAME :field value :field value}`
//// - a list: `(value value)`
//// - a list of numbers: `(b 1 2)` is a Bitmapset, `(i 1 2)` a list of
////   integers, `(o 1 2)` a list of oids, `(x 1 2)` a list of transaction ids
//// - `<>`, which is NULL, an empty list or an empty string
//// - a token: anything else, for example `23`, `true` or `"name"`
////
//// A backslash makes the next character part of the token, so a name can
//// hold spaces, braces, parentheses and newlines. A name that starts with
//// `:` is not escaped, so this reader takes the first token after a field
//// name as the field's value, the same as PostgreSQL's own reader, which
//// knows each field.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// One value of the node text format.
pub type Node {
  /// A node, `{NAME :field value ...}`. A field with more than one token
  /// (for example `:constvalue 4 [ 1 0 0 0 ]`) holds a `NodeList` of them.
  Record(name: String, fields: Dict(String, Node))
  /// A list, `(value value ...)`.
  NodeList(items: List(Node))
  /// A list of numbers, `(b 1 2)`.
  IntegerList(kind: IntegerListKind, items: List(Int))
  /// A token, with its escapes removed and without its quotes.
  Token(text: String)
  /// `<>`
  Empty
}

/// The kind of a list of numbers.
pub type IntegerListKind {
  /// `(b ...)`, a Bitmapset
  Bitmapset
  /// `(i ...)`, a list of integers
  Integers
  /// `(o ...)`, a list of oids
  Oids
  /// `(x ...)`, a list of transaction ids
  TransactionIds
}

/// Why the text cannot be read.
pub type ParseError {
  /// The text ends inside a node or a list.
  UnexpectedEnd
  /// A token is in a place where the format does not allow it.
  UnexpectedToken(token: String)
  /// A list of numbers holds something that is not a number.
  NotAnInteger(token: String)
}

type Token {
  OpenNode
  CloseNode
  OpenList
  CloseList
  /// `raw` is the token as written, `text` the token without escapes and
  /// quotes.
  Word(raw: String, text: String)
}

type CharacterClass {
  Space
  Delimiter(token: Token)
  Backslash
  Other
}

/// Reads one value from node text.
pub fn parse(text: String) -> Result(Node, ParseError) {
  let tokens = tokenize(string.to_utf_codepoints(text), [])
  use #(value, rest) <- result.try(parse_value(tokens))
  case rest {
    [] -> Ok(value)
    [token, ..] -> Error(UnexpectedToken(token_to_string(token)))
  }
}

/// Returns a readable message for a parse error.
pub fn parse_error_to_string(error: ParseError) -> String {
  case error {
    UnexpectedEnd -> "the node text ends too early"
    UnexpectedToken(token) ->
      "unexpected token " <> token <> " in the node text"
    NotAnInteger(token) -> token <> " in a list of numbers is not a number"
  }
}

/// Returns a field of a node, or `Empty` when the value is not a node or
/// has no such field.
pub fn get_field(node: Node, name: String) -> Node {
  case node {
    Record(fields:, ..) -> dict.get(fields, name) |> result.unwrap(Empty)
    _ -> Empty
  }
}

/// Returns an item of a list by its position from 0, or `Empty` when there
/// is no such item.
pub fn get_item(node: Node, index: Int) -> Node {
  items(node)
  |> list.drop(index)
  |> list.first
  |> result.unwrap(Empty)
}

/// Returns the items of a list. `Empty` is the empty list, and any other
/// single value is a list of one item, the same as PostgreSQL writes a list
/// of one node.
pub fn items(node: Node) -> List(Node) {
  case node {
    NodeList(items) -> items
    Empty -> []
    IntegerList(items:, ..) ->
      list.map(items, fn(item) { Token(int.to_string(item)) })
    _ -> [node]
  }
}

/// Returns the numbers of a list of numbers, or `[]` for any other value.
pub fn integers(node: Node) -> List(Int) {
  case node {
    IntegerList(items:, ..) -> items
    _ -> []
  }
}

/// Returns the name of a node, for example `"VAR"`, or `""` when the value
/// is not a node.
pub fn node_name(node: Node) -> String {
  case node {
    Record(name:, ..) -> name
    _ -> ""
  }
}

/// Returns the text of a token, or `""` when the value is not a token.
pub fn text(node: Node) -> String {
  case node {
    Token(text) -> text
    _ -> ""
  }
}

/// Returns the number in a token.
pub fn integer(node: Node) -> Result(Int, Nil) {
  int.parse(text(node))
}

/// Returns the value with every `location` field removed, at every depth.
/// Two expressions that differ only in where they are in the SQL text are
/// equal after this.
pub fn remove_locations(node: Node) -> Node {
  case node {
    Record(name:, fields:) ->
      Record(
        name:,
        fields: dict.delete(fields, "location")
          |> dict.map_values(fn(_name, value) { remove_locations(value) }),
      )
    NodeList(items) -> NodeList(list.map(items, remove_locations))
    _ -> node
  }
}

// --- Tokens ----------------------------------------------------------------

fn tokenize(
  characters: List(UtfCodepoint),
  tokens: List(Token),
) -> List(Token) {
  case characters {
    [] -> list.reverse(tokens)
    [character, ..rest] -> tokenize_from(character, rest, tokens)
  }
}

fn tokenize_from(
  character: UtfCodepoint,
  rest: List(UtfCodepoint),
  tokens: List(Token),
) -> List(Token) {
  case classify(character) {
    Space -> tokenize(rest, tokens)
    Delimiter(token) -> tokenize(rest, [token, ..tokens])
    Backslash | Other -> read_word([character, ..rest], [], [], tokens)
  }
}

fn read_word(
  characters: List(UtfCodepoint),
  raw: List(UtfCodepoint),
  text: List(UtfCodepoint),
  tokens: List(Token),
) -> List(Token) {
  case characters {
    [] -> tokenize([], [make_word(raw, text), ..tokens])
    [character, ..rest] -> read_word_from(character, rest, raw, text, tokens)
  }
}

fn read_word_from(
  character: UtfCodepoint,
  rest: List(UtfCodepoint),
  raw: List(UtfCodepoint),
  text: List(UtfCodepoint),
  tokens: List(Token),
) -> List(Token) {
  case classify(character), rest {
    Backslash, [escaped, ..after] ->
      read_word(after, [escaped, character, ..raw], [escaped, ..text], tokens)
    Backslash, [] | Other, _ ->
      read_word(rest, [character, ..raw], [character, ..text], tokens)
    Space, _ | Delimiter(_), _ ->
      tokenize([character, ..rest], [make_word(raw, text), ..tokens])
  }
}

/// `raw` and `text` hold the characters in reverse order. A token that
/// starts with a quote is a string: its text is without the first and the
/// last character.
fn make_word(raw: List(UtfCodepoint), text: List(UtfCodepoint)) -> Token {
  let raw = string.from_utf_codepoints(list.reverse(raw))
  let text = case string.starts_with(raw, "\""), text {
    True, [_last, _, ..] -> text |> list.drop(1) |> list.reverse |> list.drop(1)
    _, _ -> list.reverse(text)
  }
  Word(raw:, text: string.from_utf_codepoints(text))
}

fn classify(character: UtfCodepoint) -> CharacterClass {
  case string.utf_codepoint_to_int(character) {
    32 | 10 | 9 -> Space
    123 -> Delimiter(OpenNode)
    125 -> Delimiter(CloseNode)
    40 -> Delimiter(OpenList)
    41 -> Delimiter(CloseList)
    92 -> Backslash
    _ -> Other
  }
}

fn token_to_string(token: Token) -> String {
  case token {
    OpenNode -> "{"
    CloseNode -> "}"
    OpenList -> "("
    CloseList -> ")"
    Word(raw:, ..) -> raw
  }
}

fn is_field_name(token: Token) -> Bool {
  case token {
    Word(raw: ":" <> name, ..) -> name != ""
    _ -> False
  }
}

// --- Values ----------------------------------------------------------------

fn parse_value(
  tokens: List(Token),
) -> Result(#(Node, List(Token)), ParseError) {
  case tokens {
    [] -> Error(UnexpectedEnd)
    [OpenNode, Word(text: name, ..), ..rest] ->
      parse_fields(rest, name, dict.new())
    [OpenList, ..rest] -> parse_items(rest, [])
    [Word(raw: "<>", ..), ..rest] -> Ok(#(Empty, rest))
    [Word(text:, ..), ..rest] -> Ok(#(Token(text), rest))
    [token, ..] -> Error(UnexpectedToken(token_to_string(token)))
  }
}

fn parse_fields(
  tokens: List(Token),
  name: String,
  fields: Dict(String, Node),
) -> Result(#(Node, List(Token)), ParseError) {
  case tokens {
    [CloseNode, ..rest] -> Ok(#(Record(name:, fields:), rest))
    [Word(raw: ":" <> field, ..), ..rest] if field != "" -> {
      use #(value, rest) <- result.try(parse_field_value(rest))
      parse_fields(rest, name, dict.insert(fields, field, value))
    }
    [] -> Error(UnexpectedEnd)
    [token, ..] -> Error(UnexpectedToken(token_to_string(token)))
  }
}

/// The first token after a field name is always a value, even when it
/// starts with `:`. More tokens belong to the same field until the next
/// field name or the end of the node.
fn parse_field_value(
  tokens: List(Token),
) -> Result(#(Node, List(Token)), ParseError) {
  case tokens {
    [CloseNode, ..] -> Ok(#(Empty, tokens))
    _ -> {
      use #(first, rest) <- result.try(parse_value(tokens))
      use #(more, rest) <- result.try(parse_more_values(rest, []))
      Ok(#(combine_values(first, more), rest))
    }
  }
}

fn combine_values(first: Node, more: List(Node)) -> Node {
  case more {
    [] -> first
    _ -> NodeList([first, ..more])
  }
}

fn parse_more_values(
  tokens: List(Token),
  values: List(Node),
) -> Result(#(List(Node), List(Token)), ParseError) {
  case tokens {
    [CloseNode, ..] | [] -> Ok(#(list.reverse(values), tokens))
    [token, ..] -> parse_more_values_from(token, tokens, values)
  }
}

fn parse_more_values_from(
  token: Token,
  tokens: List(Token),
  values: List(Node),
) -> Result(#(List(Node), List(Token)), ParseError) {
  case is_field_name(token) {
    True -> Ok(#(list.reverse(values), tokens))
    False -> {
      use #(value, rest) <- result.try(parse_value(tokens))
      parse_more_values(rest, [value, ..values])
    }
  }
}

fn parse_items(
  tokens: List(Token),
  items: List(Node),
) -> Result(#(Node, List(Token)), ParseError) {
  case tokens, items {
    [CloseList, ..rest], _ -> Ok(#(NodeList(list.reverse(items)), rest))
    [Word(raw: "b", ..), ..rest], [] -> parse_integers(rest, Bitmapset, [])
    [Word(raw: "i", ..), ..rest], [] -> parse_integers(rest, Integers, [])
    [Word(raw: "o", ..), ..rest], [] -> parse_integers(rest, Oids, [])
    [Word(raw: "x", ..), ..rest], [] -> parse_integers(rest, TransactionIds, [])
    _, _ -> {
      use #(item, rest) <- result.try(parse_value(tokens))
      parse_items(rest, [item, ..items])
    }
  }
}

fn parse_integers(
  tokens: List(Token),
  kind: IntegerListKind,
  numbers: List(Int),
) -> Result(#(Node, List(Token)), ParseError) {
  case tokens {
    [CloseList, ..rest] ->
      Ok(#(IntegerList(kind:, items: list.reverse(numbers)), rest))
    [Word(raw:, ..), ..rest] -> {
      use number <- result.try(
        int.parse(raw) |> result.replace_error(NotAnInteger(raw)),
      )
      parse_integers(rest, kind, [number, ..numbers])
    }
    [] -> Error(UnexpectedEnd)
    [token, ..] -> Error(NotAnInteger(token_to_string(token)))
  }
}
