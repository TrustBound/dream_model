//// The model hints of a SQL file: comment lines that tell the generator
//// what the generated function returns and which errors it maps.
////
//// - `-- returns: one User` returns one row, or the not-found error.
////   `maybe` returns `Option`, `many` returns `List`, and `none` returns
////   `Nil`. With no type name, `one`, `maybe` and `many` return the value
////   of the only result column, or the model's own type when the result
////   has more columns. A type of another model is named by its module, for
////   example `app/models/user.User`.
//// - `-- not found: User not found` is the text of the 404 error of `one`.
//// - `-- unique users_email_key: Email already taken` maps a violation of
////   that unique constraint to a 409 error with that text.
////
//// The NULL hints (`not null`, `nullable`, `params`) are read by
//// `dream_model/nullability/hint`; this module only keeps their line
//// numbers for messages. Keys do not depend on case, as there.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// What a generated function returns.
pub type Returns {
  /// One row. No row is the not-found error.
  ReturnsOne
  /// No row or one row, as `Option`.
  ReturnsMaybe
  /// Every row, as `List`.
  ReturnsMany
  /// Nothing, as `Nil`. For statements with no result columns.
  ReturnsNone
}

/// The name of a record type in a `returns` hint.
pub type TypeName {
  /// A type of the model of the SQL file, for example `User`.
  LocalType(name: String)
  /// A type of another model, for example `app/models/user.User`.
  ModuleType(module: String, name: String)
}

/// A `-- returns:` line.
pub type ReturnsHint {
  ReturnsHint(returns: Returns, type_name: Option(TypeName), line: Int)
}

/// A `-- not found:` line.
pub type NotFoundHint {
  NotFoundHint(message: String, line: Int)
}

/// A `-- unique <constraint>:` line.
pub type UniqueHint {
  UniqueHint(constraint: String, message: String, line: Int)
}

/// A name in a `-- not null:`, `-- nullable:` or `-- params:` line.
pub type NamedLine {
  NamedLine(name: String, line: Int)
}

/// The model hints of one SQL file.
pub type QueryHints {
  QueryHints(
    returns: Option(ReturnsHint),
    not_found: Option(NotFoundHint),
    unique: List(UniqueHint),
    /// The line of the last `-- params:` hint.
    params_line: Option(Int),
    /// Each name of the `-- not null:` and `-- nullable:` lines, with its
    /// line.
    column_names: List(NamedLine),
  )
}

/// A hint line that cannot be used.
pub type HintError {
  HintError(line: Int, message: String)
}

type Line {
  Line(number: Int, key: String, value: String)
}

/// Reads the model hints of a SQL text. Returns every refused hint line.
pub fn parse(sql: String) -> Result(QueryHints, List(HintError)) {
  let lines =
    string.split(sql, "\n")
    |> list.index_map(fn(text, index) { read_line(text, index + 1) })
    |> result.values
  let empty =
    QueryHints(
      returns: None,
      not_found: None,
      unique: [],
      params_line: None,
      column_names: [],
    )
  let #(hints, errors) = list.fold(lines, #(empty, []), add_line)
  let errors =
    list.append(list.reverse(errors), check_not_found(hints))
    |> list.sort(compare_errors)
  case errors {
    [] -> Ok(QueryHints(..hints, unique: list.reverse(hints.unique)))
    _ -> Error(errors)
  }
}

/// Returns `name` of a type name, with the module when it has one.
pub fn type_name_to_string(type_name: TypeName) -> String {
  case type_name {
    LocalType(name) -> name
    ModuleType(module, name) -> module <> "." <> name
  }
}

/// Returns the name of a type without its module, for example `User`.
pub fn base_name(type_name: TypeName) -> String {
  case type_name {
    LocalType(name) -> name
    ModuleType(name:, ..) -> name
  }
}

/// Returns the word of a returns form, as in the hint.
pub fn returns_to_string(returns: Returns) -> String {
  case returns {
    ReturnsOne -> "one"
    ReturnsMaybe -> "maybe"
    ReturnsMany -> "many"
    ReturnsNone -> "none"
  }
}

fn compare_errors(first: HintError, second: HintError) -> order.Order {
  int.compare(first.line, second.line)
}

fn read_line(text: String, number: Int) -> Result(Line, Nil) {
  case string.trim_start(text) {
    "--" <> comment -> split_comment(string.trim(comment), number)
    _ -> Error(Nil)
  }
}

fn split_comment(comment: String, number: Int) -> Result(Line, Nil) {
  use #(key, value) <- result.map(string.split_once(comment, ":"))
  Line(number:, key: string.trim(key), value: string.trim(value))
}

fn add_line(
  state: #(QueryHints, List(HintError)),
  line: Line,
) -> #(QueryHints, List(HintError)) {
  let #(hints, errors) = state
  let added = case string.lowercase(line.key) {
    "returns" -> add_returns(hints, line)
    "not found" -> add_not_found(hints, line)
    "params" -> Ok(QueryHints(..hints, params_line: Some(line.number)))
    "not null" | "nullable" -> Ok(add_column_names(hints, line))
    "unique" ->
      Error(
        "the 'unique' hint names no constraint; write 'unique <constraint>: <message>'",
      )
    "unique " <> _ -> add_unique(hints, line)
    _ -> Ok(hints)
  }
  case added {
    Ok(hints) -> #(hints, errors)
    Error(message) -> #(hints, [HintError(line.number, message), ..errors])
  }
}

fn add_column_names(hints: QueryHints, line: Line) -> QueryHints {
  let names =
    string.split(line.value, ",")
    |> list.map(string.trim)
    |> list.filter(fn(name) { name != "" })
    |> list.map(NamedLine(_, line.number))
  QueryHints(..hints, column_names: list.append(hints.column_names, names))
}

