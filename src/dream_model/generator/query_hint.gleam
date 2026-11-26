//// The model hints of a SQL file: comment lines that tell the generator
//// what the generated function returns and which errors it maps.
////
//// - `-- returns: one User` returns one row, or `dream_errors.NotFound`.
////   `maybe` returns `Option`, `many` returns `List`, and `none` returns
////   `Nil`. With no type name, `one`, `maybe` and `many` return the value
////   of the only result column, or the model's own type when the result
////   has more columns. A type of another model is named by its module, for
////   example `app/models/user.User`.
//// - `-- unique: users_email_key, users_pkey` maps a violation of one of
////   these unique constraints to `dream_errors.Conflict`, with the query
////   error as the cause. A hint holds no text for a user: the app writes
////   that text.
//// - `-- not null elements: tags, scores` promises that the elements of
////   these array result columns are never NULL. Each one is a `List(T)`,
////   not a `List(Option(T))`, and the generated code checks the promise
////   on each row.
////
//// The old forms `-- unique <constraint>: <message>` and `-- not found:
//// <text>` are refused, with the new form in the message.
////
//// The NULL hints (`not null`, `nullable`, `params`) are read by
//// `dream_model/nullability/hint`; this module only keeps their line
//// numbers for messages. Keys do not depend on case, as there. As there,
//// only the comment block at the top of the file counts.

import dream_model/nullability/hint
import gleam/int.{to_string}
import gleam/list.{all, append, filter, find, fold, index_map, reverse, try_fold}
import gleam/option.{type Option, None, Some}
import gleam/result.{try, values}
import gleam/string.{
  contains, lowercase, split, split_once, to_graphemes, trim, trim_start,
}

