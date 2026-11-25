//// The facts from PostgreSQL's system catalogs that the NULL rules need,
//// read with parameterized queries and kept for later queries.
////
//// `load` reads the facts for the relations and functions that a query
//// uses, and for every child table and partition of those relations. The
//// NULL rules then read them with the `get_` functions and run no SQL.

import dream_model/postgres/wire
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/set
import gleam/string

/// A column of a table, view or other relation.
pub type Attribute {
  Attribute(
    number: Int,
    name: String,
    not_null: Bool,
    type_oid: Int,
    /// True when the column's type is a domain.
    has_domain_type: Bool,
  )
}

/// A relation (`pg_class` row) and the rules on it.
pub type Relation {
  Relation(
    /// `relkind`: `r` table, `p` partitioned table, `v` view, `m`
    /// materialized view, `f` foreign table, and so on.
    kind: String,
    attributes: List(Attribute),
    /// Every child table and partition, at any depth.
    descendants: List(Int),
    /// The column numbers that a CHECK constraint of this relation names.
    check_columns: List(Int),
    /// The columns with a NOT NULL constraint that is NOT VALID
    /// (PostgreSQL 18 and newer).
    not_valid_not_null: List(String),
    /// True when a BEFORE trigger (not an internal one) is on the relation.
    has_before_trigger: Bool,
    /// True when row-level security is on, or a policy has WITH CHECK.
    has_row_security: Bool,
  )
}

/// A domain type, with its base domains.
pub type Domain {
  Domain(
    /// True when the domain or one of its base domains is NOT NULL.
    not_null: Bool,
    /// True when the domain or one of its base domains has a CHECK.
    has_check: Bool,
  )
}

/// A function (`pg_proc` row).
pub type Function {
  Function(name: String, schema: String)
}

/// The facts read so far.
pub opaque type Catalog {
  Catalog(
    version: Int,
    relations: Dict(Int, Relation),
    domains: Dict(Int, Domain),
    functions: Dict(Int, Function),
  )
}

/// Returns an empty catalog for a server of the given major version.
pub fn new(version: Int) -> Catalog {
  Catalog(
    version:,
    relations: dict.new(),
    domains: dict.new(),
    functions: dict.new(),
  )
}

/// Returns the major version of the server.
pub fn version(catalog: Catalog) -> Int {
  catalog.version
}

/// Reads the facts for the relations and functions that the catalog does
/// not hold yet, with every child table and partition of the relations,
/// and the domains of their columns.
pub fn load(
  catalog: Catalog,
  connection: wire.Connection,
  relation_oids: List(Int),
  function_oids: List(Int),
) -> Result(Catalog, wire.WireError) {
  use catalog <- result.try(load_relations(catalog, connection, relation_oids))
  use catalog <- result.try(load_domains(catalog, connection))
  load_functions(catalog, connection, function_oids)
}

/// Returns the facts of a relation.
pub fn get_relation(catalog: Catalog, oid: Int) -> Result(Relation, Nil) {
  dict.get(catalog.relations, oid)
}

/// Returns the facts of a domain type.
pub fn get_domain(catalog: Catalog, type_oid: Int) -> Result(Domain, Nil) {
  dict.get(catalog.domains, type_oid)
}

/// Returns the name and schema of a function.
pub fn get_function(catalog: Catalog, oid: Int) -> Result(Function, Nil) {
  dict.get(catalog.functions, oid)
}

/// Returns a column of a relation by its number.
pub fn get_attribute(
  relation: Relation,
  number: Int,
) -> Result(Attribute, Nil) {
  list.find(relation.attributes, fn(attribute) { attribute.number == number })
}

/// Returns a column of a relation by its name.
pub fn get_attribute_by_name(
  relation: Relation,
  name: String,
) -> Result(Attribute, Nil) {
  list.find(relation.attributes, fn(attribute) { attribute.name == name })
}

// --- Relations -------------------------------------------------------------

const family_sql =
  "with recursive family(root, oid) as (
  select c.oid, c.oid from pg_catalog.pg_class c where c.oid = any($1::oid[])
  union
  select f.root, i.inhrelid from pg_catalog.pg_inherits i
  join family f on i.inhparent = f.oid)
select root, oid from family"

const relations_sql =
  "select c.oid, c.relkind,
  exists (select 1 from pg_catalog.pg_trigger t where t.tgrelid = c.oid
    and not t.tgisinternal and (t.tgtype & 2) = 2),
  c.relrowsecurity or exists (select 1 from pg_catalog.pg_policy p
    where p.polrelid = c.oid and p.polwithcheck is not null)
