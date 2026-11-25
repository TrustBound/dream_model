//// Turns one model `.sql` file into the description of its generated
//// function: the Gleam types of its result columns and parameters, what it
//// returns, its argument names and the errors it maps.
////
//// Every refusal is a `Problem` that names the file and the line.

import dream_model/generator/fingerprint
import dream_model/generator/gleam_type.{type GleamType, type Types}
import dream_model/generator/name
import dream_model/generator/query_hint.{
  type QueryHints, type Returns, type TypeName, LocalType, ReturnsHint,
  ReturnsMany, ReturnsNone,
}
import dream_model/nullability.{
  type Analysis, type AnalysisError, type Analyzer, type Column, type Parameter,
}
import dream_model/nullability/hint as null_hint
import dream_model/nullability/reason
import dream_model/postgres/tree
import dream_model/postgres/wire
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A refusal, at a line of a file.
pub type Problem {
  Problem(file: String, line: Int, message: String)
}

/// A result column of the generated code.
pub type Field {
  Field(
    /// The Gleam name, for example `created_at`.
    name: String,
    /// The name of the column in the result.
    column: String,
    gleam_type: GleamType,
    /// True when the column can be NULL: the field is `Option`.
    optional: Bool,
    /// True when a `-- not null:` hint promised the column is never NULL:
    /// the decoder checks it on each row.
    promised: Bool,
    /// True when a `-- not null elements:` hint promised the elements of
    /// this array column are never NULL: the field is `List(T)`, and the
    /// decoder checks each element on each row.
    elements_promised: Bool,
  )
}

/// A parameter of the generated function.
pub type Argument {
  Argument(name: String, gleam_type: GleamType, optional: Bool)
}

/// What one row gives.
pub type Output {
  /// The statement returns no columns (`returns: none`).
  NoOutput
  /// The value of the only result column.
  ValueOutput(field: Field)
  /// A record of the result columns. `line` is the line of the returns
  /// hint, or of the statement when there is no hint.
  RecordOutput(type_name: TypeName, fields: List(Field), line: Int)
}

/// The generated function of one SQL file.
pub type Query {
  Query(
    /// The path of the SQL file, for example `src/app/models/user/find.sql`.
    file: String,
    function: String,
    /// The SQL that the function runs: the file without the comment lines
    /// at its top.
    sql: String,
    returns: Returns,
    output: Output,
    arguments: List(Argument),
    /// The names of the unique constraints and indexes whose violation
    /// gives `client.Conflict`.
    unique: List(String),
    /// The relations whose catalog facts the analysis read.
    relations: List(String),
  )
}

/// The model that a SQL file belongs to.
pub type Model {
  Model(
    /// The module path, for example `app/models/user`.
    module: String,
    /// The type name of a record with no type name in its hint, for example
    /// `User`.
    type_name: String,
  )
}

/// Names that a parameter cannot take, because the body of the generated
/// function uses them: the connection, the modules and the helpers. A name
/// that ends in `_decoder` is refused too, as the decoders of the module
/// have such names.
pub const reserved_argument_names = [
  "db", "client", "decode", "one_row", "single_row", "maybe_row", "optional_row",
  "many_rows", "no_rows", "query_error_to_error", "unique_violation",
  "schema_fingerprint",
]

/// The end of the name of each decoder of a generated module.
const decoder_suffix = "_decoder"

fn is_reserved_argument_name(argument_name: String) -> Bool {
  list.contains(reserved_argument_names, argument_name)
  || string.ends_with(argument_name, decoder_suffix)
}

/// Names that a record field cannot take, because the generated decoder
/// uses them itself.
pub const reserved_field_names = ["client", "decode"]

const unique_sql =
  "with recursive named as (
  select i.indexrelid as oid
  from pg_catalog.pg_index i
  join pg_catalog.pg_class c on c.oid = i.indexrelid
  where i.indisunique and c.relname = $2
    and i.indrelid = any($1::pg_catalog.text[]::pg_catalog.regclass[])
), family(oid) as (
  select oid from named
  union
  select h.inhrelid from pg_catalog.pg_inherits h
  join family f on h.inhparent = f.oid
)
select c.relname from family f
join pg_catalog.pg_class c on c.oid = f.oid
order by c.relname"