/// What a generated function returns.
pub type Returns {
  /// One row. No row is `dream_errors.NotFound`.
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

/// A constraint name of a `-- unique:` line.
pub type UniqueHint {
  UniqueHint(constraint: String, line: Int)
}

/// A name in a `-- not null:`, `-- nullable:` or `-- params:` line.
pub type NamedLine {
  NamedLine(name: String, line: Int)
}

/// The model hints of one SQL file.
pub type QueryHints {
  QueryHints(
    returns: Option(ReturnsHint),
    unique: List(UniqueHint),
    /// The line of the last `-- params:` hint.
    parameters_line: Option(Int),
    /// Each name of the `-- not null:` and `-- nullable:` lines, with its
    /// line.
    column_names: List(NamedLine),
    /// Each name of the `-- not null elements:` lines, with its line.
    element_names: List(NamedLine),
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
    hint.leading_lines(sql)
    |> index_map(fn(text, index) { read_line(text, index + 1) })
    |> values
  let empty =
    QueryHints(
      returns: None,
      unique: [],
      parameters_line: None,
      column_names: [],
      element_names: [],
    )
  let #(hints, errors) = fold(lines, #(empty, []), add_line)
  case errors {
    [] -> Ok(hints)
    _ -> Error(reverse(errors))
  }
}

/// Returns `name` of a type name, with the module when it has one.
pub fn type_name_to_string(type_name: TypeName) -> String {
  case type_name {
    LocalType(name) -> name
    ModuleType(module, name) -> module <> "." <> name
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

fn read_line(text: String, number: Int) -> Result(Line, Nil) {
  case trim_start(text) {
    "--" <> comment -> split_comment(trim(comment), number)
    _ -> Error(Nil)
  }
}

fn split_comment(comment: String, number: Int) -> Result(Line, Nil) {
  use #(key, value) <- result.map(split_once(comment, ":"))
  Line(number:, key: trim(key), value: trim(value))
}

fn add_line(
  state: #(QueryHints, List(HintError)),
  line: Line,
) -> #(QueryHints, List(HintError)) {
  let #(hints, errors) = state
  let added = case lowercase(line.key) {
    "returns" -> add_returns(hints, line)
    "not found" ->
      Error(
        "the 'not found' hint is gone: no row gives dream_errors.NotFound; remove this line and write the text for the user where the app maps dream_errors.NotFound",
      )
    "params" -> Ok(QueryHints(..hints, parameters_line: Some(line.number)))
    "not null" | "nullable" -> Ok(add_column_names(hints, line))
    "not null elements" -> Ok(add_element_names(hints, line))
    "unique" -> add_unique(hints, line)
    "unique " <> constraint ->
      Error(
        "'"
        <> trim(line.key <> ": " <> line.value)
        <> "' is the old form of the unique hint, and a hint holds no message now; write 'unique: "
        <> trim(constraint)
        <> "' and write the text for the user where the app maps dream_errors.Conflict",
      )
    _ -> Ok(hints)
  }
  case added {
    Ok(hints) -> #(hints, errors)
    Error(message) -> #(hints, [HintError(line.number, message), ..errors])
  }
}

fn add_column_names(hints: QueryHints, line: Line) -> QueryHints {
  QueryHints(
    ..hints,
    column_names: append(hints.column_names, named_lines(line)),
  )
}

fn add_element_names(hints: QueryHints, line: Line) -> QueryHints {
  QueryHints(
    ..hints,
    element_names: append(hints.element_names, named_lines(line)),
  )
}

fn named_lines(line: Line) -> List(NamedLine) {
  split(line.value, ",")
  |> list.map(trim)
  |> filter(fn(name) { name != "" })
  |> list.map(NamedLine(_, line.number))
}

fn add_returns(hints: QueryHints, line: Line) -> Result(QueryHints, String) {
  use Nil <- try(refuse_second(
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
        <> to_string(line),
      )
    None -> Ok(Nil)
  }
}

fn parse_returns(line: Line) -> Result(ReturnsHint, String) {
  let words =
    split(line.value, " ")
    |> filter(fn(word) { word != "" })
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
  use returns <- try(parse_form(form))
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
  case lowercase(form) {
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
  case split_once(text, ".") {
    Ok(#(module, name)) -> parse_module_type(module, name, text)
    Error(Nil) -> check_type_name(name: text, text:) |> result.map(LocalType)
  }
}

fn parse_module_type(
  module: String,
  name: String,
  text: String,
) -> Result(TypeName, String) {
  use name <- try(check_type_name(name:, text:))
  case all(split(module, "/"), is_module_segment) {
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
  case to_graphemes(name) {
    [first, ..rest] ->
      contains(uppercase_letters, first)
      && all(rest, fn(character) {
        contains(uppercase_letters <> lowercase_letters <> digits, character)
      })
    [] -> False
  }
}

/// Returns True for one segment of a Gleam module path: a lowercase letter,
/// then lowercase letters, digits and underscores.
pub fn is_module_segment(segment: String) -> Bool {
  case to_graphemes(segment) {
    [first, ..rest] ->
      contains(lowercase_letters, first)
      && all(rest, fn(character) {
        contains(lowercase_letters <> digits <> "_", character)
      })
    [] -> False
  }
}

const uppercase_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

fn add_unique(hints: QueryHints, line: Line) -> Result(QueryHints, String) {
  case named_lines(line) {
    [] ->
      Error(
        "the 'unique' hint names no constraint; write 'unique: <constraint>', for example 'unique: users_email_key'",
      )
    names -> try_fold(names, hints, add_unique_name)
  }
}

fn add_unique_name(
  hints: QueryHints,
  named: NamedLine,
) -> Result(QueryHints, String) {
  case find(hints.unique, fn(hint) { hint.constraint == named.name }) {
    Ok(earlier) ->
      Error(
        "the constraint '"
        <> named.name
        <> "' is in a 'unique' hint a second time; the first one is on line "
        <> to_string(earlier.line),
      )
    Error(Nil) ->
      Ok(
        QueryHints(
          ..hints,
          unique: append(hints.unique, [
            UniqueHint(constraint: named.name, line: named.line),
          ]),
        ),
      )
  }
}
