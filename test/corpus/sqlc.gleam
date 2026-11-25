//// Reads sqlc's PostgreSQL end-to-end test cases from build/corpus, the
//// same way as the proof of concept's `corpus.py`: each case directory
//// with a `sqlc.json` or `sqlc.yaml` under a `postgresql` path, its schema
//// files and its query files, the queries split at `-- name:` lines, and
//// sqlc's named parameters rewritten to `$1`, `$2`, ...
////
//// `scripts/fetch-corpus.sh` fetches the corpus.

import filepath
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import simplifile

/// The directory that `scripts/fetch-corpus.sh` fills.
pub const directory = "build/corpus"

/// One test case: its directory, its schema SQL and its query SQL.
pub type Case {
  Case(directory: String, schema: String, queries: String)
}

type Package {
  Package(engine: String, schema: List(String), queries: List(String))
}

@external(erlang, "dream_model_test_ffi", "decode_json")
fn decode_json(text: String) -> Result(Dynamic, Nil)

/// Reads every case, without the cases whose schema and queries are the
/// same as an earlier case's. Fails when the corpus is not there.
pub fn load_cases() -> Result(List(Case), String) {
  use files <- result.try(
    simplifile.get_files(directory)
    |> result.replace_error(
      directory
      <> " does not exist: run `sh scripts/fetch-corpus.sh` to fetch the sqlc corpus",
    ),
  )
  let directories =
    files
    |> list.filter(fn(path) {
      string.starts_with(filepath.base_name(path), "sqlc.")
      && string.contains(path, "postgresql")
    })
    |> list.map(filepath.directory_name)
    |> list.unique
    |> list.sort(string.compare)
  let #(cases, _) =
    list.fold(directories, #([], set.new()), fn(state, case_directory) {
      list.fold(load_config(case_directory), state, fn(state, package) {
        add_case(state, case_directory, package)
      })
    })
  Ok(list.reverse(cases))
}

fn add_case(
  state: #(List(Case), set.Set(String)),
  case_directory: String,
  package: Package,
) -> #(List(Case), set.Set(String)) {
  let #(cases, seen) = state
  let schema_files = read_paths(case_directory, package.schema)
  let query_files = read_paths(case_directory, package.queries)
  let schema =
    list.map(schema_files, fn(file) { strip_down(read(file)) })
    |> string.join("\n")
  let queries = list.map(query_files, read) |> string.join("\n")
  let key = schema <> queries
  case schema_files == [] || query_files == [] || set.contains(seen, key) {
    True -> state
    False -> #(
      [Case(case_directory, schema, queries), ..cases],
      set.insert(seen, key),
    )
  }
}

fn read(path: String) -> String {
  simplifile.read(path) |> result.unwrap("")
}

/// The config file of a case: `sqlc.json`, `sqlc.yaml` or `sqlc.yml`, the
/// first one that exists. Returns its PostgreSQL packages.
fn load_config(case_directory: String) -> List(Package) {
  let found =
    ["sqlc.json", "sqlc.yaml", "sqlc.yml"]
    |> list.map(filepath.join(case_directory, _))
    |> list.find(fn(path) { simplifile.is_file(path) == Ok(True) })
  let packages = case found {
    Ok(path) -> parse_config(path, read(path))
    Error(Nil) -> []
  }
  list.filter(packages, fn(package) { package.engine == "postgresql" })
}

fn parse_config(path: String, text: String) -> List(Package) {
  case string.ends_with(path, ".json") {
    True -> parse_json_config(text)
    False -> parse_yaml_config(text)
  }
}

