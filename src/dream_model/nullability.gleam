//// Decides, for each result column and each parameter of a SQL statement,
//// whether it can be NULL. The code generator types the ones that can be
//// NULL as `Option`.
////
//// An `Analyzer` holds two connections to the database: one that receives
//// PostgreSQL's analyzed query tree, and one for catalog lookups. It keeps
//// the catalog facts that it read, so each `analyze` returns the analyzer
//// to use next.
////
//// `connect` opens the analyzer, `analyze` decides one statement and
//// returns the analyzer to use for the next one, and `close` closes both
//// connections.
////
//// The rules are in `dream_model/nullability/rules`, the reasons in
//// `dream_model/nullability/reason`.

import dream_model/nullability/hint.{
  type Hints, is_optional_parameter, parse_hints,
}
import dream_model/nullability/reason.{
  type ColumnReason, type Origin, type ParameterReason, Table,
}
import dream_model/nullability/rules.{
  collect_catalog_oids, decide_parameters, output_entries, trace_output_columns,
}
import dream_model/postgres/catalog.{type Catalog}
import dream_model/postgres/parameter_column.{
  type ParameterUse, find_uses, find_written_relations,
}
import dream_model/postgres/tree.{
  type TreeError, Captured, capture, check_version, tree_options,
}
import dream_model/postgres/wire.{
  type Connection, type WireError, Config, abort, get_parameter, parse_url,
}
import gleam/bool.{guard}
import gleam/int.{to_string}
import gleam/list.{
  append, contains, filter, filter_map, find, flat_map, index_map, length, map2,
  sort, unique, zip,
}
import gleam/option.{type Option, None, Some, to_result}
import gleam/result.{map_error, or, try, unwrap}
import gleam/string.{compare, join}

/// A result column.
pub type Column {
  Column(
    name: String,
    type_oid: Int,
    not_null: Bool,
    origin: Origin,
    reason: ColumnReason,
  )
}

/// A parameter (`$1`, `$2`, ...).
pub type Parameter {
  Parameter(
    position: Int,
    type_oid: Int,
    optional: Bool,
    reason: ParameterReason,
    /// The table columns that the parameter is stored into or compared
    /// with, in the order of the tree, without duplicates.
    columns: List(TableColumn),
  )
}

/// A column of a table, by name.
pub type TableColumn {
  TableColumn(
    /// The schema and the name of the table, quoted as `quote_ident`
    /// does, for example `public.users`.
    table: String,
    column: String,
  )
}

/// What `analyze` decides for one statement.
pub type Analysis {
  Analysis(
    columns: List(Column),
    parameters: List(Parameter),
    /// Every relation whose catalog facts the analysis read: each table or
    /// view of the statement, with every child table and partition, as
    /// `TableColumn.table` writes it, sorted.
    relations: List(String),
    /// The tables that the statement writes (INSERT, UPDATE, DELETE,
    /// MERGE, also in a CTE), sorted.
    written_relations: List(String),
  )
}

/// A hint that dream_model refuses.
pub type HintError {
  /// A `-- not null:` hint names a table column. The schema decides a
  /// table column; the reason says what it decided.
  HintNamesTableColumn(name: String, reason: ColumnReason)
  /// A `-- not null:` hint names a column that a rule already proves never
  /// NULL. The hint is not needed.
  HintNotNeeded(name: String, reason: ColumnReason)
  /// A hint names a column that the result does not have.
  HintNamesUnknownColumn(name: String)
}

/// Why a statement cannot be analyzed.
pub type AnalysisError {
  /// The connection failed, or a catalog query failed.
  DatabaseFailed(error: WireError)
  /// The server version is not supported, or the query tree cannot be read.
  TreeFailed(error: TreeError)
  /// The tree and Describe disagree on the number of result columns.
  ColumnCountMismatch(tree_columns: Int, described_columns: Int)
  /// One or more hints are refused.
  HintsRefused(errors: List(HintError))
}

/// A NULL in a column that a `-- not null:` hint promised is never NULL.
pub type BrokenPromise {
  BrokenPromise(query_name: String, column: String)
}

/// Two connections to one database, and the catalog facts read so far.
pub opaque type Analyzer {
  Analyzer(
    tree_connection: Connection,
    catalog_connection: Connection,
    catalog: Catalog,
  )
}