from pg_catalog.pg_class c where c.oid = any($1::oid[])"

const attributes_sql =
  "select a.attrelid, a.attnum, a.attname, a.attnotnull, a.atttypid,
  t.typtype = 'd'
from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid = a.atttypid
where a.attrelid = any($1::oid[]) and a.attnum > 0 and not a.attisdropped"

const checks_sql =
  "select c.conrelid, k.attnum
from pg_catalog.pg_constraint c, unnest(c.conkey) as k(attnum)
where c.conrelid = any($1::oid[]) and c.contype = 'c'"

const not_valid_sql =
  "select c.conrelid, a.attname
from pg_catalog.pg_constraint c join pg_catalog.pg_attribute a
  on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
where c.conrelid = any($1::oid[]) and c.contype = 'n' and not c.convalidated"

fn load_relations(
  catalog: Catalog,
  connection: wire.Connection,
  oids: List(Int),
) -> Result(Catalog, wire.WireError) {
  let missing =
    list.filter(oids, fn(oid) { !dict.has_key(catalog.relations, oid) })
  use family_rows <- result.try(query_by_oids(connection, family_sql, missing))
  use family <- result.try(decode_rows(family_rows, decode_pair_of_integers))
  let new =
    list.map(family, fn(pair) { pair.1 })
    |> list.filter(fn(oid) { !dict.has_key(catalog.relations, oid) })
    |> list.unique
  use pairs <- result.try(
    query_by_oids(connection, family_sql, new)
    |> result.try(decode_rows(_, decode_pair_of_integers)),
  )
  use relations <- result.try(
    query_by_oids(connection, relations_sql, new)
    |> result.try(decode_rows(_, decode_relation_row)),
  )
  use attributes <- result.try(
    query_by_oids(connection, attributes_sql, new)
    |> result.try(decode_rows(_, decode_attribute_row)),
  )
  use checks <- result.try(
    query_by_oids(connection, checks_sql, new)
    |> result.try(decode_rows(_, decode_pair_of_integers)),
  )
  use not_valid <- result.try(load_not_valid(catalog, connection, new))
  let relations =
    list.fold(relations, catalog.relations, fn(relations, row) {
      let #(oid, kind, has_before_trigger, has_row_security) = row
      let relation =
        Relation(
          kind:,
          attributes: list.filter_map(attributes, fn(attribute) {
            case attribute.0 == oid {
              True -> Ok(attribute.1)
              False -> Error(Nil)
            }
          }),
          descendants: values_for(pairs, oid)
            |> list.filter(fn(descendant) { descendant != oid }),
          check_columns: values_for(checks, oid),
          not_valid_not_null: values_for(not_valid, oid),
          has_before_trigger:,
          has_row_security:,
        )
      dict.insert(relations, oid, relation)
    })
  Ok(Catalog(..catalog, relations:))
}

