//// Writes the imports of a generated module, and imports each name bare
//// when the bare name clashes with no other name.
////
//// The generator writes the code of a module with the module before each
//// imported name, for example `client.query`. `unqualify` finds each such name
//// in the code, but not in strings and comments. It imports the name bare,
//// as in `import dream_postgres/client.{query}`, and removes the module
//// from each use of the name. A name keeps its module when the bare name
//// would clash:
////
//// - the code already uses the bare name. This is a name that comes from
////   SQL, for example the function `query` of a file `query.sql`, a
////   parameter, a field or a type. It can also be a name of the code
////   itself, for example a variable.
//// - an earlier import gives a name that is the same, for example
////   `client.int` and `decode.int`. The first import in the list keeps the
////   bare name.
////
//// Gleam keeps types and values apart. Thus a type `Error` does not clash
//// with the constructor `Error` of the prelude.

import gleam/list.{
  any, append, drop, filter, filter_map, flat_map, fold, map, reverse, sort,
  unique,
}
import gleam/set.{type Set, from_list, insert, new}
import gleam/string.{compare, concat, contains, join, slice, to_graphemes}

/// A module that a generated module can import.
pub type Import {
  Import(
    /// The module, for example `dream_postgres/client`.
    path: String,
    /// The name before the `.` in the code, for example `client`.
    alias: String,
    /// The names with a capital letter that the code uses only as a
    /// constructor, for example `NotFound`.
    constructors: List(String),
    /// The names with a capital letter that the code uses as a type and as
    /// a constructor, for example the record `User` of another model. Each
    /// other name with a capital letter is a type.
    records: List(String),
  )
}

type Namespace {
  TypeNamespace
  ValueNamespace
}

type Token {
  /// Text that `unqualify` does not change: strings, comments, spaces, signs
  /// and the names after a `.` of a field.
  Code(String)
  /// A name with no module before it.
  Bare(String)
  /// A name with the alias of an import before it.
  Qualified(alias: String, name: String)
}

/// The constructors of the prelude. They are no types, so they do not
/// clash with an imported type.
const prelude_constructors = ["Ok", "Error", "True", "False"]

const name_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

const uppercase_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const digits = "0123456789"