/// Connects to the database at a `postgresql://` URL and checks that
/// dream_model supports the server version.
pub fn connect(url: String) -> Result(Analyzer, AnalysisError) {
  use config <- try(parse_url(url) |> map_error(DatabaseFailed))
  use catalog_connection <- try(
    wire.connect(config) |> map_error(DatabaseFailed),
  )
  let opened = {
    use version <- try(
      get_parameter(catalog_connection, "server_version")
      |> unwrap("")
      |> check_version
      |> map_error(TreeFailed),
    )
    use tree_connection <- try(
      wire.connect(Config(..config, options: tree_options))
      |> map_error(DatabaseFailed),
    )
    Ok(Analyzer(
      tree_connection:,
      catalog_connection:,
      catalog: catalog.new(version),
    ))
  }
  map_error(opened, close_after_failure(catalog_connection, _))
}

/// Closes the connection after a failure, without a goodbye message, and
/// returns the failure.
fn close_after_failure(
  connection: Connection,
  error: AnalysisError,
) -> AnalysisError {
  abort(connection)
  error
}

/// Returns the major version of the server, for example 17.
pub fn version(analyzer: Analyzer) -> Int {
  catalog.version(analyzer.catalog)
}

/// Closes both connections. Returns the first error of saying goodbye to
/// the server; both connections are closed either way.
pub fn close(analyzer: Analyzer) -> Result(Nil, AnalysisError) {
  let tree_closed = wire.close(analyzer.tree_connection)
  let catalog_closed = wire.close(analyzer.catalog_connection)
  or(tree_closed, catalog_closed)
  |> map_error(DatabaseFailed)
}

/// Decides each result column and parameter of one SQL statement, with the
/// hints in its comments. Returns the analyzer to use next: it holds the
/// catalog facts read for this statement.
pub fn analyze(
  analyzer: Analyzer,
  sql: String,
) -> Result(#(Analysis, Analyzer), AnalysisError) {
  let hints = parse_hints(sql)
  use captured <- try(
    capture(analyzer.tree_connection, sql)
    |> map_error(TreeFailed),
  )
  let Captured(query:, description:, queries:) = captured
  let oids = collect_catalog_oids(query)
  use catalog <- try(
    catalog.load(
      analyzer.catalog,
      analyzer.catalog_connection,
      oids.relations,
      oids.functions,
      oids.types,
    )
    |> map_error(DatabaseFailed),
  )
  let analyzer = Analyzer(..analyzer, catalog:)
  let field_count = length(description.fields)
  let entry_count = length(output_entries(query))
  use <- guard(
    when: field_count != entry_count,
    return: Error(ColumnCountMismatch(entry_count, field_count)),
  )
  let traced = trace_output_columns(query, field_count, catalog)
  let columns =
    map2(description.fields, traced, fn(field, traced) {
      Column(
        name: field.name,
        type_oid: field.type_oid,
        not_null: traced.not_null,
        origin: traced.origin,
        reason: traced.reason,
      )
    })
  use columns <- try(apply_hints(columns, hints))
  let uses = find_uses(query)
  let parameters =
    decide_parameters(
      query,
      length(description.parameter_types),
      queries,
      catalog,
    )
    |> zip(description.parameter_types)
    |> index_map(fn(pair, index) {
      let #(rule, type_oid) = pair
      apply_parameter_hint(
        Parameter(
          position: index + 1,
          type_oid:,
          optional: rule.optional,
          reason: rule.reason,
          columns: name_parameter_columns(uses, index + 1, catalog),
        ),
        hints,
      )
    })
  let relations =
    flat_map(oids.relations, fn(oid) {
      catalog.get_relation(catalog, oid)
      |> result.map(fn(relation) { [oid, ..relation.descendants] })
      |> unwrap([])
    })
    |> relation_names(catalog)
  let written_relations =
    find_written_relations(query)
    |> relation_names(catalog)
  Ok(#(
    Analysis(columns:, parameters:, relations:, written_relations:),
    analyzer,
  ))
}

/// Runs one statement on the catalog connection, with each parameter as
/// text (`None` is NULL). The generator reads the catalog facts that the
/// NULL rules do not need with it: types, unique constraints and the
/// schema fingerprint.
pub fn execute(
  analyzer: Analyzer,
  sql: String,
  parameters: List(Option(String)),
) -> Result(List(List(Option(String))), AnalysisError) {
  wire.execute(analyzer.catalog_connection, sql, parameters)
  |> map_error(DatabaseFailed)
}

fn name_parameter_columns(
  uses: List(ParameterUse),
  position: Int,
  catalog: Catalog,
) -> List(TableColumn) {
  filter(uses, fn(found) { found.parameter == position })
  |> filter_map(fn(found) { name_table_column(found.column, catalog) })
  |> unique
}