fn load_not_valid(
  catalog: Catalog,
  connection: wire.Connection,
  oids: List(Int),
) -> Result(List(#(Int, String)), wire.WireError) {
  case catalog.version >= 18 {
    False -> Ok([])
    True ->
      query_by_oids(connection, not_valid_sql, oids)
      |> result.try(decode_rows(_, decode_integer_and_text))
  }
}

fn values_for(pairs: List(#(Int, a)), key: Int) -> List(a) {
  list.filter_map(pairs, fn(pair) {
    case pair.0 == key {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

// --- Domains ---------------------------------------------------------------

const domains_sql =
  "with recursive chain(root, oid, not_null, base) as (
  select t.oid, t.oid, t.typnotnull, t.typbasetype from pg_catalog.pg_type t
  where t.oid = any($1::oid[])
  union all
  select c.root, t.oid, t.typnotnull, t.typbasetype from pg_catalog.pg_type t
  join chain c on t.oid = c.base where t.typtype = 'd')
select c.root, bool_or(c.not_null),
  bool_or(exists (select 1 from pg_catalog.pg_constraint k
    where k.contypid = c.oid and k.contype = 'c'))
from chain c group by c.root"

fn load_domains(
  catalog: Catalog,
  connection: wire.Connection,
) -> Result(Catalog, wire.WireError) {
  let missing =
    dict.values(catalog.relations)
    |> list.flat_map(fn(relation) { relation.attributes })
    |> list.filter(fn(attribute) { attribute.has_domain_type })
    |> list.map(fn(attribute) { attribute.type_oid })
    |> list.filter(fn(oid) { !dict.has_key(catalog.domains, oid) })
    |> list.unique
  use rows <- result.try(
    query_by_oids(connection, domains_sql, missing)
    |> result.try(decode_rows(_, decode_domain_row)),
  )
  let domains =
    list.fold(rows, catalog.domains, fn(domains, row) {
      dict.insert(domains, row.0, row.1)
    })
  Ok(Catalog(..catalog, domains:))
}

// --- Functions -------------------------------------------------------------

const functions_sql =
  "select p.oid, p.proname, n.nspname
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where p.oid = any($1::oid[])"

fn load_functions(
  catalog: Catalog,
  connection: wire.Connection,
  oids: List(Int),
) -> Result(Catalog, wire.WireError) {
  let missing =
    list.filter(oids, fn(oid) { !dict.has_key(catalog.functions, oid) })
  use rows <- result.try(
    query_by_oids(connection, functions_sql, missing)
    |> result.try(decode_rows(_, decode_function_row)),
  )
  let functions =
    list.fold(rows, catalog.functions, fn(functions, row) {
      dict.insert(functions, row.0, row.1)
    })
  Ok(Catalog(..catalog, functions:))
}

// --- Rows ------------------------------------------------------------------

/// Runs a catalog query with one parameter, an array of oids. Runs nothing
/// for an empty list.
fn query_by_oids(
  connection: wire.Connection,
  sql: String,
  oids: List(Int),
) -> Result(List(List(Option(String))), wire.WireError) {
  case oids {
    [] -> Ok([])
    _ -> {
      let array =
        "{"
        <> string.join(
          list.map(set.to_list(set.from_list(oids)), int.to_string),
          ",",
        )
        <> "}"
      wire.execute(connection, sql, [Some(array)])
    }
  }
}

fn decode_rows(
  rows: List(List(Option(String))),
  decoder: fn(List(Option(String))) -> Result(a, Nil),
) -> Result(List(a), wire.WireError) {
  list.try_map(rows, decoder)
  |> result.replace_error(wire.ProtocolViolation(
    "a catalog query returned an unexpected row",
  ))
}

fn decode_pair_of_integers(
  row: List(Option(String)),
) -> Result(#(Int, Int), Nil) {
  use first <- result.try(get_integer(row, 0))
  use second <- result.try(get_integer(row, 1))
  Ok(#(first, second))
}

fn decode_integer_and_text(
  row: List(Option(String)),
) -> Result(#(Int, String), Nil) {
  use first <- result.try(get_integer(row, 0))
  use second <- result.try(get_text(row, 1))
  Ok(#(first, second))
}

fn decode_relation_row(
  row: List(Option(String)),
) -> Result(#(Int, String, Bool, Bool), Nil) {
  use oid <- result.try(get_integer(row, 0))
  use kind <- result.try(get_text(row, 1))
  use has_before_trigger <- result.try(get_boolean(row, 2))
  use has_row_security <- result.try(get_boolean(row, 3))
  Ok(#(oid, kind, has_before_trigger, has_row_security))
}

fn decode_attribute_row(
  row: List(Option(String)),
) -> Result(#(Int, Attribute), Nil) {
  use relation <- result.try(get_integer(row, 0))
  use number <- result.try(get_integer(row, 1))
  use name <- result.try(get_text(row, 2))
  use not_null <- result.try(get_boolean(row, 3))
  use type_oid <- result.try(get_integer(row, 4))
  use has_domain_type <- result.try(get_boolean(row, 5))
  Ok(#(
    relation,
    Attribute(number:, name:, not_null:, type_oid:, has_domain_type:),
  ))
}

fn decode_domain_row(row: List(Option(String))) -> Result(#(Int, Domain), Nil) {
  use oid <- result.try(get_integer(row, 0))
  use not_null <- result.try(get_boolean(row, 1))
  use has_check <- result.try(get_boolean(row, 2))
  Ok(#(oid, Domain(not_null:, has_check:)))
}

fn decode_function_row(
  row: List(Option(String)),
) -> Result(#(Int, Function), Nil) {
  use oid <- result.try(get_integer(row, 0))
  use name <- result.try(get_text(row, 1))
  use schema <- result.try(get_text(row, 2))
  Ok(#(oid, Function(name:, schema:)))
}

fn get_text(row: List(Option(String)), index: Int) -> Result(String, Nil) {
  list.drop(row, index)
  |> list.first
  |> result.try(option.to_result(_, Nil))
}

fn get_integer(row: List(Option(String)), index: Int) -> Result(Int, Nil) {
  get_text(row, index)
  |> result.try(int.parse)
}

fn get_boolean(row: List(Option(String)), index: Int) -> Result(Bool, Nil) {
  get_text(row, index)
  |> result.map(fn(text) { text == "t" })
}
