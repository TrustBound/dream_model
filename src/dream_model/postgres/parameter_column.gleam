//// Finds the table columns that each parameter of an analyzed query is
//// stored into or compared with, and the tables that the query writes.
////
//// The code generator names a parameter after its column:
////
//// - stored into: the value of an INSERT column, an UPDATE SET entry or
////   an ON CONFLICT DO UPDATE SET entry is the parameter;
//// - compared with: an operator (`=`, `<`, `LIKE`, ...), `IS DISTINCT
////   FROM`, `= ANY ($1)` or `IN ($1, $2)` with a column on one side and
////   the parameter on the other.
////
//// A column is a table column, also through views, subqueries and joins.
//// Casts are looked through: `$1::int`, the length coercion of a
//// `varchar(n)` column, `RELABELTYPE`, `COERCETODOMAIN`, `COLLATEEXPR` and
//// `COERCEVIAIO`. This module reads only the tree; it
//// runs no SQL.

import dream_model/postgres/node.{
  type Node, NodeList, Record, get_field, get_item, integer, node_name, text,
}
import gleam/dict.{to_list}
import gleam/int
import gleam/list.{
  append, contains, drop, filter_map, find, flat_map, sort, unique, wrap,
}
import gleam/result.{try}
import gleam/string

/// A table column: the oid of the table and the number of the column.
pub type TableColumn {
  TableColumn(relation: Int, column: Int)
}

/// One use of a parameter with a column.
pub type ParameterUse {
  ParameterUse(parameter: Int, column: TableColumn)
}

const pass_through = [
  "RELABELTYPE", "COERCETODOMAIN", "COLLATEEXPR", "COERCEVIAIO",
]

/// `funcformat` of a cast: `1` an explicit cast, `2` an implicit one, such
/// as the length coercion of a `varchar(n)` column.
const cast_formats = ["1", "2"]

const comparisons = ["OPEXPR", "DISTINCTEXPR", "SCALARARRAYOPEXPR"]

const store_commands = ["2", "3"]

const write_commands = ["2", "3", "4", "5"]

const relation_entry = "0"

const subquery_entry = "1"

const join_entry = "2"

/// Returns every use of a parameter with a table column, in the order of
/// the tree.
pub fn find_uses(query: Node) -> List(ParameterUse) {
  walk(query, [])
}

/// Returns the oids of the tables that the query writes: the target of the
/// INSERT, UPDATE, DELETE or MERGE, and of each data-modifying CTE, sorted.
pub fn find_written_relations(query: Node) -> List(Int) {
  collect_queries(query)
  |> filter_map(written_relation)
  |> unique
  |> sort(int.compare)
}

fn written_relation(query: Node) -> Result(Int, Nil) {
  let target = get_integer(query, "resultRelation")
  case target > 0 && contains(write_commands, command(query)) {
    True -> get_relation_oid(get_range_entry(query, target))
    False -> Error(Nil)
  }
}

fn collect_queries(value: Node) -> List(Node) {
  let own = case node_name(value) {
    "QUERY" -> [value]
    _ -> []
  }
  append(own, flat_map(children(value), collect_queries))
}

// --- Walking ---------------------------------------------------------------

/// `stack` holds the queries from the innermost one out, for the
/// `varlevelsup` of a variable.
fn walk(value: Node, stack: List(Node)) -> List(ParameterUse) {
  let name = node_name(value)
  let stack = case name {
    "QUERY" -> [value, ..stack]
    _ -> stack
  }
  let own = case name {
    "QUERY" -> find_stores(value)
    _ -> find_comparison(value, name, stack)
  }
  append(own, flat_map(children(value), walk(_, stack)))
}

fn find_stores(query: Node) -> List(ParameterUse) {
  let target = get_integer(query, "resultRelation")
  let is_store = target > 0 && contains(store_commands, command(query))
  let relation = get_relation_oid(get_range_entry(query, target))
  case is_store, relation {
    True, Ok(relation) ->
      append(
        node.items(get_field(query, "targetList")),
        node.items(get_field(get_field(query, "onConflict"), "onConflictSet")),
      )
      |> filter_map(store_of_entry(_, relation))
    _, _ -> []
  }
}

fn store_of_entry(entry: Node, relation: Int) -> Result(ParameterUse, Nil) {
  use parameter <- result.map(get_parameter(unwrap(get_field(entry, "expr"))))
  ParameterUse(
    parameter:,
    column: TableColumn(relation:, column: get_integer(entry, "resno")),
  )
}