/// Returns the import line of each module that the code uses, in the order
/// of `imports`, and the code with the bare names.
pub fn unqualify(
  code: String,
  imports: List(Import),
) -> #(List(String), String) {
  let aliases = map(imports, fn(entry) { entry.alias })
  let tokens = lex(to_graphemes(code), aliases, False, [])
  let aliases_taken =
    from_list(map(aliases, fn(alias) { #(ValueNamespace, alias) }))
  let taken = fold(tokens, aliases_taken, add_bare)
  let references = flat_map(imports, references_of(_, tokens))
  let #(_, bare) =
    fold(references, #(taken, new()), fn(state, reference) {
      choose(state, reference)
    })
  let lines = filter_map(imports, import_line(_, tokens, bare))
  let text =
    map(tokens, fn(token) { token_text(token, bare) })
    |> concat
  #(lines, text)
}

// --- Choice ----------------------------------------------------------------

/// The names of an import that the code uses, sorted, with their
/// namespaces.
fn references_of(
  entry: Import,
  tokens: List(Token),
) -> List(#(Import, String, List(Namespace))) {
  used_names(entry, tokens)
  |> map(fn(name) { #(entry, name, imported_namespaces(entry, name)) })
}

fn used_names(entry: Import, tokens: List(Token)) -> List(String) {
  filter_map(tokens, fn(token) {
    case token {
      Qualified(alias:, name:) if alias == entry.alias -> Ok(name)
      _ -> Error(Nil)
    }
  })
  |> unique
  |> sort(compare)
}

/// Makes the name bare when no taken name of its namespaces is the same,
/// and then takes it.
fn choose(
  state: #(Set(#(Namespace, String)), Set(#(String, String))),
  reference: #(Import, String, List(Namespace)),
) -> #(Set(#(Namespace, String)), Set(#(String, String))) {
  let #(taken, bare) = state
  let #(entry, name, namespaces) = reference
  let keys = map(namespaces, fn(namespace) { #(namespace, name) })
  case any(keys, set.contains(taken, _)) {
    True -> state
    False -> #(fold(keys, taken, insert), insert(bare, #(entry.alias, name)))
  }
}

fn add_bare(
  taken: Set(#(Namespace, String)),
  token: Token,
) -> Set(#(Namespace, String)) {
  case token {
    Bare(name) ->
      fold(bare_namespaces(name), taken, fn(taken, namespace) {
        insert(taken, #(namespace, name))
      })
    _ -> taken
  }
}

/// The namespaces of a name that the code uses with no module. A name with
/// a capital letter is a type or a constructor; only the constructors of
/// the prelude are surely no types.
fn bare_namespaces(name: String) -> List(Namespace) {
  case is_capitalised(name), list.contains(prelude_constructors, name) {
    False, _ | True, True -> [ValueNamespace]
    True, False -> [TypeNamespace, ValueNamespace]
  }
}

fn imported_namespaces(entry: Import, name: String) -> List(Namespace) {
  let is_constructor = list.contains(entry.constructors, name)
  let is_record = list.contains(entry.records, name)
  case is_capitalised(name), is_constructor, is_record {
    False, _, _ | True, True, _ -> [ValueNamespace]
    True, False, True -> [TypeNamespace, ValueNamespace]
    True, False, False -> [TypeNamespace]
  }
}

fn is_capitalised(name: String) -> Bool {
  contains(uppercase_letters, slice(name, 0, 1))
}

// --- Output ----------------------------------------------------------------

fn import_line(
  entry: Import,
  tokens: List(Token),
  bare: Set(#(String, String)),
) -> Result(String, Nil) {
  case used_names(entry, tokens) {
    [] -> Error(Nil)
    names -> {
      let bare_names =
        filter(names, fn(name) { set.contains(bare, #(entry.alias, name)) })
      let types =
        filter(bare_names, fn(name) {
          list.contains(imported_namespaces(entry, name), TypeNamespace)
        })
        |> map(fn(name) { "type " <> name })
      let values =
        filter(bare_names, fn(name) {
          list.contains(imported_namespaces(entry, name), ValueNamespace)
        })
      case append(types, values) {
        [] -> Ok("import " <> entry.path)
        items -> Ok("import " <> entry.path <> ".{" <> join(items, ", ") <> "}")
      }
    }
  }
}

fn token_text(token: Token, bare: Set(#(String, String))) -> String {
  case token {
    Code(text) | Bare(text) -> text
    Qualified(alias:, name:) ->
      case set.contains(bare, #(alias, name)) {
        True -> name
        False -> alias <> "." <> name
      }
  }
}

// --- Tokens ----------------------------------------------------------------

/// Splits Gleam code into tokens. `after_dot` is True after a `.` that is
/// not part of `..`: the name that follows it is a field or a name of a
/// module.
fn lex(
  characters: List(String),
  aliases: List(String),
  after_dot: Bool,
  tokens: List(Token),
) -> List(Token) {
  case characters {
    [] -> reverse(tokens)
    ["\"", ..rest] -> {
      let #(literal, rest) = take_string(rest, ["\""])
      lex(rest, aliases, False, [Code(literal), ..tokens])
    }
    ["/", "/", ..rest] -> {
      let #(comment, rest) = take_line(rest, ["/", "/"])
      lex(rest, aliases, False, [Code(comment), ..tokens])
    }
    [".", ".", ..rest] -> lex(rest, aliases, False, [Code(".."), ..tokens])
    [".", ..rest] -> lex(rest, aliases, True, [Code("."), ..tokens])
    [character, ..rest] ->
      case contains(name_characters, character) {
        True -> {
          let #(word, rest) = take_name(characters, [])
          let #(token, rest) = name_token(word, rest, aliases, after_dot)
          lex(rest, aliases, False, [token, ..tokens])
        }
        False -> lex(rest, aliases, False, [Code(character), ..tokens])
      }
  }
}

/// The token of a name, and the characters after it.
fn name_token(
  word: String,
  rest: List(String),
  aliases: List(String),
  after_dot: Bool,
) -> #(Token, List(String)) {
  let is_number = contains(digits, slice(word, 0, 1))
  let is_qualified = case rest {
    [".", next, ..] ->
      list.contains(aliases, word) && contains(name_characters, next)
    _ -> False
  }
  case is_number || after_dot, is_qualified {
    True, _ -> #(Code(word), rest)
    False, True -> {
      let #(name, after) = take_name(drop(rest, 1), [])
      #(Qualified(alias: word, name:), after)
    }
    False, False -> #(Bare(word), rest)
  }
}

fn take_name(
  characters: List(String),
  taken: List(String),
) -> #(String, List(String)) {
  case characters {
    [character, ..rest] ->
      case contains(name_characters, character) {
        True -> take_name(rest, [character, ..taken])
        False -> #(join_reversed(taken), characters)
      }
    [] -> #(join_reversed(taken), [])
  }
}

/// Takes a string literal up to its closing quote, with each escaped
/// character.
fn take_string(
  characters: List(String),
  taken: List(String),
) -> #(String, List(String)) {
  case characters {
    ["\\", character, ..rest] -> take_string(rest, [character, "\\", ..taken])
    ["\"", ..rest] -> #(join_reversed(["\"", ..taken]), rest)
    [character, ..rest] -> take_string(rest, [character, ..taken])
    [] -> #(join_reversed(taken), [])
  }
}

/// Takes a comment up to the end of its line.
fn take_line(
  characters: List(String),
  taken: List(String),
) -> #(String, List(String)) {
  case characters {
    ["\n", ..] -> #(join_reversed(taken), characters)
    [character, ..rest] -> take_line(rest, [character, ..taken])
    [] -> #(join_reversed(taken), [])
  }
}

fn join_reversed(characters: List(String)) -> String {
  reverse(characters) |> concat
}