/// The objects that have the name of a unique hint: `hinted` rows describe
/// the unique indexes of the written tables with that name, `other` rows
/// every other index or constraint with that name in any schema. A
/// constraint that a hinted index (or an index of a partition or child
/// table of it) backs is not an other object.
const same_name_sql =
  "with recursive named as (
  select i.indexrelid as oid
  from pg_catalog.pg_index i
  join pg_catalog.pg_class c on c.oid = i.indexrelid
  where i.indisunique and c.relname = $2
    and i.indrelid = any($1::pg_catalog.text[]::pg_catalog.regclass[])
), family(oid) as (
  select oid from named
  union
  select h.inhrelid from pg_catalog.pg_inherits h
  join family f on h.inhparent = f.oid
), indexes as (
  select c.oid, c.relname,
    'the unique index ' || pg_catalog.quote_ident(n.nspname) || '.'
      || pg_catalog.quote_ident(c.relname) || ' on '
      || pg_catalog.quote_ident(tn.nspname) || '.'
      || pg_catalog.quote_ident(t.relname) as description
  from pg_catalog.pg_index i
  join pg_catalog.pg_class c on c.oid = i.indexrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_class t on t.oid = i.indrelid
  join pg_catalog.pg_namespace tn on tn.oid = t.relnamespace
  where c.relname = $2
)
select 'hinted', description from indexes
where oid in (select oid from named)
union all
select 'other', pg_catalog.replace(description, 'the unique index', 'the index')
from indexes
where oid not in (select oid from family)
  and not exists (
    select from pg_catalog.pg_constraint k
    where k.conindid = indexes.oid and k.conname = indexes.relname
      and k.contype in ('p', 'u', 'x')
  )
union all
select 'other',
  case k.contype
    when 'c' then 'the check constraint '
    when 'f' then 'the foreign key '
    when 'p' then 'the primary key '
    when 'u' then 'the unique constraint '
    when 'x' then 'the exclusion constraint '
    when 'n' then 'the not-null constraint '
    when 't' then 'the constraint trigger '
    else 'the constraint '
  end
  || pg_catalog.quote_ident(k.conname) || ' on '
  || case when k.conrelid <> 0
    then pg_catalog.quote_ident(tn.nspname) || '.'
      || pg_catalog.quote_ident(t.relname)
    else 'the domain ' || pg_catalog.quote_ident(yn.nspname) || '.'
      || pg_catalog.quote_ident(y.typname)
  end
from pg_catalog.pg_constraint k
left join pg_catalog.pg_class t on t.oid = k.conrelid
left join pg_catalog.pg_namespace tn on tn.oid = t.relnamespace
left join pg_catalog.pg_type y on y.oid = k.contypid
left join pg_catalog.pg_namespace yn on yn.oid = y.typnamespace
where k.conname = $2
  and not (k.contype in ('p', 'u') and k.conindid in (select oid from family))
order by 1, 2"

/// Returns the text of a problem: `file:line: message`.
pub fn problem_to_string(problem: Problem) -> String {
  problem.file <> ":" <> int.to_string(problem.line) <> ": " <> problem.message
}

/// Describes the generated function of one SQL file. Returns the analyzer
/// to use next, also after a refusal.
pub fn analyze(
  analyzer: Analyzer,
  model: Model,
  file: String,
  sql: String,
) -> #(Result(Query, List(Problem)), Analyzer) {
  let problem = fn(line, message) { [Problem(file:, line:, message:)] }
  let statement = strip_leading_comments(sql)
  let statement_line = statement.0
  let hinted =
    query_hint.parse(sql)
    |> result.map_error(
      list.map(_, fn(error: query_hint.HintError) {
        Problem(file:, line: error.line, message: error.message)
      }),
    )
  let function =
    function_name(file)
    |> result.replace_error(problem(
      1,
      "the file name does not give a Gleam function name; name the file in snake case, for example find_by_email.sql",
    ))
  case hinted, function {
    Ok(hints), Ok(function) ->
      analyze_statement(
        analyzer,
        Context(model:, file:, sql:, statement_line:, hints:),
        function,
        statement.1,
      )
    _, _ -> #(
      Error(list.append(error_list(hinted), error_list(function))),
      analyzer,
    )
  }
}

fn error_list(found: Result(a, List(Problem))) -> List(Problem) {
  case found {
    Ok(_) -> []
    Error(problems) -> problems
  }
}