fn name_table_column(
  column: parameter_column.TableColumn,
  catalog: Catalog,
) -> Result(TableColumn, Nil) {
  use relation <- try(catalog.get_relation(catalog, column.relation))
  use attribute <- result.map(catalog.get_attribute(relation, column.column))
  TableColumn(table: relation.name, column: attribute.name)
}

fn relation_names(oids: List(Int), catalog: Catalog) -> List(String) {
  filter_map(oids, catalog.get_relation(catalog, _))
  |> list.map(fn(relation) { relation.name })
  |> unique
  |> sort(compare)
}

/// Checks one row of results against the `-- not null:` hints, the same
/// way the generated decoder does: a NULL in a hinted column is an error.
pub fn check_row(
  columns: List(Column),
  query_name: String,
  row: List(Option(String)),
) -> Result(Nil, BrokenPromise) {
  zip(columns, row)
  |> find(fn(pair) { pair.1 == None && { pair.0 }.reason == reason.NotNullHint })
  |> result.map(fn(pair) { BrokenPromise(query_name:, column: { pair.0 }.name) })
  |> result_to_refusal
}

/// Returns the message of a broken promise.
pub fn broken_promise_to_string(promise: BrokenPromise) -> String {
  promise.query_name
  <> ": the SQL file promised '"
  <> promise.column
  <> "' is never NULL, and PostgreSQL returned NULL"
}

/// Returns a readable message for an analysis error.
pub fn error_to_string(error: AnalysisError) -> String {
  case error {
    DatabaseFailed(error) -> wire.error_to_string(error)
    TreeFailed(error) -> tree.error_to_string(error)
    ColumnCountMismatch(tree_columns, described_columns) ->
      "the analyzed query has "
      <> to_string(tree_columns)
      <> " result columns, and Describe reported "
      <> to_string(described_columns)
    HintsRefused(errors) ->
      list.map(errors, hint_error_to_string)
      |> join("; ")
  }
}

/// Returns a readable message for a refused hint.
pub fn hint_error_to_string(error: HintError) -> String {
  case error {
    HintNamesTableColumn(name, why) ->
      "hint 'not null: "
      <> name
      <> "' names a table column; the schema decides it ("
      <> reason.column_reason_to_string(why)
      <> ")"
    HintNotNeeded(name, why) ->
      "hint 'not null: "
      <> name
      <> "' is not needed: the column is never NULL by rule ("
      <> reason.column_reason_to_string(why)
      <> "); remove the hint"
    HintNamesUnknownColumn(name) ->
      "hint names '" <> name <> "', which is not a result column"
  }
}

fn result_to_refusal(found: Result(a, Nil)) -> Result(Nil, a) {
  case found {
    Ok(value) -> Error(value)
    Error(Nil) -> Ok(Nil)
  }
}

fn apply_hints(
  columns: List(Column),
  hints: Hints,
) -> Result(List(Column), AnalysisError) {
  let decided = list.map(columns, apply_not_null_hint(_, hints))
  let columns =
    list.map(decided, fn(pair) { apply_nullable_hint(pair.0, hints) })
  let errors = filter_map(decided, fn(pair) { to_result(pair.1, Nil) })
  let names = list.map(columns, fn(column) { column.name })
  let unknown =
    append(hints.not_null, hints.nullable)
    |> unique
    |> filter(fn(name) { !contains(names, name) })
    |> sort(compare)
    |> list.map(HintNamesUnknownColumn)
  case append(errors, unknown) {
    [] -> Ok(columns)
    errors -> Error(HintsRefused(errors))
  }
}

fn apply_not_null_hint(
  column: Column,
  hints: Hints,
) -> #(Column, Option(HintError)) {
  let hinted = contains(hints.not_null, column.name)
  case hinted, column.origin, column.not_null {
    False, _, _ -> #(column, None)
    True, Table, _ -> #(
      column,
      Some(HintNamesTableColumn(column.name, column.reason)),
    )
    True, _, True -> #(column, Some(HintNotNeeded(column.name, column.reason)))
    True, _, False -> #(
      Column(..column, not_null: True, reason: reason.NotNullHint),
      None,
    )
  }
}

fn apply_nullable_hint(column: Column, hints: Hints) -> Column {
  case contains(hints.nullable, column.name) {
    True -> Column(..column, not_null: False, reason: reason.NullableHint)
    False -> column
  }
}

fn apply_parameter_hint(parameter: Parameter, hints: Hints) -> Parameter {
  case is_optional_parameter(hints, parameter.position) {
    True -> Parameter(..parameter, optional: True, reason: reason.ParamsHint)
    False -> parameter
  }
}
