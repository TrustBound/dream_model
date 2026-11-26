//// The facts from PostgreSQL's system catalogs that the NULL rules need,
//// read with parameterized queries and kept for later queries.
////
//// `load` reads the facts for the relations and functions that a query
//// uses, and for every child table and partition of those relations. The
//// NULL rules then read them with the `get_` functions and run no SQL.

import dream_model/postgres/wire.{
  type Connection, type WireError, ProtocolViolation, execute,
}
import gleam/dict.{type Dict, get, has_key, insert, values}
import gleam/int.{parse, to_string}
import gleam/list.{
  append, drop, filter, filter_map, find, flat_map, fold, try_map, unique,
}
import gleam/option.{type Option, Some, to_result}
import gleam/result.{replace_error, try}
import gleam/set.{from_list, to_list}
import gleam/string.{join}

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
    /// The schema and the name, each quoted as `quote_ident` does, for
    /// example `public.users`.
    name: String,
    /// `relkind`: `r` table, `p` partitioned table, `v` view, `m`
    /// materialized view, `f` foreign table, and so on.
    kind: String,
    attributes: List(Attribute),
    /// Every child table and partition, at any depth.
    descendants: List(Int),
    /// The column numbers that a CHECK constraint of this relation names.
    /// `0` stands for a CHECK with a whole-row reference or with no column,
    /// which can reject NULL in any column.
    check_columns: List(Int),
    /// The column numbers of the partition key of a partitioned table.
    /// `0` stands for an expression in the key, which can use any column.
    partition_key_columns: List(Int),
    /// The column numbers that a generated column is computed from.
    generated_sources: List(Int),
    /// The columns with a NOT NULL constraint that is NOT VALID
    /// (PostgreSQL 18 and newer).
    not_valid_not_null: List(String),
    /// True when a row-level BEFORE or INSTEAD OF trigger (not an internal
    /// one) is on the relation: `tgtype` has the ROW bit (1) and the BEFORE
    /// bit (2), or the ROW bit and the INSTEAD bit (64). A statement-level
    /// trigger cannot see the values of a row. The schema fingerprint of
    /// dream_postgres reads the same BEFORE ROW triggers (`tgtype & 3 = 3`).
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
  Function(
    name: String,
    schema: String,
    /// True for a built-in length coercion function: the function of a
    /// cast from a type to the same type (`pg_cast`), such as the one that
    /// cuts a value to the length of a `varchar(n)` column. Such a
    /// function is strict, so it keeps NULL as NULL.
    is_length_coercion: Bool,
  )
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

/// Reads the facts for the relations, functions and types that the
/// catalog does not hold yet, with every child table and partition of the
/// relations, and the domains of their columns. Of `type_oids`, only the
/// domain types get facts: `get_domain` gives `Error(Nil)` for any other
/// type.
pub fn load(
  catalog: Catalog,
  connection: Connection,
  relation_oids: List(Int),
  function_oids: List(Int),
  type_oids: List(Int),
) -> Result(Catalog, WireError) {
  use catalog <- try(load_relations(catalog, connection, relation_oids))
  use catalog <- try(load_domains(catalog, connection, type_oids))
  load_functions(catalog, connection, function_oids)
}

/// Returns the facts of a relation.
pub fn get_relation(catalog: Catalog, oid: Int) -> Result(Relation, Nil) {
  get(catalog.relations, oid)
}

/// Returns the facts of a domain type.
pub fn get_domain(catalog: Catalog, type_oid: Int) -> Result(Domain, Nil) {
  get(catalog.domains, type_oid)
}

/// Returns the name and schema of a function.
pub fn get_function(catalog: Catalog, oid: Int) -> Result(Function, Nil) {
  get(catalog.functions, oid)
}

/// Returns a column of a relation by its number.
pub fn get_attribute(
  relation: Relation,
  number: Int,
) -> Result(Attribute, Nil) {
  find(relation.attributes, fn(attribute) { attribute.number == number })
}

/// Returns a column of a relation by its name.
pub fn get_attribute_by_name(
  relation: Relation,
  name: String,
) -> Result(Attribute, Nil) {
  find(relation.attributes, fn(attribute) { attribute.name == name })
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
    and not t.tgisinternal
    and ((t.tgtype & 3) = 3 or (t.tgtype & 65) = 65)),
  c.relrowsecurity or exists (select 1 from pg_catalog.pg_policy p
    where p.polrelid = c.oid and p.polwithcheck is not null),
  pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(c.relname)
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where c.oid = any($1::oid[])"

const attributes_sql =
  "select a.attrelid, a.attnum, a.attname, a.attnotnull, a.atttypid,
  t.typtype = 'd'
from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid = a.atttypid
where a.attrelid = any($1::oid[]) and a.attnum > 0 and not a.attisdropped"

/// A CHECK with no column list gives the column number 0, like a whole-row
/// reference does.
const checks_sql =
  "select c.conrelid, k.attnum