type Context {
  Context(
    model: Model,
    file: String,
    sql: String,
    statement_line: Int,
    hints: QueryHints,
  )
}

fn analyze_statement(
  analyzer: Analyzer,
  context: Context,
  function: String,
  statement: String,
) -> #(Result(Query, List(Problem)), Analyzer) {
  case nullability.analyze(analyzer, context.sql) {
    Error(error) -> #(Error(analysis_problems(context, error)), analyzer)
    Ok(#(analysis, analyzer)) -> #(
      describe(analyzer, context, function, statement, analysis),
      analyzer,
    )
  }
}

fn describe(
  analyzer: Analyzer,
  context: Context,
  function: String,
  statement: String,
  analysis: Analysis,
) -> Result(Query, List(Problem)) {
  let oids =
    list.append(
      list.map(analysis.columns, fn(column) { column.type_oid }),
      list.map(analysis.parameters, fn(parameter) { parameter.type_oid }),
    )
  use types <- result.try(
    gleam_type.load(analyzer, oids)
    |> result.map_error(fn(error) { [database_problem(context, error)] }),
  )
  let columns =
    resolve_columns(context, types, analysis.columns)
    |> result.try(promise_elements(analyzer, context, analysis.relations, _))
  let arguments = resolve_arguments(context, types, analysis.parameters)
  let unique = resolve_unique(analyzer, context, analysis.written_relations)
  use #(columns, arguments, unique) <- result.try(collect_three(
    columns,
    arguments,
    unique,
  ))
  use #(returns, output) <- result.map(decide_output(context, columns))
  Query(
    file: context.file,
    function:,
    sql: statement,
    returns:,
    output:,
    arguments:,
    unique:,
    relations: analysis.relations,
  )
}

