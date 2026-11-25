//// The NULL rules: for each result column and each parameter of an
//// analyzed query, whether it can be NULL, and why.
////
//// The rules read PostgreSQL's rewritten query tree and the catalog facts.
//// They run no SQL.
////
//// Result columns:
////
//// - A table column takes NOT NULL from the schema, and from every child
////   table and partition that the scan reads.
//// - A table column that an outer join, a grouping set, `RETURNING old/new`
////   or `MERGE ... WHEN NOT MATCHED BY SOURCE` can make NULL is `Option`.
////   PostgreSQL's tree says which ones (`varnullingrels`).
//// - A short list of computed values is never NULL: a constant that is not
////   NULL, `count(...)`, `coalesce(...)` whose last argument is never
////   NULL, `EXISTS (...)`, `IS [NOT] NULL`, and `IS DISTINCT FROM` with a
////   built-in operator. In a query with grouping sets, such a value that is
////   equal to a grouping expression is `Option`, because the higher
////   grouping levels make it NULL.
//// - Any other computed value is `Option`.
////
//// Parameters: a parameter is `Option` only when it is stored straight
//// into a column that accepts NULL in every case (INSERT, UPDATE SET, ON
//// CONFLICT DO UPDATE SET). A built-in length coercion around the
//// parameter, such as the one of a `varchar(n)` column, keeps NULL as
//// NULL, so the store is still straight.

import dream_model/nullability/reason.{
  type ColumnReason, type Origin, type ParameterReason, Computed, Table,
}
import dream_model/postgres/catalog.{type Catalog, type Relation}
import dream_model/postgres/node.{type Node, Empty}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// What the rules decide for one result column.
pub type Traced {
  Traced(not_null: Bool, origin: Origin, reason: ColumnReason)
}

/// What the rules decide for one parameter.
pub type ParameterRule {
  ParameterRule(optional: Bool, reason: ParameterReason)
}

/// The relations and functions whose catalog facts the rules need.
pub type CatalogOids {
  CatalogOids(relations: List(Int), functions: List(Int))
}

const command_select = "1"

const command_update = "2"

const command_insert = "3"

const command_merge = "5"

const pass_through = ["RELABELTYPE", "COERCETODOMAIN", "COLLATEEXPR"]

/// `funcformat` of a function call that is a cast: `1` an explicit cast,
/// `2` an implicit one, such as the length coercion of a `varchar(n)`
/// column.
const cast_formats = ["1", "2"]

// --- Entry points ----------------------------------------------------------

/// Returns the target entries of the query's result columns: the
/// non-junk entries of the target list for a SELECT, the RETURNING list
/// for any other command.
pub fn output_entries(query: Node) -> List(Node) {
  case command(query) == command_select {
    True ->
      node.items(node.get_field(query, "targetList"))
      |> list.filter(fn(entry) {
        node.text(node.get_field(entry, "resjunk")) == "false"
      })
    False -> node.items(node.get_field(query, "returningList"))
  }
}

/// Decides each of the first `count` result columns of the query.
pub fn trace_output_columns(
  query: Node,
  count: Int,
  catalog: Catalog,
) -> List(Traced) {
  let entries = node.NodeList(output_entries(query))
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    trace_output_column(query, entries, index, catalog)
  })
}

/// Decides each parameter of the query. `count` is the number of
/// parameters that Describe reported.
pub fn decide_parameters(
  query: Node,
  count: Int,
  catalog: Catalog,
) -> List(ParameterRule) {
  let stores = parameter_stores(query, catalog)
  let occurrences = count_parameters(query, dict.new())
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    decide_parameter(index + 1, stores, occurrences, catalog)
  })
}

/// Collects the relations, aggregate functions, operator functions and
/// cast functions that the query uses, so that the catalog can load their
/// facts first.
pub fn collect_catalog_oids(query: Node) -> CatalogOids {
  let found = collect(query, CatalogOids(relations: [], functions: []))
  CatalogOids(
    relations: list.unique(found.relations),
    functions: list.unique(found.functions),
  )
}

// --- Result columns --------------------------------------------------------

