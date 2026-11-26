//// The NULL hints of a SQL file: comment lines that change what the rules
//// decide.
////
//// A hint is a comment line of the form `-- key: name, name`, for
//// example `-- not null: total, newest` or `-- params: id, nickname?`.
////
//// - `-- not null:` names computed result columns that are never NULL. The
////   generated code checks this on every row.
//// - `-- nullable:` names result columns to type as `Option`.
//// - `-- params:` names the parameters in order. A name that ends with `?`
////   makes that parameter `Option`.
////
//// Only the comment block at the top of the file counts: the `--` lines
//// and the blank lines before the first other line. A hint line after
//// the start of the statement is a plain comment.
////
//// The keys do not depend on case. A later `-- params:` line replaces an
//// earlier one.

import gleam/list.{append, drop, filter, first, fold, take_while, unique}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string.{
  ends_with, lowercase, split, split_once, trim, trim_end, trim_start,
}

/// The hints of one SQL text.
pub type Hints {
  Hints(
    not_null: List(String),
    nullable: List(String),
    /// `None` when the SQL has no `-- params:` line.
    parameters: Option(List(String)),
  )
}

/// Reads the hint lines of a SQL text.
pub fn parse_hints(sql: String) -> Hints {
  leading_lines(sql)
  |> fold(Hints(not_null: [], nullable: [], parameters: None), add_line)
}

/// Returns the lines of the comment block at the top of a SQL text: the
/// `--` lines and the blank lines before the first other line. The first
/// line of the result is line 1 of the text.
pub fn leading_lines(sql: String) -> List(String) {
  sql
  |> split("\n")
  |> take_while(fn(line) {
    case trim(line) {
      "" -> True
      "--" <> _ -> True
      _ -> False
    }
  })
}

/// Returns True when the `-- params:` hint marks the parameter at
/// `position` (from 1) with `?`.
pub fn is_optional_parameter(hints: Hints, position: Int) -> Bool {
  hints.parameters
  |> option.unwrap([])
  |> drop(position - 1)
  |> first
  |> result.map(ends_with(_, "?"))
  |> result.unwrap(False)
}

fn add_line(hints: Hints, line: String) -> Hints {
  let trimmed = trim_start(line)
  case trimmed {
    "--" <> comment -> add_comment(hints, trim_start(comment))
    _ -> hints
  }
}

fn add_comment(hints: Hints, comment: String) -> Hints {
  case split_once(comment, ":") {
    Ok(#(key, names)) -> add_hint(hints, lowercase(trim_end(key)), names)
    Error(Nil) -> hints
  }
}

fn add_hint(hints: Hints, key: String, names: String) -> Hints {
  let names =
    split(names, ",")
    |> list.map(trim)
    |> filter(fn(name) { name != "" })
  case key {
    "not null" ->
      Hints(..hints, not_null: unique(append(hints.not_null, names)))
    "nullable" ->
      Hints(..hints, nullable: unique(append(hints.nullable, names)))
    "params" -> Hints(..hints, parameters: Some(names))
    _ -> hints
  }
}