fn find_comparison(
  value: Node,
  name: String,
  stack: List(Node),
) -> List(ParameterUse) {
  let arguments = node.items(get_field(value, "args")) |> list.map(unwrap)
  case contains(comparisons, name), arguments {
    True, [left, right] ->
      append(compare(left, right, stack), compare(right, left, stack))
    _, _ -> []
  }
}

/// The parameters of `side` (the parameter itself, or each element of an
/// `ARRAYEXPR` of parameters) compared with the column of `other`.
fn compare(side: Node, other: Node, stack: List(Node)) -> List(ParameterUse) {
  case resolve_variable(other, stack) {
    Ok(column) ->
      parameters_of_side(side)
      |> list.map(ParameterUse(_, column))
    Error(Nil) -> []
  }
}

fn parameters_of_side(side: Node) -> List(Int) {
  case node_name(side) {
    "ARRAYEXPR" ->
      node.items(get_field(side, "elements"))
      |> filter_map(fn(element) { get_parameter(unwrap(element)) })
    _ -> get_parameter(side) |> result.map(wrap) |> result.unwrap([])
  }
}

// --- Variables -------------------------------------------------------------

fn resolve_variable(
  value: Node,
  stack: List(Node),
) -> Result(TableColumn, Nil) {
  case node_name(value) {
    "VAR" -> resolve_in_query(value, stack)
    _ -> Error(Nil)
  }
}

fn resolve_in_query(
  variable: Node,
  stack: List(Node),
) -> Result(TableColumn, Nil) {
  let stack = drop(stack, get_integer(variable, "varlevelsup"))
  use query <- try(list.first(stack))
  let entry = get_range_entry(query, get_integer(variable, "varno"))
  let column = get_integer(variable, "varattno")
  resolve_in_entry(entry, column, stack)
}

fn resolve_in_entry(
  entry: Node,
  column: Int,
  stack: List(Node),
) -> Result(TableColumn, Nil) {
  let kind = text(get_field(entry, "rtekind"))
  case kind {
    _ if column < 1 -> Error(Nil)
    _ if kind == relation_entry ->
      get_relation_oid(entry) |> result.map(TableColumn(_, column))
    _ if kind == join_entry ->
      get_item(get_field(entry, "joinaliasvars"), column - 1)
      |> unwrap
      |> resolve_variable(stack)
    _ if kind == subquery_entry -> resolve_in_subquery(entry, column, stack)
    _ -> Error(Nil)
  }
}

fn resolve_in_subquery(
  entry: Node,
  column: Int,
  stack: List(Node),
) -> Result(TableColumn, Nil) {
  let subquery = get_field(entry, "subquery")
  node.items(get_field(subquery, "targetList"))
  |> find(fn(target) { get_integer(target, "resno") == column })
  |> result.map(fn(target) { unwrap(get_field(target, "expr")) })
  |> try(resolve_variable(_, [subquery, ..stack]))
}

// --- Helpers ---------------------------------------------------------------

fn unwrap(expression: Node) -> Node {
  let name = node_name(expression)
  let is_cast =
    name == "FUNCEXPR"
    && contains(cast_formats, text(get_field(expression, "funcformat")))
  case contains(pass_through, name), is_cast {
    True, _ -> unwrap(get_field(expression, "arg"))
    False, True -> unwrap(get_item(get_field(expression, "args"), 0))
    False, False -> expression
  }
}

/// The number of an external parameter (`$n`).
fn get_parameter(value: Node) -> Result(Int, Nil) {
  let is_external =
    node_name(value) == "PARAM" && text(get_field(value, "paramkind")) == "0"
  case is_external {
    True -> Ok(get_integer(value, "paramid"))
    False -> Error(Nil)
  }
}

fn get_relation_oid(entry: Node) -> Result(Int, Nil) {
  case text(get_field(entry, "rtekind")) == relation_entry {
    True -> integer(get_field(entry, "relid"))
    False -> Error(Nil)
  }
}

fn command(query: Node) -> String {
  text(get_field(query, "commandType"))
}

fn get_integer(value: Node, field: String) -> Int {
  integer(get_field(value, field))
  |> result.unwrap(-1)
}

fn get_range_entry(query: Node, index_from_one: Int) -> Node {
  get_item(get_field(query, "rtable"), index_from_one - 1)
}

fn children(value: Node) -> List(Node) {
  case value {
    Record(fields:, ..) ->
      to_list(fields)
      |> sort(fn(first, second) { string.compare(first.0, second.0) })
      |> list.map(fn(pair) { pair.1 })
    NodeList(items) -> items
    _ -> []
  }
}
