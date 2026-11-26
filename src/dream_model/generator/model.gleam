//// Writes the Gleam module of one model folder from the descriptions of its
//// SQL files, and checks the record types across every model.
////
//// The text that `render` returns is valid Gleam. The command formats it
//// with `gleam format` before it writes it.

import dream_model/generator/gleam_type
import dream_model/generator/name
import dream_model/generator/query.{
  type Argument, type Field, type Problem, type Query, NoOutput, Problem,
  RecordOutput, ValueOutput,
}
import dream_model/generator/query_hint.{
  type TypeName, LocalType, ModuleType, ReturnsMany, ReturnsMaybe, ReturnsNone,
  ReturnsOne,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The SQL files of one model folder, described.
pub type Unit {
  Unit(
    model: query.Model,
    /// The folder of the SQL files, for example `src/app/models/user`.
    folder: String,
    /// Sorted by file name.
    queries: List(Query),
  )
}

/// A record type that a SQL file returns.
type Definition {
  Definition(
    module: String,
    name: String,
    file: String,
    line: Int,
    fields: List(Field),
  )
}

/// A record type that a generated module decodes.
type Record {
  Record(
    /// `None` for a type of the module itself, else the alias of the
    /// module of the type.
    alias: Option(String),
    name: String,
    fields: List(Field),
    /// The first file of the model that returns the type.
    file: String,
    /// The line of the returns hint of that file, or of its statement.
    line: Int,
  )
}

/// The names of the helpers that a generated module can hold.
pub const helper_names = [
  "one_row", "single_row", "maybe_row", "optional_row", "many_rows", "no_rows",
  "query_error_to_error", "unique_violation", "schema_fingerprint",
]

/// The aliases of the modules that a generated module can import, besides
/// the modules of other models.
pub const standard_aliases = [
  "client", "decode", "dream_errors", "option", "result",
]

/// The type and constructor names that a type of the module itself cannot
/// take: the types and constructors of the Gleam prelude, and the names
/// that the module imports without a module (`Option`, `Some`, `None`). A record type gives a constructor of its own name, so each
/// of them would shadow one that the module uses.
pub const reserved_type_names = [
  "BitArray", "Bool", "Error", "False", "Float", "Int", "List", "Nil", "None",
  "Ok", "Option", "Result", "Some", "String", "True", "UtfCodepoint",
]

// --- Types across the models -----------------------------------------------

/// Checks that every file that names one type gives it the same fields, in
/// the same order, with the same types, and that a type of another model
/// is a type that a SQL file of that model returns.
pub fn check_types(units: List(Unit)) -> List(Problem) {
  let definitions = list.flat_map(units, unit_definitions)
  let mismatches =
    list.group(definitions, fn(definition) {
      #(definition.module, definition.name)
    })
    |> dict.values
    |> list.flat_map(fn(group) { compare_group(list.reverse(group)) })
  let unknown =
    list.flat_map(units, fn(unit) { unknown_types(unit, units, definitions) })
  list.append(unknown, mismatches)
  |> list.sort(fn(first, second) {
    string.compare(
      query.problem_to_string(first),
      query.problem_to_string(second),
    )
  })
}

fn unit_definitions(unit: Unit) -> List(Definition) {
  list.filter_map(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name:, fields:, line:) -> {
        let #(module, type_base) = qualify(unit, type_name)
        Ok(Definition(
          module:,
          name: type_base,
          file: found.file,
          line:,
          fields:,
        ))
      }
      _ -> Error(Nil)
    }
  })
}

/// The module and the name of the record type of a query, or `Error(Nil)`
/// when the query returns no record.
fn query_type(unit: Unit, found: Query) -> Result(#(String, String), Nil) {
  case found.output {
    RecordOutput(type_name:, ..) -> Ok(qualify(unit, type_name))
    _ -> Error(Nil)
  }
}

/// The module and the name of a type. A type that names the model's own
/// module is a type of the model.
fn qualify(unit: Unit, type_name: TypeName) -> #(String, String) {
  case type_name {
    LocalType(type_base) -> #(unit.model.module, type_base)
    ModuleType(module:, name: type_base) -> #(module, type_base)
  }
}