fn collect_three(
  first: Result(a, List(Problem)),
  second: Result(b, List(Problem)),
  third: Result(c, List(Problem)),
) -> Result(#(a, b, c), List(Problem)) {
  case first, second, third {
    Ok(first), Ok(second), Ok(third) -> Ok(#(first, second, third))
    _, _, _ ->
      Error(
        list.flatten([error_list(first), error_list(second), error_list(third)]),
      )
  }
}

// --- Problems of the analysis ----------------------------------------------

fn analysis_problems(context: Context, error: AnalysisError) -> List(Problem) {
  case error {
    nullability.TreeFailed(tree.QueryFailed(wire.ServerError(fields))) -> [
      Problem(
        file: context.file,
        line: server_error_line(context, fields),
        message: "PostgreSQL refused the statement: "
          <> wire.get_field(fields, "M") |> result.unwrap(""),
      ),
    ]
    nullability.HintsRefused(errors) ->
      list.map(errors, fn(hint_error) {
        Problem(
          file: context.file,
          line: hint_error_line(context, hint_error),
          message: nullability.hint_error_to_string(hint_error),
        )
      })
    _ -> [database_problem(context, error)]
  }
}

fn database_problem(context: Context, error: AnalysisError) -> Problem {
  Problem(
    file: context.file,
    line: context.statement_line,
    message: nullability.error_to_string(error),
  )
}

/// The line of the character position `P` (from 1) of an ErrorResponse.
fn server_error_line(context: Context, fields: List(#(String, String))) -> Int {
  wire.get_field(fields, "P")
  |> result.try(int.parse)
  |> result.map(fn(position) {
    string.slice(context.sql, 0, position - 1)
    |> string.split("\n")
    |> list.length
  })
  |> result.unwrap(context.statement_line)
}

fn hint_error_line(context: Context, error: nullability.HintError) -> Int {
  list.find(context.hints.column_names, fn(named) { named.name == error.name })
  |> result.map(fn(named) { named.line })
  |> result.unwrap(context.statement_line)
}

// --- Columns ---------------------------------------------------------------

/// A column with its Gleam type, before its name is checked.
type TypedColumn {
  TypedColumn(column: Column, gleam_type: GleamType, elements_promised: Bool)
}

fn resolve_columns(
  context: Context,
  types: Types,
  columns: List(Column),
) -> Result(List(TypedColumn), List(Problem)) {
  list.map(columns, fn(column) {
    gleam_type.resolve(types, column.type_oid)
    |> result.map(TypedColumn(column, _, False))
    |> result.map_error(fn(type_name) {
      Problem(
        file: context.file,
        line: context.statement_line,
        message: "the column '"
          <> column.name
          <> "' has the PostgreSQL type "
          <> type_name
          <> ", which dream_model does not support; cast it in the SQL to a supported type, for example "
          <> column.name
          <> "::text",
      )
    })
  })
  |> collect_all
}

fn collect_all(
  found: List(Result(a, Problem)),
) -> Result(List(a), List(Problem)) {
  case result.partition(found) {
    #(values, []) -> Ok(list.reverse(values))
    #(_, problems) -> Error(list.reverse(problems))
  }
}

fn decide_output(
  context: Context,
  columns: List(TypedColumn),
) -> Result(#(Returns, Output), List(Problem)) {
  let problem = fn(line, message) {
    Error([Problem(file: context.file, line:, message:)])
  }
  let local = LocalType(context.model.type_name)
  case context.hints.returns, columns {
    None, [] -> Ok(#(ReturnsNone, NoOutput))
    None, _ ->
      record_output(
        context,
        ReturnsMany,
        local,
        columns,
        context.statement_line,
      )
    Some(ReturnsHint(ReturnsNone, _, _)), [] -> Ok(#(ReturnsNone, NoOutput))
    Some(ReturnsHint(ReturnsNone, _, line)), _ ->
      problem(
        line,
        "'returns: none', and the statement returns the columns "
          <> column_list(columns)
          <> "; remove the columns or write another returns form",
      )
    Some(ReturnsHint(returns, _, line)), [] ->
      problem(
        line,
        "'returns: "
          <> query_hint.returns_to_string(returns)
          <> "' needs result columns, and the statement returns none; write 'returns: none'",
      )
    Some(ReturnsHint(returns, None, _)), [single] ->
      Ok(#(returns, ValueOutput(make_field(single, single.column.name))))
    Some(ReturnsHint(returns, None, line)), _ ->
      record_output(context, returns, local, columns, line)
    Some(ReturnsHint(returns, Some(type_name), line)), _ ->
      record_output(context, returns, type_name, columns, line)
  }
}

fn column_list(columns: List(TypedColumn)) -> String {
  list.map(columns, fn(typed) { typed.column.name })
  |> string.join(", ")
}

fn record_output(
  context: Context,
  returns: Returns,
  type_name: TypeName,
  columns: List(TypedColumn),
  line: Int,
) -> Result(#(Returns, Output), List(Problem)) {
  use fields <- result.try(
    list.index_map(columns, fn(typed, index) {
      name_field(context, typed, index + 1, line)
    })
    |> collect_all,
  )
  use Nil <- result.map(check_duplicate_fields(context, fields, line))
  #(returns, RecordOutput(type_name:, fields:, line:))
}

fn name_field(
  context: Context,
  typed: TypedColumn,
  position: Int,
  line: Int,
) -> Result(Field, Problem) {
  let problem = fn(message) { Problem(file: context.file, line:, message:) }
  let column = typed.column.name
  use field_name <- result.try(
    name.to_value_name(column)
    |> result.replace_error(problem(
      "result column "
      <> int.to_string(position)
      <> " ('"
      <> column
      <> "') has no Gleam name; name it with AS in the SQL, for example AS total",
    )),
  )
  case list.contains(reserved_field_names, field_name) {
    True ->
      Error(problem(
        "the result column '"
        <> column
        <> "' gives the field name '"
        <> field_name
        <> "', which the generated decoder uses itself; rename it with AS in the SQL",
      ))
    False -> Ok(make_field(typed, field_name))
  }
}

fn make_field(typed: TypedColumn, field_name: String) -> Field {
  Field(
    name: field_name,
    column: typed.column.name,
    gleam_type: typed.gleam_type,
    optional: !typed.column.not_null,
    promised: typed.column.reason == reason.NotNullHint,
    elements_promised: typed.elements_promised,
  )
}

// --- The `-- not null elements:` hint ---------------------------------------

/// The table columns with a name, of the relations that a query reads.
const relation_column_sql =
  "select pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(c.relname)
  || '.' || pg_catalog.quote_ident(a.attname)
from pg_catalog.pg_attribute a
join pg_catalog.pg_class c on c.oid = a.attrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where a.attrelid = any($1::pg_catalog.text[]::pg_catalog.regclass[])
  and a.attname = $2 and a.attnum > 0 and not a.attisdropped
order by 1"

/// Marks the array columns that a `-- not null elements:` hint names.
/// Refuses a name that is not a result column, or a column that is not an
/// array.
fn promise_elements(
  analyzer: Analyzer,
  context: Context,
  relations: List(String),
  columns: List(TypedColumn),
) -> Result(List(TypedColumn), List(Problem)) {
  let named = context.hints.element_names
  use Nil <- result.map(
    list.map(named, check_element_name(analyzer, context, relations, columns, _))
    |> collect_all
    |> result.replace(Nil),
  )
  list.map(columns, fn(typed) {
    TypedColumn(
      ..typed,
      elements_promised: list.any(named, fn(hinted) {
        hinted.name == typed.column.name
      }),
    )
  })
}

fn check_element_name(
  analyzer: Analyzer,
  context: Context,
  relations: List(String),
  columns: List(TypedColumn),
  hinted: query_hint.NamedLine,
) -> Result(Nil, Problem) {
  let problem = fn(message) {
    Problem(file: context.file, line: hinted.line, message:)
  }
  let start = "hint 'not null elements: " <> hinted.name <> "' "
  case list.find(columns, fn(typed) { typed.column.name == hinted.name }) {
    Ok(TypedColumn(gleam_type: gleam_type.ListType(_), ..)) -> Ok(Nil)
    Ok(typed) ->
      Error(problem(
        start
        <> "names a column that is not an array: its Gleam type is "
        <> gleam_type.type_text(typed.gleam_type)
        <> "; the hint is only for array columns",
      ))
    Error(Nil) ->
      Error(problem(
        start <> missing_column_text(analyzer, relations, columns, hinted.name),
      ))
  }
}

/// Tells why a name is not a result column: it is a column of a table that
/// the statement reads but does not return, or no column at all.
fn missing_column_text(
  analyzer: Analyzer,
  relations: List(String),
  columns: List(TypedColumn),
  name: String,
) -> String {
  let found =
    nullability.execute(analyzer, relation_column_sql, [
      Some(fingerprint.text_array_literal(relations)),
      Some(name),
    ])
    |> result.unwrap([])
    |> list.flat_map(option.values)
  let result_text = case columns {
    [] -> "the statement returns no columns"
    _ -> "the result columns are " <> column_list(columns)
  }
  case found {
    [] -> "names an unknown column; " <> result_text
    tables ->
      "names "
      <> string.join(tables, ", ")
      <> ", which is not in the result of the statement; return it, or remove it from the hint ("
      <> result_text
      <> ")"
  }
}

fn check_duplicate_fields(
  context: Context,
  fields: List(Field),
  line: Int,
) -> Result(Nil, List(Problem)) {
  let names = list.map(fields, fn(field) { field.name })
  case first_duplicate(names) {
    Ok(duplicate) ->
      Error([
        Problem(
          file: context.file,
          line:,
          message: "two result columns give the field name '"
            <> duplicate
            <> "'; rename one with AS in the SQL",
        ),
      ])
    Error(Nil) -> Ok(Nil)
  }
}

fn first_duplicate(names: List(String)) -> Result(String, Nil) {
  list.index_map(names, fn(found, index) {
    #(found, list.drop(names, index + 1))
  })
  |> list.find(fn(pair) { list.contains(pair.1, pair.0) })
  |> result.map(fn(pair) { pair.0 })
}

// --- Unique constraints ----------------------------------------------------

fn resolve_unique(
  analyzer: Analyzer,
  context: Context,
  written: List(String),
) -> Result(List(String), List(Problem)) {
  list.map(context.hints.unique, resolve_unique_hint(
    analyzer,
    context,
    written,
    _,
  ))
  |> collect_all
  |> result.map(list.flatten)
}

fn resolve_unique_hint(
  analyzer: Analyzer,
  context: Context,
  written: List(String),
  hint: query_hint.UniqueHint,
) -> Result(List(String), Problem) {
  let problem = fn(message) {
    Problem(file: context.file, line: hint.line, message:)
  }
  use <- refuse_when_nothing_written(written, problem)
  use rows <- result.try(
    nullability.execute(analyzer, unique_sql, [
      Some(fingerprint.text_array_literal(written)),
      Some(hint.constraint),
    ])
    |> result.map_error(nullability.error_to_string)
    |> result.map_error(problem),
  )
  case list.flat_map(rows, option.values) {
    [] ->
      Error(problem(
        "'"
        <> hint.constraint
        <> "' is not a unique constraint, a primary key or a unique index of "
        <> string.join(written, ", "),
      ))
    names -> {
      use Nil <- result.map(refuse_same_name(analyzer, written, hint, problem))
      names
    }
  }
}

/// Refuses a unique hint whose name another index or constraint of the
/// database also has. A violation names only its constraint, so the other
/// object would give the `Conflict` of the hint.
fn refuse_same_name(
  analyzer: Analyzer,
  written: List(String),
  hint: query_hint.UniqueHint,
  problem: fn(String) -> Problem,
) -> Result(Nil, Problem) {
  use rows <- result.try(
    nullability.execute(analyzer, same_name_sql, [
      Some(fingerprint.text_array_literal(written)),
      Some(hint.constraint),
    ])
    |> result.map_error(nullability.error_to_string)
    |> result.map_error(problem),
  )
  let hinted = descriptions_of(rows, "hinted")
  case descriptions_of(rows, "other") {
    [] -> Ok(Nil)
    others ->
      Error(problem(
        "the name '"
        <> hint.constraint
        <> "' belongs to "
        <> string.join(hinted, " and ")
        <> ", and also to "
        <> string.join(others, " and ")
        <> "; PostgreSQL names a violation only by the name of its constraint, so a violation of the other object would give this Conflict; rename one of them",
      ))
  }
}

fn descriptions_of(
  rows: List(List(Option(String))),
  role: String,
) -> List(String) {
  list.filter_map(rows, fn(row) {
    case row {
      [Some(found_role), Some(description)] if found_role == role ->
        Ok(description)
      _ -> Error(Nil)
    }
  })
}

fn refuse_when_nothing_written(
  written: List(String),
  problem: fn(String) -> Problem,
  next: fn() -> Result(List(String), Problem),
) -> Result(List(String), Problem) {
  case written {
    [] ->
      Error(problem(
        "the statement writes no table, so no unique constraint can fail; remove the hint",
      ))
    _ -> next()
  }
}

// --- Parameters ------------------------------------------------------------

fn resolve_arguments(
  context: Context,
  types: Types,
  parameters: List(Parameter),
) -> Result(List(Argument), List(Problem)) {
  let named = name_parameters(context, parameters)
  let typed =
    list.map(parameters, fn(parameter) {
      gleam_type.resolve(types, parameter.type_oid)
      |> result.map_error(fn(type_name) {
        let placeholder = "$" <> int.to_string(parameter.position)
        Problem(
          file: context.file,
          line: parameter_line(context, parameter.position),
          message: "the parameter "
            <> placeholder
            <> " has the PostgreSQL type "
            <> type_name
            <> ", which dream_model does not support; cast it in the SQL from a supported type, for example "
            <> placeholder
            <> "::text::"
            <> type_name,
        )
      })
    })
    |> collect_all
    |> result.try(refuse_numeric_arrays(context, parameters, _))
  case named, typed {
    Ok(names), Ok(types) ->
      Ok(
        list.zip(parameters, list.zip(names, types))
        |> list.map(fn(entry) {
          let #(parameter, #(argument_name, gleam_type)) = entry
          Argument(
            name: argument_name,
            gleam_type:,
            optional: parameter.optional,
          )
        }),
      )
    _, _ -> Error(list.append(error_list(named), error_list(typed)))
  }
}

/// Refuses an array of `numeric` as a parameter. A `numeric` parameter is
/// sent as text, and the driver sends an array in binary, where a `numeric`
/// element as text is not possible.
fn refuse_numeric_arrays(
  context: Context,
  parameters: List(Parameter),
  types: List(GleamType),
) -> Result(List(GleamType), List(Problem)) {
  list.zip(parameters, types)
  |> list.map(fn(pair) {
    case pair {
      #(parameter, gleam_type.ListType(element)) ->
        case gleam_type.has_numeric(element) {
          True -> {
            let placeholder = "$" <> int.to_string(parameter.position)
            Error(Problem(
              file: context.file,
              line: parameter_line(context, parameter.position),
              message: "the parameter "
                <> placeholder
                <> " is an array of numeric, which dream_model cannot send exactly; take a text array and cast it in the SQL, for example "
                <> placeholder
                <> "::text[]::numeric[], and the parameter is a List(Option(String))",
            ))
          }
          False -> Ok(pair.1)
        }
      #(_, other) -> Ok(other)
    }
  })
  |> collect_all
}

fn name_parameters(
  context: Context,
  parameters: List(Parameter),
) -> Result(List(String), List(Problem)) {
  case null_hint.parse_hints(context.sql).parameters {
    Some(names) -> names_from_hint(context, names, list.length(parameters))
    None -> names_from_columns(context, parameters)
  }
}

fn names_from_hint(
  context: Context,
  names: List(String),
  count: Int,
) -> Result(List(String), List(Problem)) {
  let line =
    option.unwrap(context.hints.parameters_line, context.statement_line)
  let problem = fn(message) { Problem(file: context.file, line:, message:) }
  let checked =
    list.map(names, fn(hinted) {
      let argument_name = case string.ends_with(hinted, "?") {
        True -> string.drop_end(hinted, 1)
        False -> hinted
      }
      check_hinted_name(argument_name, problem)
    })
    |> collect_all
  use names <- result.try(checked)
  use <- refuse_count(count, list.length(names), problem)
  check_unique_names(context, names, Some(line), string.join(names, ", "))
}

fn refuse_count(
  count: Int,
  hinted: Int,
  problem: fn(String) -> Problem,
  next: fn() -> Result(List(String), List(Problem)),
) -> Result(List(String), List(Problem)) {
  case count == hinted {
    True -> next()
    False ->
      Error([
        problem(
          "the 'params' hint names "
          <> int.to_string(hinted)
          <> " parameters, and the statement has "
          <> int.to_string(count)
          <> "; name every parameter, in order",
        ),
      ])
  }
}

fn check_hinted_name(
  argument_name: String,
  problem: fn(String) -> Problem,
) -> Result(String, Problem) {
  let is_valid = name.to_value_name(argument_name) == Ok(argument_name)
  let is_reserved = is_reserved_argument_name(argument_name)
  case is_valid, is_reserved {
    True, False -> Ok(argument_name)
    True, True ->
      Error(problem(
        "the parameter name '"
        <> argument_name
        <> "' is a name that the generated function uses itself: its connection, a module, a helper or a decoder; choose another name",
      ))
    False, _ ->
      Error(problem(
        "'"
        <> argument_name
        <> "' is not a Gleam name; write the parameter names in snake case, for example user_id",
      ))
  }
}

fn names_from_columns(
  context: Context,
  parameters: List(Parameter),
) -> Result(List(String), List(Problem)) {
  let suggestion = suggest_names(parameters)
  use names <- result.try(
    list.map(parameters, name_from_columns(context, _, suggestion))
    |> collect_all,
  )
  check_unique_names(context, names, None, suggestion)
}

/// A `-- params:` line for the message of a refusal: the name of the column
/// of each parameter that has one, `value_<n>` for the others, and the
/// position after a name that is taken.
fn suggest_names(parameters: List(Parameter)) -> String {
  let bases =
    list.map(parameters, fn(parameter) {
      let columns =
        list.map(parameter.columns, fn(column) { column.column }) |> list.unique
      let base = case columns {
        [column] -> name.to_value_name(column) |> result.unwrap("")
        _ -> ""
      }
      #(base, parameter)
    })
  list.index_map(bases, fn(pair, index) {
    let #(base, parameter) = pair
    let position = int.to_string(parameter.position)
    let taken =
      list.take(bases, index)
      |> list.any(fn(earlier) { earlier.0 == base })
    let suggested = case base, taken {
      "", _ -> "value_" <> position
      _, True -> base <> "_" <> position
      _, False -> base
    }
    case parameter.optional {
      True -> suggested <> "?"
      False -> suggested
    }
  })
  |> string.join(", ")
}

fn name_from_columns(
  context: Context,
  parameter: Parameter,
  suggestion: String,
) -> Result(String, Problem) {
  let placeholder = "$" <> int.to_string(parameter.position)
  let problem = fn(message) {
    Problem(
      file: context.file,
      line: parameter_line(context, parameter.position),
      message: message
        <> "; name every parameter, in order, with a line like '-- params: "
        <> suggestion
        <> "'",
    )
  }
  let columns =
    list.map(parameter.columns, fn(column) { column.column })
    |> list.unique
  case columns {
    [] ->
      Error(problem(
        "the parameter "
        <> placeholder
        <> " is not stored into or compared with a table column, so it has no name",
      ))
    [column] -> name_after_column(column, placeholder, problem)
    _ ->
      Error(problem(
        "the parameter "
        <> placeholder
        <> " is used with the columns "
        <> string.join(columns, " and ")
        <> ", so its name is not clear",
      ))
  }
}

fn name_after_column(
  column: String,
  placeholder: String,
  problem: fn(String) -> Problem,
) -> Result(String, Problem) {
  let argument_name = name.to_value_name(column)
  let is_reserved = is_reserved_argument_name(result.unwrap(argument_name, ""))
  case argument_name, is_reserved {
    Ok(argument_name), False -> Ok(argument_name)
    Ok(argument_name), True ->
      Error(problem(
        "the parameter "
        <> placeholder
        <> " would be named '"
        <> argument_name
        <> "', which the generated function uses itself",
      ))
    Error(Nil), _ ->
      Error(problem(
        "the column '"
        <> column
        <> "' of the parameter "
        <> placeholder
        <> " gives no Gleam name",
      ))
  }
}

fn check_unique_names(
  context: Context,
  names: List(String),
  hint_line: Option(Int),
  suggestion: String,
) -> Result(List(String), List(Problem)) {
  use duplicate <- result_to_refusal(first_duplicate(names), names)
  let positions =
    list.index_map(names, fn(argument_name, index) {
      #(argument_name, index + 1)
    })
    |> list.filter(fn(pair) { pair.0 == duplicate })
    |> list.map(fn(pair) { pair.1 })
  let line =
    option.lazy_unwrap(hint_line, fn() {
      parameter_line(context, list.first(positions) |> result.unwrap(1))
    })
  Error([
    Problem(
      file: context.file,
      line:,
      message: "the parameters "
        <> string.join(
        list.map(positions, fn(position) { "$" <> int.to_string(position) }),
        " and ",
      )
        <> " would all be named '"
        <> duplicate
        <> "'; name every parameter, in order, with a line like '-- params: "
        <> suggestion
        <> "'",
    ),
  ])
}

/// Runs `next` with the value of `found`, or returns `Ok(names)` when
/// there is none.
fn result_to_refusal(
  found: Result(String, Nil),
  names: List(String),
  next: fn(String) -> Result(List(String), List(Problem)),
) -> Result(List(String), List(Problem)) {
  case found {
    Ok(duplicate) -> next(duplicate)
    Error(Nil) -> Ok(names)
  }
}

/// The line of the first `$n` of the SQL, outside comment lines.
fn parameter_line(context: Context, position: Int) -> Int {
  let placeholder = "$" <> int.to_string(position)
  string.split(context.sql, "\n")
  |> list.index_map(fn(text, index) { #(text, index + 1) })
  |> list.find(fn(pair) {
    !string.starts_with(string.trim_start(pair.0), "--")
    && has_placeholder(pair.0, placeholder)
  })
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap(context.statement_line)
}

fn has_placeholder(text: String, placeholder: String) -> Bool {
  string.split(text, placeholder)
  |> list.drop(1)
  |> list.any(fn(after) {
    !string.contains("0123456789", string.slice(after, 0, 1)) || after == ""
  })
}

// --- Names and text --------------------------------------------------------

/// Returns the function name of a SQL file path: its file name without
/// `.sql`, in snake case.
pub fn function_name(file: String) -> Result(String, Nil) {
  string.split(file, "/")
  |> list.last
  |> result.map(fn(base) { string.drop_end(base, 4) })
  |> result.try(name.to_value_name)
}

/// Returns the line number of the first line after the comment and blank
/// lines at the top, and the SQL from that line, without trailing
/// whitespace.
pub fn strip_leading_comments(sql: String) -> #(Int, String) {
  let lines = string.split(sql, "\n")
  let skipped =
    list.take_while(lines, fn(text) {
      let trimmed = string.trim(text)
      trimmed == "" || string.starts_with(trimmed, "--")
    })
    |> list.length
  #(
    skipped + 1,
    list.drop(lines, skipped)
      |> string.join("\n")
      |> string.trim_end,
  )
}