fn add_returns(hints: QueryHints, line: Line) -> Result(QueryHints, String) {
  use Nil <- result.try(refuse_second(
    hints.returns |> option.map(fn(hint) { hint.line }),
    "returns",
  ))
  use hint <- result.map(parse_returns(line))
  QueryHints(..hints, returns: Some(hint))
}

fn refuse_second(earlier: Option(Int), key: String) -> Result(Nil, String) {
  case earlier {
    Some(line) ->
      Error(
        "a second '"
        <> key
        <> "' hint; the first one is on line "
        <> int.to_string(line),
      )
    None -> Ok(Nil)
  }
}

fn parse_returns(line: Line) -> Result(ReturnsHint, String) {
  let words =
    string.split(line.value, " ")
    |> list.filter(fn(word) { word != "" })
  case words {
    [form] -> parse_form(form) |> result.map(ReturnsHint(_, None, line.number))
    [form, type_text] -> parse_form_and_type(form, type_text, line.number)
    _ ->
      Error(
        "'returns: "
        <> line.value
        <> "' is not a returns hint; write 'returns: one', 'maybe', 'many' or 'none', with a type name after it, for example 'returns: one User'",
      )
  }
}

fn parse_form_and_type(
  form: String,
  type_text: String,
  line: Int,
) -> Result(ReturnsHint, String) {
  use returns <- result.try(parse_form(form))
  use <- refuse_type_of_none(returns)
  use type_name <- result.map(parse_type_name(type_text))
  ReturnsHint(returns, Some(type_name), line)
}

fn refuse_type_of_none(
  returns: Returns,
  next: fn() -> Result(ReturnsHint, String),
) -> Result(ReturnsHint, String) {
  case returns {
    ReturnsNone -> Error("'returns: none' takes no type name")
    _ -> next()
  }
}

fn parse_form(form: String) -> Result(Returns, String) {
  case string.lowercase(form) {
    "one" -> Ok(ReturnsOne)
    "maybe" -> Ok(ReturnsMaybe)
    "many" -> Ok(ReturnsMany)
    "none" -> Ok(ReturnsNone)
    _ ->
      Error(
        "'" <> form <> "' is not a returns form; write one, maybe, many or none",
      )
  }
}

fn parse_type_name(text: String) -> Result(TypeName, String) {
  case string.split_once(text, ".") {
    Ok(#(module, name)) -> parse_module_type(module, name, text)
    Error(Nil) -> check_type_name(name: text, text:) |> result.map(LocalType)
  }
}

fn parse_module_type(
  module: String,
  name: String,
  text: String,
) -> Result(TypeName, String) {
  use name <- result.try(check_type_name(name:, text:))
  case list.all(string.split(module, "/"), is_module_segment) {
    True -> Ok(ModuleType(module:, name:))
    False ->
      Error(
        "'"
        <> text
        <> "' is not a type name; a type of another model is its module and its type, for example app/models/user.User",
      )
  }
}

fn check_type_name(
  name name: String,
  text text: String,
) -> Result(String, String) {
  case is_type_name(name) {
    True -> Ok(name)
    False ->
      Error(
        "'"
        <> text
        <> "' is not a type name; a type name starts with a capital letter and has only letters and digits, for example User",
      )
  }
}

/// Returns True for a Gleam type name: a capital letter, then letters and
/// digits.
pub fn is_type_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains(uppercase_letters, first)
      && list.all(rest, fn(character) {
        string.contains(
          uppercase_letters <> lowercase_letters <> digits,
          character,
        )
      })
    [] -> False
  }
}

/// Returns True for one segment of a Gleam module path: a lowercase letter,
/// then lowercase letters, digits and underscores.
pub fn is_module_segment(segment: String) -> Bool {
  case string.to_graphemes(segment) {
    [first, ..rest] ->
      string.contains(lowercase_letters, first)
      && list.all(rest, fn(character) {
        string.contains(lowercase_letters <> digits <> "_", character)
      })
    [] -> False
  }
}

const uppercase_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

fn add_not_found(hints: QueryHints, line: Line) -> Result(QueryHints, String) {
  use Nil <- result.try(refuse_second(
    hints.not_found |> option.map(fn(hint) { hint.line }),
    "not found",
  ))
  use message <- result.map(require_message(line.value, "not found"))
  QueryHints(..hints, not_found: Some(NotFoundHint(message, line.number)))
}

fn require_message(value: String, key: String) -> Result(String, String) {
  case value {
    "" -> Error("the '" <> key <> "' hint has no message")
    _ -> Ok(value)
  }
}

fn add_unique(hints: QueryHints, line: Line) -> Result(QueryHints, String) {
  let constraint = string.trim(string.drop_start(line.key, 7))
  let key = "unique " <> constraint
  use Nil <- result.try(refuse_second(
    list.find(hints.unique, fn(hint) { hint.constraint == constraint })
      |> result.map(fn(hint) { hint.line })
      |> option.from_result,
    key,
  ))
  use message <- result.map(require_message(line.value, key))
  QueryHints(..hints, unique: [
    UniqueHint(constraint:, message:, line: line.number),
    ..hints.unique
  ])
}

fn check_not_found(hints: QueryHints) -> List(HintError) {
  case hints.not_found, hints.returns {
    None, _ -> []
    Some(_), Some(ReturnsHint(returns: ReturnsOne, ..)) -> []
    Some(hint), _ -> [
      HintError(
        hint.line,
        "the 'not found' hint needs 'returns: one'; only 'one' fails when there is no row",
      ),
    ]
  }
}