fn compare_group(group: List(Definition)) -> List(Problem) {
  let first = list.first(group)
  list.drop(group, 1)
  |> list.filter_map(fn(other) {
    result.try(first, compare_definition(_, other))
  })
}

fn compare_definition(
  first: Definition,
  other: Definition,
) -> Result(Problem, Nil) {
  use difference <- result.map(first_difference(
    list.map(first.fields, field_signature),
    list.map(other.fields, field_signature),
    first.file,
  ))
  Problem(
    file: other.file,
    line: other.line,
    message: "the type "
      <> first.name
      <> " "
      <> difference
      <> "; every file that returns one type must give it the same fields, in the same order, with the same types",
  )
}

fn first_difference(
  expected: List(String),
  found: List(String),
  first_file: String,
) -> Result(String, Nil) {
  case expected, found {
    [], [] -> Error(Nil)
    [expected_field, ..], [] ->
      Ok(
        "has no field '"
        <> expected_field
        <> "' here, and "
        <> first_file
        <> " has it",
      )
    [], [found_field, ..] ->
      Ok(
        "has the field '"
        <> found_field
        <> "' here, and "
        <> first_file
        <> " does not",
      )
    [expected_field, ..expected_rest], [found_field, ..found_rest]
      if expected_field == found_field
    -> first_difference(expected_rest, found_rest, first_file)
    [expected_field, ..], [found_field, ..] ->
      Ok(
        "has the field '"
        <> found_field
        <> "' here, and '"
        <> expected_field
        <> "' in "
        <> first_file,
      )
  }
}

fn field_signature(field: Field) -> String {
  field.name <> ": " <> field_type_text(field)
}

fn unknown_types(
  unit: Unit,
  units: List(Unit),
  definitions: List(Definition),
) -> List(Problem) {
  list.filter_map(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name: ModuleType(module:, name: type_base), line:, ..)
        if module != unit.model.module
      ->
        check_module_type(units, definitions, module, type_base)
        |> result.map(Problem(file: found.file, line:, message: _))
      _ -> Error(Nil)
    }
  })
}

/// Returns the refusal of a type of another model, or `Error(Nil)` when a
/// SQL file of that model returns the type.
fn check_module_type(
  units: List(Unit),
  definitions: List(Definition),
  module: String,
  type_base: String,
) -> Result(String, Nil) {
  let owner = list.find(units, fn(unit) { unit.model.module == module })
  let defined =
    list.any(definitions, fn(definition) {
      definition.module == module
      && definition.name == type_base
      && result.map(owner, fn(unit) {
        string.starts_with(definition.file, unit.folder <> "/")
      })
      == Ok(True)
    })
  case owner, defined {
    Error(Nil), _ ->
      Ok(
        module
        <> " is not a model that dream_model generates in this run; the type "
        <> module
        <> "."
        <> type_base
        <> " must come from a model folder",
      )
    Ok(_), False ->
      Ok(
        "no .sql file of "
        <> module
        <> " returns the type "
        <> type_base
        <> "; name a type that a file of that model returns",
      )
    Ok(_), True -> Error(Nil)
  }
}

// --- The module ------------------------------------------------------------

/// Returns the text of the module of one model, with the fingerprint hash of
/// its tables. `check_types` must have accepted the units.
pub fn render(unit: Unit, hash: String) -> Result(String, List(Problem)) {
  let imports = model_imports(unit)
  let records = unit_records(unit, imports)
  let decoders = decoder_names(unit, records)
  use Nil <- result.map(check_names(unit, imports, records))
  let functions =
    list.map(unit.queries, render_function(unit, _, records, decoders))
  let used_helpers = list.map(unit.queries, helper_of) |> list.unique
  [
    header(unit),
    render_imports(unit, imports),
    render_fingerprint(unit, hash),
    ..list.flatten([
      list.filter_map(records, render_type(unit, _)),
      functions,
      render_decoders(unit, records, decoders),
      render_helpers(used_helpers),
    ])
  ]
  |> string.join("\n\n")
  |> string.append("\n")
}

fn header(unit: Unit) -> String {
  header_line(unit.folder)
}

/// Returns the first line of the module of a model folder, for example
/// `//// Generated by dream_model from src/app/models/user/*.sql. Do not
/// edit.` The command overwrites and removes only files that start with
/// it.
pub fn header_line(folder: String) -> String {
  "//// Generated by dream_model from " <> folder <> "/*.sql. Do not edit."
}