fn trace_output_column(
  query: Node,
  entries: Node,
  index: Int,
  catalog: Catalog,
) -> Traced {
  case node.get_field(query, "setOperations") {
    Empty ->
      trace(
        node.get_field(node.get_item(entries, index), "expr"),
        [query],
        catalog,
      )
    operations ->
      trace_set_operation(query, operations, index + 1, [query], catalog)
  }
}

fn command(query: Node) -> String {
  node.text(node.get_field(query, "commandType"))
}

fn get_integer(value: Node, field: String) -> Int {
  node.integer(node.get_field(value, field))
  |> result.unwrap(-1)
}

fn get_range_entry(query: Node, index_from_one: Int) -> Node {
  node.get_item(node.get_field(query, "rtable"), index_from_one - 1)
}

fn has_grouping_sets(query: Node) -> Bool {
  node.items(node.get_field(query, "groupingSets")) != []
}

/// Traces output column `number` (from 1) of a query.
fn trace_column(
  query: Node,
  number: Int,
  stack: List(Node),
  catalog: Catalog,
) -> Traced {
  case node.get_field(query, "setOperations") {
    Empty -> trace_column_entry(query, number, stack, catalog)
    operations ->
      trace_set_operation(query, operations, number, [query, ..stack], catalog)
  }
}

fn trace_column_entry(
  query: Node,
  number: Int,
  stack: List(Node),
  catalog: Catalog,
) -> Traced {
  let entries = case command(query) == command_select {
    True -> node.items(node.get_field(query, "targetList"))
    False -> output_entries(query)
  }
  let entry =
    list.find(entries, fn(entry) { get_integer(entry, "resno") == number })
  case entry {
    Ok(entry) -> trace(node.get_field(entry, "expr"), [query, ..stack], catalog)
    Error(Nil) -> Traced(False, Computed, reason.ColumnUntraceable)
  }
}

fn trace_set_operation(
  query: Node,
  operation: Node,
  number: Int,
  stack: List(Node),
  catalog: Catalog,
) -> Traced {
  case node.node_name(operation) {
    "RANGETBLREF" -> {
      let entry = get_range_entry(query, get_integer(operation, "rtindex"))
      trace_column(node.get_field(entry, "subquery"), number, stack, catalog)
    }
    _ -> {
      let left =
        trace_set_operation(
          query,
          node.get_field(operation, "larg"),
          number,
          stack,
          catalog,
        )
      let right =
        trace_set_operation(
          query,
          node.get_field(operation, "rarg"),
          number,
          stack,
          catalog,
        )
      combine_branches(left, right)
    }
  }
}

fn combine_branches(left: Traced, right: Traced) -> Traced {
  let origin = case left.origin, right.origin {
    Table, Table -> Table
    _, _ -> Computed
  }
  case left.not_null, right.not_null {
    True, True -> Traced(True, origin, reason.NotNullInEveryBranch)
    False, _ -> Traced(False, origin, left.reason)
    True, False -> Traced(False, origin, right.reason)
  }
}

/// Decides an expression evaluated in the first query of `stack`. The rest
/// of the stack holds the outer queries, for outer references.
fn trace(expression: Node, stack: List(Node), catalog: Catalog) -> Traced {
  let name = node.node_name(expression)
  case list.contains(pass_through, name), name {
    True, _ -> trace(node.get_field(expression, "arg"), stack, catalog)
    False, "VAR" -> trace_variable(expression, stack, catalog)
    False, _ -> trace_computed(expression, name, stack, catalog)
  }
}

// --- Computed values -------------------------------------------------------