from pg_catalog.pg_constraint c,
  unnest(coalesce(nullif(c.conkey, '{}'), '{0}'::int2[])) as k(attnum)
where c.conrelid = any($1::oid[]) and c.contype = 'c'"

/// An expression in a partition key gives the column number 0.
const partition_keys_sql =
  "select p.partrelid, k.attnum
from pg_catalog.pg_partitioned_table p,
  unnest(p.partattrs::int2[]) as k(attnum)
where p.partrelid = any($1::oid[])"

/// The columns that a generated column depends on, from `pg_depend`.
const generated_sources_sql =
  "select d.adrelid, p.refobjsubid
from pg_catalog.pg_attrdef d
join pg_catalog.pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
join pg_catalog.pg_depend p on p.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass
  and p.objid = d.oid and p.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
  and p.refobjid = d.adrelid and p.refobjsubid > 0 and p.refobjsubid <> d.adnum
where d.adrelid = any($1::oid[]) and a.attgenerated <> ''"

const not_valid_sql =
  "select c.conrelid, a.attname
from pg_catalog.pg_constraint c join pg_catalog.pg_attribute a
  on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
where c.conrelid = any($1::oid[]) and c.contype = 'n' and not c.convalidated"

fn load_relations(
  catalog: Catalog,
  connection: Connection,
  oids: List(Int),
) -> Result(Catalog, WireError) {
  let missing = filter(oids, fn(oid) { !has_key(catalog.relations, oid) })
  use family_rows <- try(query_by_oids(connection, family_sql, missing))
  use family <- try(decode_rows(family_rows, decode_pair_of_integers))
  let new =
    list.map(family, fn(pair) { pair.1 })
    |> filter(fn(oid) { !has_key(catalog.relations, oid) })
    |> unique
  use pairs <- try(
    query_by_oids(connection, family_sql, new)
    |> try(decode_rows(_, decode_pair_of_integers)),
  )
  use relations <- try(
    query_by_oids(connection, relations_sql, new)
    |> try(decode_rows(_, decode_relation_row)),
  )
  use attributes <- try(
    query_by_oids(connection, attributes_sql, new)
    |> try(decode_rows(_, decode_attribute_row)),
  )
  use checks <- try(
    query_by_oids(connection, checks_sql, new)
    |> try(decode_rows(_, decode_pair_of_integers)),
  )
  use partition_keys <- try(
    query_by_oids(connection, partition_keys_sql, new)
    |> try(decode_rows(_, decode_pair_of_integers)),
  )
  use generated_sources <- try(
    query_by_oids(connection, generated_sources_sql, new)
    |> try(decode_rows(_, decode_pair_of_integers)),
  )
  use not_valid <- try(load_not_valid(catalog, connection, new))
  let relations =
    fold(relations, catalog.relations, fn(relations, row) {
      let #(oid, kind, has_before_trigger, has_row_security, name) = row
      let relation =
        Relation(
          name:,
          kind:,
          attributes: filter_map(attributes, fn(attribute) {
            case attribute.0 == oid {
              True -> Ok(attribute.1)
              False -> Error(Nil)
            }
          }),
          descendants: values_for(pairs, oid)
            |> filter(fn(descendant) { descendant != oid }),
          check_columns: values_for(checks, oid),
          partition_key_columns: values_for(partition_keys, oid),
          generated_sources: values_for(generated_sources, oid) |> unique,
          not_valid_not_null: values_for(not_valid, oid),
          has_before_trigger:,
          has_row_security:,
        )
      insert(relations, oid, relation)
    })
  Ok(Catalog(..catalog, relations:))
}