fn parse_json_config(text: String) -> List(Package) {
  let one_or_many =
    decode.one_of(decode.string |> decode.map(fn(item) { [item] }), [
      decode.list(decode.string),
    ])
  let package = {
    use engine <- decode.optional_field("engine", "postgresql", decode.string)
    use schema <- decode.optional_field("schema", [], one_or_many)
    use queries <- decode.optional_field("queries", [], one_or_many)
    decode.success(Package(engine:, schema:, queries:))
  }
  let config = {
    use packages <- decode.optional_field("packages", [], decode.list(package))
    use sql <- decode.optional_field("sql", [], decode.list(package))
    decode.success(case packages {
      [] -> sql
      _ -> packages
    })
  }
  decode_json(text)
  |> result.try(fn(value) {
    decode.run(value, config) |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

/// Reads the `engine`, `schema` and `queries` keys of a YAML config. It
/// reads the subset of YAML that the corpus uses: one package, and each
/// key with one value on its line or a list of `- item` lines after it.
fn parse_yaml_config(text: String) -> List(Package) {
  let lines = string.split(text, "\n")
  let values = fn(key: String) { yaml_values(lines, key) }
  let engine = case values("engine") {
    [engine, ..] -> engine
    [] -> "postgresql"
  }
  [Package(engine:, schema: values("schema"), queries: values("queries"))]
}

fn yaml_values(lines: List(String), key: String) -> List(String) {
  let after =
    list.drop_while(lines, fn(line) { yaml_key_value(line, key) == Error(Nil) })
  case after {
    [] -> []
    [line, ..rest] ->
      yaml_value_or_list(yaml_key_value(line, key) |> result.unwrap(""), rest)
  }
}

fn yaml_value_or_list(value: String, rest: List(String)) -> List(String) {
  case value {
    "" ->
      list.take_while(rest, fn(line) {
        string.starts_with(string.trim(line), "- ")
      })
      |> list.map(fn(line) { unquote(string.drop_start(string.trim(line), 2)) })
    _ -> [value]
  }
}

fn yaml_key_value(line: String, key: String) -> Result(String, Nil) {
  let trimmed = string.trim(line)
  let trimmed = case string.starts_with(trimmed, "- ") {
    True -> string.trim(string.drop_start(trimmed, 2))
    False -> trimmed
  }
  case string.starts_with(trimmed, key <> ":") {
    True -> Ok(unquote(string.drop_start(trimmed, string.length(key) + 1)))
    False -> Error(Nil)
  }
}

fn unquote(value: String) -> String {
  let value = string.trim(value)
  value
  |> string.replace("\"", "")
  |> string.replace("'", "")
}

/// The files of the paths of a config: a directory gives its `.sql` files
/// in order, a file gives itself.
fn read_paths(case_directory: String, paths: List(String)) -> List(String) {
  list.flat_map(paths, fn(path) {
    let full = filepath.join(case_directory, path)
    case simplifile.is_directory(full), simplifile.is_file(full) {
      Ok(True), _ ->
        simplifile.read_directory(full)
        |> result.unwrap([])
        |> list.filter(fn(name) { string.ends_with(name, ".sql") })
        |> list.sort(string.compare)
        |> list.map(filepath.join(full, _))
      _, Ok(True) -> [full]
      _, _ -> []
    }
  })
}

/// Keeps only the Up part of a goose migration.
fn strip_down(sql: String) -> String {
  case string.split_once(sql, "-- +goose Down") {
    Ok(#(up, _)) -> up
    Error(Nil) -> sql
  }
}

// --- Queries ---------------------------------------------------------------

/// Splits a query file at its `-- name: Name :kind` lines. Returns each
/// name and query, without the last semicolon.
pub fn split_queries(text: String) -> List(#(String, String)) {
  let #(named, current) =
    string.split(text, "\n")
    |> list.fold(#([], Error(Nil)), fn(state, line) {
      let #(named, current) = state
      case query_name(line), current {
        Ok(name), Ok(open) -> #([open, ..named], Ok(#(name, [])))
        Ok(name), Error(Nil) -> #(named, Ok(#(name, [])))
        Error(Nil), Ok(#(name, lines)) -> #(named, Ok(#(name, [line, ..lines])))
        Error(Nil), Error(Nil) -> #(named, current)
      }
    })
  let named = case current {
    Ok(open) -> [open, ..named]
    Error(Nil) -> named
  }
  named
  |> list.reverse
  |> list.filter_map(fn(pair) {
    let #(name, lines) = pair
    let body =
      list.reverse(lines)
      |> string.join("\n")
      |> string.trim
      |> trim_semicolons
    case body {
      "" -> Error(Nil)
      _ -> Ok(#(name, body))
    }
  })
}

fn trim_semicolons(text: String) -> String {
  case string.ends_with(text, ";") {
    True -> trim_semicolons(string.trim_end(string.drop_end(text, 1)))
    False -> text
  }
}

/// The name of a `-- name: Name :kind` line.
fn query_name(line: String) -> Result(String, Nil) {
  use rest <- result.try(drop_prefix(line, "--"))
  use rest <- result.try(drop_prefix(string.trim_start(rest), "name:"))
  use #(name, kind) <- result.try(string.split_once(
    string.trim_start(rest),
    " ",
  ))
  case string.starts_with(string.trim_start(kind), ":") && name != "" {
    True -> Ok(name)
    False -> Error(Nil)
  }
}

fn drop_prefix(text: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(text, prefix) {
    True -> Ok(string.drop_start(text, string.length(prefix)))
    False -> Error(Nil)
  }
}

/// Rewrites sqlc's named parameters (`sqlc.arg(name)`, `sqlc.narg(name)`
/// and `@name`) to numbered ones, after the highest `$n` that the query
/// already has. Returns an error for the queries that use `sqlc.slice`,
/// `sqlc.embed` or `/*SLICE`, which have no SQL form.
pub fn rewrite_parameters(sql: String) -> Result(String, Nil) {
  let unsupported =
    list.any(["sqlc.slice", "sqlc.embed", "/*SLICE"], string.contains(sql, _))
  case unsupported {
    True -> Error(Nil)
    False -> {
      let characters = string.to_graphemes(sql)
      let highest = highest_parameter(characters, 0)
      let #(rewritten, _) =
        rewrite(characters, "", Rewriting([], dict.new(), highest))
      Ok(rewritten)
    }
  }
}

type Rewriting {
  Rewriting(output: List(String), numbers: Dict(String, Int), highest: Int)
}

fn highest_parameter(characters: List(String), highest: Int) -> Int {
  case characters {
    [] -> highest
    ["$", ..rest] -> {
      let digits = list.take_while(rest, is_digit)
      let number = int.parse(string.concat(digits)) |> result.unwrap(0)
      highest_parameter(rest, int.max(highest, number))
    }
    [_, ..rest] -> highest_parameter(rest, highest)
  }
}

fn rewrite(
  characters: List(String),
  previous: String,
  state: Rewriting,
) -> #(String, Rewriting) {
  case characters {
    [] -> #(string.concat(list.reverse(state.output)), state)
    ["s", "q", "l", "c", ".", ..rest] ->
      rewrite_sqlc(characters, sqlc_argument(rest), state)
    ["@", ..rest] if previous != ":" && previous != "@" ->
      rewrite_at(characters, rest, previous, state)
    _ -> copy(characters, state)
  }
}

fn rewrite_sqlc(
  characters: List(String),
  argument: Result(#(String, List(String)), Nil),
  state: Rewriting,
) -> #(String, Rewriting) {
  case argument {
    Ok(#(name, rest)) -> {
      let #(parameter, state) = number_for(state, name)
      rewrite(
        rest,
        ")",
        Rewriting(..state, output: [parameter, ..state.output]),
      )
    }
    Error(Nil) -> copy(characters, state)
  }
}

fn rewrite_at(
  characters: List(String),
  rest: List(String),
  previous: String,
  state: Rewriting,
) -> #(String, Rewriting) {
  let name = list.take_while(rest, is_word)
  case name, is_word(previous) {
    [], _ | _, True -> copy(characters, state)
    _, False -> {
      let #(parameter, state) = number_for(state, string.concat(name))
      let rest = list.drop(rest, list.length(name))
      let previous = list.last(name) |> result.unwrap("")
      rewrite(
        rest,
        previous,
        Rewriting(..state, output: [parameter, ..state.output]),
      )
    }
  }
}

fn copy(characters: List(String), state: Rewriting) -> #(String, Rewriting) {
  case characters {
    [] -> rewrite([], "", state)
    [character, ..rest] ->
      rewrite(
        rest,
        character,
        Rewriting(..state, output: [character, ..state.output]),
      )
  }
}