fn trace_computed(
  expression: Node,
  name: String,
  stack: List(Node),
  catalog: Catalog,
) -> Traced {
  let proven = case name {
    "CONST" ->
      prove(
        node.text(node.get_field(expression, "constisnull")) == "false",
        reason.NonNullConstant,
      )
    "AGGREF" ->
      prove(
        is_function(catalog, node.get_field(expression, "aggfnoid"), "count"),
        reason.CountAggregate,
      )
    "SUBLINK" ->
      prove(
        node.text(node.get_field(expression, "subLinkType")) == "0",
        reason.ExistsSubquery,
      )
    "NULLTEST" -> Ok(reason.NullTest)
    "DISTINCTEXPR" ->
      prove(
        is_built_in(catalog, node.get_field(expression, "opfuncid")),
        reason.DistinctFrom,
      )
    "COALESCEEXPR" ->
      prove(
        last_argument_not_null(expression, stack, catalog),
        reason.CoalesceWithNonNullLastArgument,
      )
    _ -> Error(Nil)
  }
  case proven {
    Ok(proof) -> check_grouping(expression, stack, proof)
    Error(Nil) ->
      Traced(False, Computed, reason.ComputedValue(string.lowercase(name)))
  }
}

fn last_argument_not_null(
  expression: Node,
  stack: List(Node),
  catalog: Catalog,
) -> Bool {
  let last =
    node.items(node.get_field(expression, "args"))
    |> list.last
    |> result.unwrap(Empty)
  trace(last, stack, catalog).not_null
}

fn prove(holds: Bool, proof: ColumnReason) -> Result(ColumnReason, Nil) {
  case holds {
    True -> Ok(proof)
    False -> Error(Nil)
  }
}

fn is_function(catalog: Catalog, oid: Node, name: String) -> Bool {
  catalog.get_function(catalog, node.integer(oid) |> result.unwrap(0))
  |> result.map(fn(function) {
    function.schema == "pg_catalog" && function.name == name
  })
  |> result.unwrap(False)
}

fn is_built_in(catalog: Catalog, oid: Node) -> Bool {
  catalog.get_function(catalog, node.integer(oid) |> result.unwrap(0))
  |> result.map(fn(function) { function.schema == "pg_catalog" })
  |> result.unwrap(False)
}

/// In a query with grouping sets, the higher grouping levels make each
/// grouping expression NULL. PostgreSQL 16 and 17 do not mark this in the
/// tree, and the planner also replaces any expression equal to a grouping
/// expression with the grouped value. So a proven value that is equal to a
/// grouping expression of its query can be NULL.
fn check_grouping(
  expression: Node,
  stack: List(Node),
  proof: ColumnReason,
) -> Traced {
  let query = list.first(stack) |> result.unwrap(Empty)
  case is_grouping_expression(query, expression) {
    True -> Traced(False, Computed, reason.GroupingSet)
    False -> Traced(True, Computed, proof)
  }
}

fn is_grouping_expression(query: Node, expression: Node) -> Bool {
  use <- bool.guard(when: !has_grouping_sets(query), return: False)
  let references =
    node.items(node.get_field(query, "groupClause"))
    |> list.map(get_integer(_, "tleSortGroupRef"))
  let compared = comparable(expression)
  node.items(node.get_field(query, "targetList"))
  |> list.filter(fn(entry) {
    list.contains(references, get_integer(entry, "ressortgroupref"))
  })
  |> list.any(fn(entry) {
    comparable(node.get_field(entry, "expr")) == compared
  })
}

fn comparable(expression: Node) -> Node {
  case list.contains(pass_through, node.node_name(expression)) {
    True -> comparable(node.get_field(expression, "arg"))
    False -> node.remove_locations(expression)
  }
}

// --- Variables -------------------------------------------------------------

fn trace_variable(
  variable: Node,
  stack: List(Node),
  catalog: Catalog,
) -> Traced {
  let levels_up = get_integer(variable, "varlevelsup")
  let rest = list.drop(stack, levels_up)
  let owner = list.first(rest) |> result.unwrap(Empty)
  let entry = get_range_entry(owner, get_integer(variable, "varno"))
  let resolved =
    resolve(entry, get_integer(variable, "varattno"), rest, catalog)
  let can_be_emptied =
    node.integers(node.get_field(variable, "varnullingrels")) != []
  use <- bool.guard(
    when: can_be_emptied,
    return: Traced(False, resolved.origin, reason.OuterJoinOrGroupingSet),
  )
  use <- bool.guard(
    when: is_missing_returning_row(variable, owner),
    return: Traced(False, resolved.origin, reason.ReturningOldNew),
  )
  use <- bool.guard(
    when: is_merge_source_without_match(variable, owner, levels_up),
    return: Traced(False, resolved.origin, reason.MergeNotMatchedBySource),
  )
  use <- bool.guard(
    when: has_grouping_sets(owner),
    return: Traced(False, resolved.origin, reason.GroupingSet),
  )
  resolved
}