fn load_not_valid(
  catalog: Catalog,
  connection: Connection,
  oids: List(Int),
) -> Result(List(#(Int, String)), WireError) {
  case catalog.version >= 18 {
    False -> Ok([])
    True ->
      query_by_oids(connection, not_valid_sql, oids)
      |> try(decode_rows(_, decode_integer_and_text))
  }
}

fn values_for(pairs: List(#(Int, a)), key: Int) -> List(a) {
  filter_map(pairs, fn(pair) {
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
  where t.oid = any($1::oid[]) and t.typtype = 'd'
  union all
  select c.root, t.oid, t.typnotnull, t.typbasetype from pg_catalog.pg_type t
  join chain c on t.oid = c.base where t.typtype = 'd')
select c.root, bool_or(c.not_null),
  bool_or(exists (select 1 from pg_catalog.pg_constraint k
    where k.contypid = c.oid and k.contype = 'c'))
from chain c group by c.root"

fn load_domains(
  catalog: Catalog,
  connection: Connection,
  type_oids: List(Int),
) -> Result(Catalog, WireError) {
  let missing =
    values(catalog.relations)
    |> flat_map(fn(relation) { relation.attributes })
    |> filter(fn(attribute) { attribute.has_domain_type })
    |> list.map(fn(attribute) { attribute.type_oid })
    |> append(type_oids)
    |> filter(fn(oid) { !has_key(catalog.domains, oid) })
    |> unique
  use rows <- try(
    query_by_oids(connection, domains_sql, missing)
    |> try(decode_rows(_, decode_domain_row)),
  )
  let domains =
    fold(rows, catalog.domains, fn(domains, row) {
      insert(domains, row.0, row.1)
    })
  Ok(Catalog(..catalog, domains:))
}

// --- Functions -------------------------------------------------------------

const functions_sql =
  "select p.oid, p.proname, n.nspname,
  p.oid < 16384 and p.proisstrict and exists (
    select from pg_catalog.pg_cast c
    where c.castfunc = p.oid and c.castsource = c.casttarget
  )
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where p.oid = any($1::oid[])"

fn load_functions(
  catalog: Catalog,
  connection: Connection,
  oids: List(Int),
) -> Result(Catalog, WireError) {
  let missing = filter(oids, fn(oid) { !has_key(catalog.functions, oid) })
  use rows <- try(
    query_by_oids(connection, functions_sql, missing)
    |> try(decode_rows(_, decode_function_row)),
  )
  let functions =
    fold(rows, catalog.functions, fn(functions, row) {
      insert(functions, row.0, row.1)
    })
  Ok(Catalog(..catalog, functions:))
}

// --- Rows ------------------------------------------------------------------

/// Runs a catalog query with one parameter, an array of oids. Runs nothing
/// for an empty list.
fn query_by_oids(
  connection: Connection,
  sql: String,
  oids: List(Int),
) -> Result(List(List(Option(String))), WireError) {
  case oids {
    [] -> Ok([])
    _ -> {
      let array =
        "{" <> join(list.map(to_list(from_list(oids)), to_string), ",") <> "}"
      execute(connection, sql, [Some(array)])
    }
  }
}

fn decode_rows(
  rows: List(List(Option(String))),
  decoder: fn(List(Option(String))) -> Result(a, Nil),
) -> Result(List(a), WireError) {
  try_map(rows, decoder)
  |> replace_error(ProtocolViolation(
    "a catalog query returned an unexpected row",
  ))
}

fn decode_pair_of_integers(
  row: List(Option(String)),
) -> Result(#(Int, Int), Nil) {
  use first <- try(get_integer(row, 0))
  use second <- try(get_integer(row, 1))
  Ok(#(first, second))
}

fn decode_integer_and_text(
  row: List(Option(String)),
) -> Result(#(Int, String), Nil) {
  use first <- try(get_integer(row, 0))
  use second <- try(get_text(row, 1))
  Ok(#(first, second))
}

fn decode_relation_row(
  row: List(Option(String)),
) -> Result(#(Int, String, Bool, Bool, String), Nil) {
  use oid <- try(get_integer(row, 0))
  use kind <- try(get_text(row, 1))
  use has_before_trigger <- try(get_boolean(row, 2))
  use has_row_security <- try(get_boolean(row, 3))
  use name <- try(get_text(row, 4))
  Ok(#(oid, kind, has_before_trigger, has_row_security, name))
}

fn decode_attribute_row(
  row: List(Option(String)),
) -> Result(#(Int, Attribute), Nil) {
  use relation <- try(get_integer(row, 0))
  use number <- try(get_integer(row, 1))
  use name <- try(get_text(row, 2))
  use not_null <- try(get_boolean(row, 3))
  use type_oid <- try(get_integer(row, 4))
  use has_domain_type <- try(get_boolean(row, 5))
  Ok(#(
    relation,
    Attribute(number:, name:, not_null:, type_oid:, has_domain_type:),
  ))
}

fn decode_domain_row(row: List(Option(String))) -> Result(#(Int, Domain), Nil) {
  use oid <- try(get_integer(row, 0))
  use not_null <- try(get_boolean(row, 1))
  use has_check <- try(get_boolean(row, 2))
  Ok(#(oid, Domain(not_null:, has_check:)))
}

fn decode_function_row(
  row: List(Option(String)),
) -> Result(#(Int, Function), Nil) {
  use oid <- try(get_integer(row, 0))
  use name <- try(get_text(row, 1))
  use schema <- try(get_text(row, 2))
  use is_length_coercion <- try(get_boolean(row, 3))
  Ok(#(oid, Function(name:, schema:, is_length_coercion:)))
}

fn get_text(row: List(Option(String)), index: Int) -> Result(String, Nil) {
  drop(row, index)
  |> list.first
  |> try(to_result(_, Nil))
}

fn get_integer(row: List(Option(String)), index: Int) -> Result(Int, Nil) {
  get_text(row, index)
  |> try(parse)
}

fn get_boolean(row: List(Option(String)), index: Int) -> Result(Bool, Nil) {
  get_text(row, index)
  |> result.map(fn(text) { text == "t" })
}