fn number_for(state: Rewriting, name: String) -> #(String, Rewriting) {
  case dict.get(state.numbers, name) {
    Ok(number) -> #("$" <> int.to_string(number), state)
    Error(Nil) -> {
      let number = state.highest + 1
      #(
        "$" <> int.to_string(number),
        Rewriting(
          ..state,
          numbers: dict.insert(state.numbers, name, number),
          highest: number,
        ),
      )
    }
  }
}

/// Reads `arg(name)` or `narg(name)` after `sqlc.`, with optional quotes
/// and spaces around the name. Returns the name and what follows the `)`.
fn sqlc_argument(
  characters: List(String),
) -> Result(#(String, List(String)), Nil) {
  use rest <- result.try(case characters {
    ["a", "r", "g", "(", ..rest] -> Ok(rest)
    ["n", "a", "r", "g", "(", ..rest] -> Ok(rest)
    _ -> Error(Nil)
  })
  let rest = list.drop_while(rest, is_space)
  let rest = drop_one(rest, "'")
  let rest = drop_one(rest, "\"")
  let name = list.take_while(rest, is_word)
  let rest = list.drop(rest, list.length(name))
  let rest = drop_one(rest, "'")
  let rest = drop_one(rest, "\"")
  let rest = list.drop_while(rest, is_space)
  case name, rest {
    [_, ..], [")", ..rest] -> Ok(#(string.concat(name), rest))
    _, _ -> Error(Nil)
  }
}

fn drop_one(characters: List(String), character: String) -> List(String) {
  case characters {
    [first, ..rest] if first == character -> rest
    _ -> characters
  }
}

fn is_space(character: String) -> Bool {
  string.trim(character) == ""
}

fn is_digit(character: String) -> Bool {
  string.contains("0123456789", character) && character != ""
}

fn is_word(character: String) -> Bool {
  character != ""
  && string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    character,
  )
}