/// `RETURNING old.x` exists for UPDATE and DELETE; `RETURNING new.x`
/// exists for UPDATE and for an INSERT without ON CONFLICT.
fn is_missing_returning_row(variable: Node, owner: Node) -> Bool {
  let returning = node.text(node.get_field(variable, "varreturningtype"))
  let present = case returning, command(owner) {
    "", _ | "0", _ -> True
    _, "2" -> True
    "1", "4" -> True
    "2", "3" -> node.node_name(node.get_field(owner, "onConflict")) == ""
    _, _ -> False
  }
  !present
}

fn is_merge_source_without_match(
  variable: Node,
  owner: Node,
  levels_up: Int,
) -> Bool {
  let not_matched_by_source =
    node.items(node.get_field(owner, "mergeActionList"))
    |> list.any(fn(action) {
      node.text(node.get_field(action, "matchKind")) == "1"
    })
  command(owner) == command_merge
  && levels_up == 0
  && node.text(node.get_field(variable, "varno"))
  != node.text(node.get_field(owner, "resultRelation"))
  && not_matched_by_source
}

fn resolve(
  entry: Node,
  column: Int,
  rest: List(Node),
  catalog: Catalog,
) -> Traced {
  case node.text(node.get_field(entry, "rtekind")) {
    "0" -> resolve_relation(entry, column, catalog)
    "1" ->
      trace_column(node.get_field(entry, "subquery"), column, rest, catalog)
    "2" -> resolve_join(entry, column, rest, catalog)
    "6" -> resolve_cte(entry, column, rest, catalog)
    "9" ->
      node.get_field(entry, "groupexprs")
      |> node.get_item(column - 1)
      |> trace(rest, catalog)
    kind -> Traced(False, Computed, reason.RangeResult(range_kind_name(kind)))
  }
}

fn range_kind_name(kind: String) -> String {
  [
    #("3", "function"),
    #("4", "tablefunc"),
    #("5", "values"),
    #("7", "tuplestore"),
    #("8", "result"),
  ]
  |> list.key_find(kind)
  |> result.unwrap("unknown")
}

fn resolve_relation(entry: Node, column: Int, catalog: Catalog) -> Traced {
  let oid = get_integer(entry, "relid")
  let relation = catalog.get_relation(catalog, oid)
  let kind = result.map(relation, fn(relation) { relation.kind })
  case column, kind {
    0, _ -> Traced(False, Computed, reason.WholeRow)
    _, _ if column < 0 -> Traced(True, Table, reason.SystemColumn)
    _, Ok("r") | _, Ok("p") -> {
      let inherits = node.text(node.get_field(entry, "inh")) == "true"
      let #(not_null, why) = column_not_null(catalog, oid, column, inherits)
      Traced(not_null, Table, why)
    }
    _, Ok(kind) -> Traced(False, Table, reason.RelationKindWithoutNotNull(kind))
    _, Error(Nil) -> Traced(False, Table, reason.ColumnNotFound)
  }
}

/// Whether a stored table column is NOT NULL in the table and in every
/// child table that a scan of the table reads, with no NOT VALID NOT NULL
/// constraint.
fn column_not_null(
  catalog: Catalog,
  oid: Int,
  column: Int,
  inherits: Bool,
) -> #(Bool, ColumnReason) {
  let found = {
    use relation <- result.try(catalog.get_relation(catalog, oid))
    use attribute <- result.try(catalog.get_attribute(relation, column))
    Ok(#(relation, attribute))
  }
  case found {
    Error(Nil) -> #(False, reason.ColumnNotFound)
    Ok(#(_, attribute)) if !attribute.not_null -> #(
      False,
      reason.ColumnAllowsNull,
    )
    Ok(#(relation, attribute)) -> {
      let checked =
        scanned_tables(oid, relation, inherits)
        |> list.try_each(check_table_column(catalog, _, attribute.name))
      #(
        checked == Ok(Nil),
        result.unwrap_error(checked, reason.NotNullInSchema),
      )
    }
  }
}