// --- Imports ---------------------------------------------------------------

/// The modules of other models that the module imports, with their alias.
fn model_imports(unit: Unit) -> List(#(String, String)) {
  list.filter_map(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name: ModuleType(module:, ..), ..)
        if module != unit.model.module
      -> Ok(#(module, module_alias(module)))
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.sort(fn(first, second) { string.compare(first.0, second.0) })
}

fn module_alias(module: String) -> String {
  string.split(module, "/") |> list.last |> result.unwrap(module)
}

fn render_imports(unit: Unit, imports: List(#(String, String))) -> String {
  let has_output =
    list.any(unit.queries, fn(found) { found.output != NoOutput })
  let has_option =
    list.any(unit.queries, fn(found) {
      list.any(output_fields(found), fn(field) { field.optional })
      || list.any(found.arguments, fn(argument) { argument.optional })
    })
  let has_maybe =
    list.any(unit.queries, fn(found) { found.returns == ReturnsMaybe })
  let option_import = case has_maybe, has_option {
    True, _ -> Some("import gleam/option.{type Option, None, Some}")
    False, True -> Some("import gleam/option.{type Option}")
    False, False -> None
  }
  let result_import = case
    list.any(unit.queries, fn(found) {
      found.returns == ReturnsMany || found.returns == ReturnsNone
    })
  {
    True -> Some("import gleam/result")
    False -> None
  }
  let decode_import = case has_output {
    True -> Some("import gleam/dynamic/decode")
    False -> None
  }
  list.map(imports, fn(entry) { "import " <> entry.0 })
  |> list.append(["import dream_errors", "import dream_postgres/client"])
  |> list.append(option.values([decode_import]))
  |> list.append(option.values([option_import, result_import]))
  |> list.sort(string.compare)
  |> string.join("\n")
}

fn output_fields(found: Query) -> List(Field) {
  case found.output {
    NoOutput -> []
    ValueOutput(field) -> [field]
    RecordOutput(fields:, ..) -> fields
  }
}

// --- Names -----------------------------------------------------------------

/// Refuses a function name that a helper, a decoder or an import uses, two
/// imported models with the same alias, a type name that the prelude or
/// an import uses, and two record types with the same decoder name. The
/// query refuses a parameter name that the body of a function uses.
fn check_names(
  unit: Unit,
  imports: List(#(String, String)),
  records: List(Record),
) -> Result(Nil, List(Problem)) {
  let aliases = list.map(imports, fn(entry) { entry.1 })
  let taken =
    list.flatten([
      helper_names,
      standard_aliases,
      aliases,
      list.map(records, record_decoder_name),
    ])
  let function_problems =
    list.filter_map(unit.queries, fn(found) {
      case list.contains(taken, found.function) {
        True ->
          Ok(Problem(
            file: found.file,
            line: 1,
            message: "the function name '"
              <> found.function
              <> "' is a name that the generated module uses itself; rename the file",
          ))
        False -> Error(Nil)
      }
    })
  let alias_problems =
    list.filter_map(imports, fn(entry) {
      let clashes =
        list.count(aliases, fn(alias) { alias == entry.1 }) > 1
        || list.contains(standard_aliases, entry.1)
      case clashes {
        True ->
          Ok(Problem(
            file: first_file_of_module(unit, entry.0),
            line: 1,
            message: "the module "
              <> entry.0
              <> " would be imported as '"
              <> entry.1
              <> "', which another import of this model uses; name the type of another model whose module ends in another name",
          ))
        False -> Error(Nil)
      }
    })
  let field_problems =
    list.filter_map(unit.queries, fn(found) {
      let clashing =
        output_fields(found)
        |> list.find(fn(field) { list.contains(aliases, field.name) })
      case found.output, clashing {
        RecordOutput(type_name: ModuleType(module:, ..), line:, ..), Ok(field)
          if module != unit.model.module
        ->
          Ok(Problem(
            file: found.file,
            line:,
            message: "the field '"
              <> field.name
              <> "' has the name of the imported module "
              <> module
              <> ", which its decoder uses; rename the column with AS in the SQL",
          ))
        _, _ -> Error(Nil)
      }
    })
  let type_problems =
    list.filter_map(records, fn(record) {
      case record.alias, list.contains(reserved_type_names, record.name) {
        None, True ->
          Ok(Problem(
            file: record.file,
            line: record.line,
            message: "the type name '"
              <> record.name
              <> "' is a type or a constructor of the Gleam prelude or of an import of the generated module; write another type name in the 'returns' hint, for example 'returns: one "
              <> record.name
              <> "Row', or rename the model folder",
          ))
        _, _ -> Error(Nil)
      }
    })
  let decoder_problems =
    list.index_map(records, fn(record, index) {
      let decoder = record_decoder_name(record)
      list.take(records, index)
      |> list.find(fn(earlier) { record_decoder_name(earlier) == decoder })
      |> result.map(fn(earlier) {
        Problem(
          file: record.file,
          line: record.line,
          message: "the types "
            <> record_type_text(earlier)
            <> " and "
            <> record_type_text(record)
            <> " would both get the decoder "
            <> decoder
            <> "; rename one of the types",
        )
      })
    })
    |> result.values
  case
    list.flatten([
      function_problems,
      alias_problems,
      field_problems,
      type_problems,
      decoder_problems,
    ])
  {
    [] -> Ok(Nil)
    problems -> Error(problems)
  }
}

fn first_file_of_module(unit: Unit, module: String) -> String {
  list.find(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name: ModuleType(module: found_module, ..), ..) ->
        found_module == module
      _ -> False
    }
  })
  |> result.map(fn(found) { found.file })
  |> result.unwrap(unit.folder)
}

// --- Records ---------------------------------------------------------------

/// The record types that the module decodes, in the order of the files.
fn unit_records(unit: Unit, imports: List(#(String, String))) -> List(Record) {
  list.filter_map(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name:, fields:, line:) -> {
        let #(module, type_base) = qualify(unit, type_name)
        Ok(Record(
          alias: record_alias(unit, imports, module),
          name: type_base,
          fields:,
          file: found.file,
          line:,
        ))
      }
      _ -> Error(Nil)
    }
  })
  |> list.fold([], fn(kept: List(Record), record) {
    case
      list.any(kept, fn(earlier) {
        earlier.alias == record.alias && earlier.name == record.name
      })
    {
      True -> kept
      False -> list.append(kept, [record])
    }
  })
}

fn record_alias(
  unit: Unit,
  imports: List(#(String, String)),
  module: String,
) -> Option(String) {
  case module == unit.model.module {
    True -> None
    False -> list.key_find(imports, module) |> option.from_result
  }
}

fn record_type_text(record: Record) -> String {
  case record.alias {
    Some(alias) -> alias <> "." <> record.name
    None -> record.name
  }
}

fn record_decoder_name(record: Record) -> String {
  let type_part = name.to_value_name(record.name) |> result.unwrap("record")
  case record.alias {
    Some(alias) -> alias <> "_" <> type_part <> "_decoder"
    None -> type_part <> "_decoder"
  }
}

fn find_record(
  records: List(Record),
  unit: Unit,
  type_name: TypeName,
) -> Record {
  let #(module, type_base) = qualify(unit, type_name)
  let is_local = module == unit.model.module
  list.find(records, fn(record) {
    record.name == type_base && { record.alias == None } == is_local
  })
  |> result.unwrap(Record(
    alias: None,
    name: type_base,
    fields: [],
    file: "",
    line: 1,
  ))
}

fn render_type(unit: Unit, record: Record) -> Result(String, Nil) {
  let files =
    list.filter(unit.queries, fn(found) {
      query_type(unit, found) == Ok(#(unit.model.module, record.name))
    })
    |> list.map(fn(found) { file_name(found.file) })
  case record.alias {
    Some(_) -> Error(Nil)
    None ->
      Ok(
        "/// A row of "
        <> join_words(files)
        <> ".\npub type "
        <> record.name
        <> " {\n  "
        <> record.name
        <> "("
        <> list.map(record.fields, field_signature) |> string.join(", ")
        <> ")\n}",
      )
  }
}

// --- Decoders --------------------------------------------------------------

/// The name of the decoder of each query with a record output: the decoder
/// of its type, or a decoder of its own when its columns decode in another
/// way (a `-- not null:` promise).
fn decoder_names(unit: Unit, records: List(Record)) -> List(#(String, String)) {
  list.filter_map(unit.queries, fn(found) {
    case found.output {
      RecordOutput(type_name:, fields:, ..) ->
        Ok(#(
          found.function,
          choose_decoder(found, find_record(records, unit, type_name), fields),
        ))
      _ -> Error(Nil)
    }
  })
}

fn choose_decoder(found: Query, record: Record, fields: List(Field)) -> String {
  let own = decoder_body(record, fields, found.file)
  case own == decoder_body(record, record.fields, record.file) {
    True -> record_decoder_name(record)
    False -> found.function <> "_decoder"
  }
}

fn render_decoders(
  unit: Unit,
  records: List(Record),
  decoders: List(#(String, String)),
) -> List(String) {
  let used = list.map(decoders, fn(entry) { entry.1 })
  let shared =
    list.filter(records, fn(record) {
      list.contains(used, record_decoder_name(record))
    })
    |> list.map(fn(record) {
      render_decoder(
        record_decoder_name(record),
        record,
        record.fields,
        record.file,
      )
    })
  let own =
    list.filter_map(unit.queries, fn(found) {
      let decoder = list.key_find(decoders, found.function)
      case found.output, decoder {
        RecordOutput(type_name:, fields:, ..), Ok(decoder)
          if decoder == found.function <> "_decoder"
        ->
          Ok(render_decoder(
            decoder,
            find_record(records, unit, type_name),
            fields,
            found.file,
          ))
        _, _ -> Error(Nil)
      }
    })
  list.append(shared, own)
}

fn render_decoder(
  decoder: String,
  record: Record,
  fields: List(Field),
  file: String,
) -> String {
  "fn "
  <> decoder
  <> "() -> decode.Decoder("
  <> record_type_text(record)
  <> ") {\n"
  <> decoder_body(record, fields, file)
  <> "\n}"
}

fn decoder_body(record: Record, fields: List(Field), file: String) -> String {
  let uses =
    list.index_map(fields, fn(field, index) {
      "  use "
      <> field.name
      <> " <- decode.field("
      <> int_text(index)
      <> ", "
      <> field_decoder(field, file)
      <> ")"
    })
  let labels = list.map(fields, fn(field) { field.name <> ":" })
  list.append(uses, [
    "  decode.success("
    <> record_type_text(record)
    <> "("
    <> string.join(labels, ", ")
    <> "))",
  ])
  |> string.join("\n")
}

fn field_decoder(field: Field, file: String) -> String {
  let column_literal = string_literal(field.column)
  let decoder = case field.elements_promised, field.gleam_type {
    True, gleam_type.ListType(element) ->
      "client.promised_elements_not_null("
      <> gleam_type.decoder_text(element, column_literal)
      <> ", "
      <> string_literal(file)
      <> ", "
      <> column_literal
      <> ")"
    _, other -> gleam_type.decoder_text(other, column_literal)
  }
  case field.optional, field.promised {
    True, _ -> "decode.optional(" <> decoder <> ")"
    False, True ->
      "client.promised_not_null("
      <> decoder
      <> ", "
      <> string_literal(file)
      <> ", "
      <> string_literal(field.column)
      <> ")"
    False, False -> decoder
  }
}

// --- Functions -------------------------------------------------------------

fn render_function(
  unit: Unit,
  found: Query,
  records: List(Record),
  decoders: List(#(String, String)),
) -> String {
  let arguments =
    [
      "db: client.Connection",
      ..list.map(found.arguments, fn(argument) {
        argument.name <> ": " <> argument_type_text(argument)
      })
    ]
    |> string.join(", ")
  let parameters =
    list.map(found.arguments, fn(argument) {
      "  |> client.parameter("
      <> gleam_type.encode_call(
        argument.gleam_type,
        argument.name,
        argument.optional,
      )
      <> ")"
    })
  let numeric = case
    list.any(output_fields(found), fn(field) {
      gleam_type.has_numeric(field.gleam_type)
    })
  {
    True -> ["  |> client.numeric_as_text"]
    False -> []
  }
  let returning = case found.output {
    NoOutput -> []
    ValueOutput(field) -> [
      "  |> client.returning(decode.at([0], "
      <> field_decoder(field, found.file)
      <> "))",
    ]
    RecordOutput(..) -> [
      "  |> client.returning("
      <> { list.key_find(decoders, found.function) |> result.unwrap("") }
      <> "())",
    ]
  }
  let lines =
    list.flatten([
      [
        "/// Generated from " <> file_name(found.file) <> ".",
        "pub fn "
          <> found.function
          <> "("
          <> arguments
          <> ") -> Result("
          <> return_type_text(unit, found, records)
          <> ", dream_errors.Error(client.QueryError)) {",
        "  " <> string_literal(found.sql),
        "  |> client.query",
      ],
      parameters,
      numeric,
      returning,
      ["  |> client.execute(db)", "  |> " <> helper_call(unit, found), "}"],
    ])
  string.join(lines, "\n")
}

fn file_name(file: String) -> String {
  string.split(file, "/") |> list.last |> result.unwrap(file)
}

fn argument_type_text(argument: Argument) -> String {
  optional_text(gleam_type.type_text(argument.gleam_type), argument.optional)
}

fn field_type_text(field: Field) -> String {
  let text = case field.elements_promised, field.gleam_type {
    True, gleam_type.ListType(element) -> gleam_type.promised_list_text(element)
    _, other -> gleam_type.type_text(other)
  }
  optional_text(text, field.optional)
}

fn optional_text(text: String, optional: Bool) -> String {
  case optional {
    True -> "Option(" <> text <> ")"
    False -> text
  }
}

fn return_type_text(unit: Unit, found: Query, records: List(Record)) -> String {
  let row = case found.output {
    NoOutput -> "Nil"
    ValueOutput(field) -> field_type_text(field)
    RecordOutput(type_name:, ..) ->
      record_type_text(find_record(records, unit, type_name))
  }
  case found.returns {
    ReturnsOne | ReturnsNone -> row
    ReturnsMaybe -> "Option(" <> row <> ")"
    ReturnsMany -> "List(" <> row <> ")"
  }
}

fn helper_of(found: Query) -> String {
  case found.returns {
    ReturnsOne -> "one_row"
    ReturnsMaybe -> "maybe_row"
    ReturnsMany -> "many_rows"
    ReturnsNone -> "no_rows"
  }
}

fn helper_call(unit: Unit, found: Query) -> String {
  let query_name =
    string_literal(module_alias(unit.model.module) <> "." <> found.function)
  let unique_list =
    "[" <> string.join(list.map(found.unique, string_literal), ", ") <> "]"
  helper_of(found) <> "(" <> query_name <> ", " <> unique_list <> ")"
}

// --- The fingerprint -------------------------------------------------------

fn render_fingerprint(unit: Unit, hash: String) -> String {
  let tables =
    list.flat_map(unit.queries, fn(found) { found.relations })
    |> list.unique
    |> list.sort(string.compare)
    |> list.map(string_literal)
  "/// The tables that the functions of this module read and write, and the
/// fingerprint of their schema when dream_model generated the module. Give
/// it to `client.check_schema` when the application starts, to stop with a
/// clear message when the schema changed after the generation.
pub const schema_fingerprint = client.SchemaFingerprint(
  module: " <> string_literal(unit.model.module) <> ",
  tables: [" <> string.join(tables, ", ") <> "],
  hash: " <> string_literal(hash) <> ",
)"
}

// --- Helpers ---------------------------------------------------------------

fn render_helpers(used: List(String)) -> List(String) {
  let helpers = [
    #("one_row", [one_row_helper, single_row_helper]),
    #("maybe_row", [maybe_row_helper, optional_row_helper]),
    #("many_rows", [many_rows_helper]),
    #("no_rows", [no_rows_helper]),
  ]
  list.filter(helpers, fn(entry) { list.contains(used, entry.0) })
  |> list.flat_map(fn(entry) { entry.1 })
  |> list.append([query_error_helper])
}

const one_row_helper =
  "fn one_row(
  executed: Result(client.Returned(row), client.QueryError),
  query_name: String,
  unique: List(String),
) -> Result(row, dream_errors.Error(client.QueryError)) {
  case executed {
    Ok(returned) -> single_row(returned, query_name)
    Error(query_error) ->
      Error(query_error_to_error(query_error, query_name, unique))
  }
}"

const single_row_helper =
  "fn single_row(
  returned: client.Returned(row),
  query_name: String,
) -> Result(row, dream_errors.Error(client.QueryError)) {
  case returned.rows {
    [row] -> Ok(row)
    [] -> Error(dream_errors.NotFound(query_name <> \" found no row\"))
    _ ->
      Error(dream_errors.Failed(
        query_name <> \" returned more than one row\",
        client.more_than_one_row(returned.count),
      ))
  }
}"

const maybe_row_helper =
  "fn maybe_row(
  executed: Result(client.Returned(row), client.QueryError),
  query_name: String,
  unique: List(String),
) -> Result(Option(row), dream_errors.Error(client.QueryError)) {
  case executed {
    Ok(returned) -> optional_row(returned, query_name)
    Error(query_error) ->
      Error(query_error_to_error(query_error, query_name, unique))
  }
}"

const optional_row_helper =
  "fn optional_row(
  returned: client.Returned(row),
  query_name: String,
) -> Result(Option(row), dream_errors.Error(client.QueryError)) {
  case returned.rows {
    [] -> Ok(None)
    [row] -> Ok(Some(row))
    _ ->
      Error(dream_errors.Failed(
        query_name <> \" returned more than one row\",
        client.more_than_one_row(returned.count),
      ))
  }
}"

const many_rows_helper =
  "fn many_rows(
  executed: Result(client.Returned(row), client.QueryError),
  query_name: String,
  unique: List(String),
) -> Result(List(row), dream_errors.Error(client.QueryError)) {
  executed
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(query_error_to_error(_, query_name, unique))
}"