/// A scan of a table with `inh` reads every child table and partition too.
fn scanned_tables(oid: Int, relation: Relation, inherits: Bool) -> List(Int) {
  case inherits {
    True -> [oid, ..relation.descendants]
    False -> [oid]
  }
}

fn check_table_column(
  catalog: Catalog,
  oid: Int,
  name: String,
) -> Result(Nil, ColumnReason) {
  let found = {
    use relation <- result.try(catalog.get_relation(catalog, oid))
    use attribute <- result.try(catalog.get_attribute_by_name(relation, name))
    Ok(#(relation, attribute))
  }
  case found {
    Ok(#(relation, attribute)) if attribute.not_null ->
      refuse_when(
        list.contains(relation.not_valid_not_null, name),
        reason.NotNullNotValid,
      )
    _ -> Error(reason.ChildTableAllowsNull)
  }
}

fn resolve_join(
  entry: Node,
  column: Int,
  rest: List(Node),
  catalog: Catalog,
) -> Traced {
  case node.get_item(node.get_field(entry, "joinaliasvars"), column - 1) {
    Empty -> Traced(False, Computed, reason.JoinColumnUntraceable)
    alias -> trace(alias, rest, catalog)
  }
}

fn resolve_cte(
  entry: Node,
  column: Int,
  rest: List(Node),
  catalog: Catalog,
) -> Traced {
  let levels_up = get_integer(entry, "ctelevelsup")
  let owner_and_outer = list.drop(rest, levels_up)
  let owner = list.first(owner_and_outer) |> result.unwrap(Empty)
  let name = cte_name(node.get_field(entry, "ctename"))
  let matching =
    node.items(node.get_field(owner, "cteList"))
    |> list.filter(fn(cte) { cte_name(node.get_field(cte, "ctename")) == name })
  case matching {
    [cte] -> trace_cte(cte, column, owner_and_outer, catalog)
    _ -> Traced(False, Computed, reason.CteNotFound)
  }
}

/// PostgreSQL breaks the tree text into lines at spaces, also at an
/// escaped space inside a name, so a CTE name can come with a newline in
/// place of a space. Names are compared with newlines as spaces; two CTEs
/// that match the same name are not traced.
fn cte_name(name: Node) -> String {
  string.replace(node.text(name), "\n", " ")
}

fn trace_cte(
  cte: Node,
  column: Int,
  owner_and_outer: List(Node),
  catalog: Catalog,
) -> Traced {
  case node.text(node.get_field(cte, "cterecursive")) {
    "true" -> Traced(False, Computed, reason.RecursiveCte)
    _ ->
      trace_column(
        node.get_field(cte, "ctequery"),
        column,
        owner_and_outer,
        catalog,
      )
  }
}

// --- Parameters ------------------------------------------------------------

type Store {
  Store(parameter: Int, relation: Int, column: Int)
}

/// The parameters that are stored straight into a column: the whole value
/// of an INSERT or UPDATE target entry, or of an ON CONFLICT DO UPDATE SET
/// entry, is the parameter, also inside a built-in length coercion.
fn parameter_stores(query: Node, catalog: Catalog) -> List(Store) {
  let target = get_integer(query, "resultRelation")
  let is_store_command =
    command(query) == command_insert || command(query) == command_update
  use <- bool.guard(when: target < 1 || !is_store_command, return: [])
  let relation = get_integer(get_range_entry(query, target), "relid")
  let conflict_entries =
    node.get_field(node.get_field(query, "onConflict"), "onConflictSet")
  list.append(
    node.items(node.get_field(query, "targetList")),
    node.items(conflict_entries),
  )
  |> list.filter_map(fn(entry) {
    let value = stored_value(node.get_field(entry, "expr"), catalog)
    case is_external_parameter(value) {
      True ->
        Ok(Store(
          parameter: get_integer(value, "paramid"),
          relation:,
          column: get_integer(entry, "resno"),
        ))
      False -> Error(Nil)
    }
  })
}

/// The value of a store without the nodes that keep NULL as NULL: the
/// pass-through nodes, and a built-in length coercion.
fn stored_value(expression: Node, catalog: Catalog) -> Node {
  let is_pass_through = list.contains(pass_through, node.node_name(expression))
  case is_pass_through, is_length_coercion(expression, catalog) {
    True, _ -> stored_value(node.get_field(expression, "arg"), catalog)
    False, True ->
      stored_value(
        node.get_item(node.get_field(expression, "args"), 0),
        catalog,
      )
    False, False -> expression
  }
}

/// A call of a built-in length coercion function as a cast, whose
/// arguments after the value (the length and the explicit flag) are
/// constants that are not NULL. The catalog says which functions are
/// length coercions: the functions of a cast from a type to itself.
fn is_length_coercion(expression: Node, catalog: Catalog) -> Bool {
  let is_cast =
    node.node_name(expression) == "FUNCEXPR"
    && list.contains(
      cast_formats,
      node.text(node.get_field(expression, "funcformat")),
    )
  let is_coercion_function =
    catalog.get_function(catalog, get_integer(expression, "funcid"))
    |> result.map(fn(function) { function.is_length_coercion })
    |> result.unwrap(False)
  let has_constant_modifiers =
    node.items(node.get_field(expression, "args"))
    |> list.drop(1)
    |> list.all(is_constant_not_null)
  is_cast && is_coercion_function && has_constant_modifiers
}

fn is_constant_not_null(value: Node) -> Bool {
  node.node_name(value) == "CONST"
  && node.text(node.get_field(value, "constisnull")) == "false"
}

fn is_external_parameter(value: Node) -> Bool {
  node.node_name(value) == "PARAM"
  && node.text(node.get_field(value, "paramkind")) == "0"
}

/// Counts every use of each external parameter in the whole tree.
fn count_parameters(
  value: Node,
  counts: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  let counts = case is_external_parameter(value) {
    True ->
      dict.upsert(counts, get_integer(value, "paramid"), fn(count) {
        option_to_int(count) + 1
      })
    False -> counts
  }
  list.fold(children(value), counts, fn(counts, child) {
    count_parameters(child, counts)
  })
}

fn option_to_int(count: option.Option(Int)) -> Int {
  option.unwrap(count, 0)
}

fn decide_parameter(
  position: Int,
  stores: List(Store),
  occurrences: dict.Dict(Int, Int),
  catalog: Catalog,
) -> ParameterRule {
  let own_stores =
    list.filter(stores, fn(store) { store.parameter == position })
  let uses = dict.get(occurrences, position) |> result.unwrap(0)
  case own_stores, list.length(own_stores) == uses {
    [], _ -> ParameterRule(False, reason.Required)
    _, False -> ParameterRule(False, reason.AlsoUsedOutsideStore)
    _, True ->
      list.find_map(own_stores, fn(store) {
        accepts_null(catalog, store.relation, store.column)
        |> result_to_refusal
      })
      |> refusal_to_rule
  }
}

fn refusal_to_rule(refusal: Result(ParameterReason, Nil)) -> ParameterRule {
  case refusal {
    Ok(why) -> ParameterRule(False, why)
    Error(Nil) -> ParameterRule(True, reason.StoredIntoNullableColumn)
  }
}

fn result_to_refusal(
  accepted: Result(Nil, ParameterReason),
) -> Result(ParameterReason, Nil) {
  case accepted {
    Ok(Nil) -> Error(Nil)
    Error(why) -> Ok(why)
  }
}

/// Whether storing NULL into the column can never fail because of a
/// declared rule.
fn accepts_null(
  catalog: Catalog,
  oid: Int,
  column: Int,
) -> Result(Nil, ParameterReason) {
  use relation <- result.try(
    catalog.get_relation(catalog, oid)
    |> result.replace_error(reason.StoreColumnNotFound),
  )
  use attribute <- result.try(
    catalog.get_attribute(relation, column)
    |> result.replace_error(reason.StoreColumnNotFound),
  )
  use <- bool.guard(
    when: attribute.not_null,
    return: Error(reason.ColumnIsNotNull),
  )
  use Nil <- result.try(check_domain(catalog, attribute))
  use <- bool.guard(
    when: list.contains(relation.check_columns, column),
    return: Error(reason.CheckConstraint),
  )
  let family =
    [oid, ..relation.descendants]
    |> list.filter_map(catalog.get_relation(catalog, _))
  use Nil <- result.try(
    list.try_each(family, check_family_member(_, attribute.name)),
  )
  use <- bool.guard(
    when: list.any(family, fn(member) { member.has_before_trigger }),
    return: Error(reason.BeforeTrigger),
  )
  use <- bool.guard(
    when: list.any(family, fn(member) { member.has_row_security }),
    return: Error(reason.RowLevelSecurity),
  )
  Ok(Nil)
}

/// A domain whose facts are missing counts as NOT NULL, so the parameter
/// stays required.
fn check_domain(
  catalog: Catalog,
  attribute: catalog.Attribute,
) -> Result(Nil, ParameterReason) {
  use <- bool.guard(when: !attribute.has_domain_type, return: Ok(Nil))
  catalog.get_domain(catalog, attribute.type_oid)
  |> result.map(check_domain_rules)
  |> result.unwrap(Error(reason.DomainNotNull))
}

fn check_domain_rules(domain: catalog.Domain) -> Result(Nil, ParameterReason) {
  use <- bool.guard(when: domain.not_null, return: Error(reason.DomainNotNull))
  refuse_when(domain.has_check, reason.DomainCheck)
}

fn refuse_when(refused: Bool, why: a) -> Result(Nil, a) {
  case refused {
    True -> Error(why)
    False -> Ok(Nil)
  }
}

/// A child table or partition without the column has nothing to check.
fn check_family_member(
  member: Relation,
  name: String,
) -> Result(Nil, ParameterReason) {
  catalog.get_attribute_by_name(member, name)
  |> result.map(check_member_column(member, _))
  |> result.unwrap(Ok(Nil))
}

fn check_member_column(
  member: Relation,
  attribute: catalog.Attribute,
) -> Result(Nil, ParameterReason) {
  use <- bool.guard(
    when: attribute.not_null,
    return: Error(reason.PartitionNotNull),
  )
  refuse_when(
    list.contains(member.check_columns, attribute.number),
    reason.PartitionCheck,
  )
}

// --- Tree walking ----------------------------------------------------------

fn collect(value: Node, found: CatalogOids) -> CatalogOids {
  let found = collect_oid(value, found)
  list.fold(children(value), found, fn(found, child) { collect(child, found) })
}

fn collect_oid(value: Node, found: CatalogOids) -> CatalogOids {
  let kind = node.text(node.get_field(value, "rtekind"))
  case node.node_name(value), kind {
    "RANGETBLENTRY", "0" ->
      CatalogOids(..found, relations: [
        get_integer(value, "relid"),
        ..found.relations
      ])
    "AGGREF", _ ->
      CatalogOids(..found, functions: [
        get_integer(value, "aggfnoid"),
        ..found.functions
      ])
    "DISTINCTEXPR", _ ->
      CatalogOids(..found, functions: [
        get_integer(value, "opfuncid"),
        ..found.functions
      ])
    "FUNCEXPR", _ -> collect_cast_function(value, found)
    _, _ -> found
  }
}

/// A function call that is a cast can be a length coercion, which the
/// parameter rules look up.
fn collect_cast_function(value: Node, found: CatalogOids) -> CatalogOids {
  let format = node.text(node.get_field(value, "funcformat"))
  case list.contains(cast_formats, format) {
    True ->
      CatalogOids(..found, functions: [
        get_integer(value, "funcid"),
        ..found.functions
      ])
    False -> found
  }
}

fn children(value: Node) -> List(Node) {
  case value {
    node.Record(fields:, ..) -> dict.values(fields)
    node.NodeList(items) -> items
    _ -> []
  }
}