const no_rows_helper =
  "fn no_rows(
  executed: Result(client.Returned(row), client.QueryError),
  query_name: String,
  unique: List(String),
) -> Result(Nil, dream_errors.Error(client.QueryError)) {
  executed
  |> result.replace(Nil)
  |> result.map_error(query_error_to_error(_, query_name, unique))
}"

const query_error_helper =
  "fn query_error_to_error(
  query_error: client.QueryError,
  query_name: String,
  unique: List(String),
) -> dream_errors.Error(client.QueryError) {
  let conflict =
    unique_violation(client.violated_constraint(query_error), unique)
  let promise = client.broken_promise(query_error)
  let infinite = client.infinite_value(query_error)
  let shared = client.to_error(query_error)
  let described = query_name <> \": \" <> dream_errors.message(shared)
  case conflict, promise, infinite, shared {
    Ok(_), _, _, _ -> dream_errors.Conflict(described, query_error)
    Error(Nil), Ok(message), _, _ -> dream_errors.Failed(message, query_error)
    Error(Nil), Error(Nil), Ok(message), _ ->
      dream_errors.Failed(query_name <> \": \" <> message, query_error)
    Error(Nil), Error(Nil), Error(Nil), dream_errors.Timeout(..) ->
      dream_errors.Timeout(described, query_error)
    Error(Nil), Error(Nil), Error(Nil), dream_errors.Unavailable(..) ->
      dream_errors.Unavailable(described, query_error)
    Error(Nil), Error(Nil), Error(Nil), _ ->
      dream_errors.Failed(described, query_error)
  }
}

fn unique_violation(
  constraint: Result(String, Nil),
  unique: List(String),
) -> Result(String, Nil) {
  case constraint, unique {
    Ok(violated), [name, ..] if name == violated -> Ok(violated)
    Ok(_), [_, ..rest] -> unique_violation(constraint, rest)
    _, _ -> Error(Nil)
  }
}"

// --- Text ------------------------------------------------------------------

/// Returns a Gleam string literal of the text.
pub fn string_literal(text: String) -> String {
  let escaped =
    text
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
  "\"" <> escaped <> "\""
}

/// Joins words as a sentence does: `a`, `a and b`, `a, b and c`.
fn join_words(words: List(String)) -> String {
  let last = list.length(words) - 1
  list.index_map(words, fn(word, index) {
    case index {
      0 -> word
      _ if index == last -> " and " <> word
      _ -> ", " <> word
    }
  })
  |> string.concat
}

fn int_text(value: Int) -> String {
  int.to_string(value)
}
