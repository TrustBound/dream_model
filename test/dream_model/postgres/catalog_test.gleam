//// Tests for `dream_model/postgres/catalog`, on the attack database.

import dream_model/postgres/catalog.{Attribute, Domain, Function}
import dream_model/postgres/wire.{type Connection, close, simple_query}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/attack_database.{database}
import fixtures/servers.{connect}
import gleam/int.{compare, parse}
import gleam/list.{filter_map, key_find, sort}
import gleam/option.{Some}
import gleam/result.{replace, try, unwrap}
import gleam/string.{join}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/postgres/catalog", [
    catalog_case(
      "get_relation returns the relation kind",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "users"))
        |> result.map(fn(relation) { relation.kind })
      },
      Ok("r"),
    ),
    catalog_case(
      "get_relation returns the quoted schema and name",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "users"))
        |> result.map(fn(relation) { relation.name })
      },
      Ok("public.users"),
    ),
    catalog_case(
      "get_attribute returns a column by its number",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "users"))
        |> try(catalog.get_attribute(_, 2))
      },
      Ok(Attribute(2, "email", True, 25, False)),
    ),
    catalog_case(
      "get_attribute_by_name returns a column by its name",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "contacts"))
        |> try(catalog.get_attribute_by_name(_, "email"))
        |> result.map(fn(attribute) { attribute.has_domain_type })
      },
      Ok(True),
    ),
    catalog_case(
      "a relation holds its child tables",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "animals"))
        |> result.map(fn(relation) {
          relation.descendants == [oid_of(oids, "dogs")]
        })
      },
      Ok(True),
    ),
    catalog_case(
      "the child tables are loaded too",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "dogs"))
        |> result.map(fn(relation) { relation.kind })
      },
      Ok("r"),
    ),
    catalog_case(
      "a relation holds the columns of its CHECK constraints",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "checked"))
        |> result.map(fn(relation) { sort(relation.check_columns, compare) })
      },
      Ok([2, 3]),
    ),
    catalog_case(
      "a relation says when it has a BEFORE trigger",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "users"))
        |> result.map(fn(relation) { relation.has_before_trigger })
      },
      Ok(True),
    ),
    catalog_case(
      "a relation says when it has row-level security",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "secured"))
        |> result.map(fn(relation) { relation.has_row_security })
      },
      Ok(True),
    ),
    catalog_case(
      "get_domain returns the rules of a domain used by a loaded column",
      version,
      fn(catalog, oids) {
        catalog.get_domain(catalog, oid_of(oids, "strict_text"))
      },
      Ok(Domain(not_null: True, has_check: False)),
    ),
    catalog_case(
      "get_domain returns an error for a loaded type that is not a domain",
      version,
      fn(catalog, _oids) { catalog.get_domain(catalog, 25) },
      Error(Nil),
    ),
    catalog_case(
      "a whole-row CHECK and a CHECK without a column give the column 0",
      version,
      fn(catalog, oids) {
        ["whole_checked", "free_checked"]
        |> list.map(fn(name) {
          catalog.get_relation(catalog, oid_of(oids, name))
          |> result.map(fn(relation) { relation.check_columns })
        })
      },
      [Ok([0]), Ok([0])],
    ),
    catalog_case(
      "a partitioned table holds its key columns, 0 for an expression",
      version,
      fn(catalog, oids) {
        ["keyed", "keyed_expression", "users"]
        |> list.map(fn(name) {
          catalog.get_relation(catalog, oid_of(oids, name))
          |> result.map(fn(relation) { relation.partition_key_columns })
        })
      },
      [Ok([2]), Ok([0]), Ok([])],
    ),
    catalog_case(
      "a relation holds the columns that its generated columns use",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "gen_from"))
        |> result.map(fn(relation) { relation.generated_sources })
      },
      Ok([2]),
    ),
    catalog_case(
      "only row-level BEFORE and INSTEAD OF triggers count",
      version,
      fn(catalog, oids) {
        ["statement_triggered", "after_triggered", "iot_view"]
        |> list.map(fn(name) {
          catalog.get_relation(catalog, oid_of(oids, name))
          |> result.map(fn(relation) { relation.has_before_trigger })
        })
      },
      [Ok(False), Ok(False), Ok(True)],
    ),
    catalog_case(
      "get_function returns the name and schema of a function",
      version,
      fn(catalog, _oids) { catalog.get_function(catalog, 2803) },
      Ok(Function("count", "pg_catalog", False)),
    ),
    catalog_case(
      "get_function says that the varchar length coercion is one",
      version,
      fn(catalog, _oids) { catalog.get_function(catalog, 669) },
      Ok(Function("varchar", "pg_catalog", True)),
    ),
    catalog_case(
      "get_relation returns an error for a relation that was not loaded",
      version,
      fn(catalog, _oids) {
        catalog.get_relation(catalog, 1)
        |> replace(Nil)
      },
      Error(Nil),
    ),
    catalog_case(
      "version returns the server version",
      version,
      fn(catalog, _oids) { catalog.version(catalog) },
      version,
    ),
  ])
}

const names = [
  #("users", "users"),
  #("contacts", "contacts"),
  #("animals", "animals"),
  #("dogs", "dogs"),
  #("checked", "checked"),
  #("secured", "secured"),
  #("keyed", "keyed"),
  #("keyed_expression", "keyed_expression"),
  #("whole_checked", "whole_checked"),
  #("free_checked", "free_checked"),
  #("gen_from", "gen_from"),
  #("statement_triggered", "statement_triggered"),
  #("after_triggered", "after_triggered"),
  #("iot_view", "iot_view"),
]

fn oid_of(oids: List(#(String, Int)), name: String) -> Int {
  key_find(oids, name) |> unwrap(0)
}

fn catalog_case(
  name: String,
  version: Int,
  read: fn(catalog.Catalog, List(#(String, Int))) -> a,
  expected: a,
) {
  it(name, fn() {
    // Arrange
    let connection = connect(version, database())
    let oids = read_oids(connection)
    let relations =
      names
      |> list.map(fn(pair) { oid_of(oids, pair.0) })

    // Act
    let assert Ok(loaded) =
      catalog.load(catalog.new(version), connection, relations, [2803, 669], [
        25,
      ])
    let assert Ok(loaded) =
      catalog.load(loaded, connection, relations, [2803, 669], [])
    let _ = close(connection)

    // Assert
    read(loaded, oids)
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the catalog fact")
  })
}

fn read_oids(connection: Connection) -> List(#(String, Int)) {
  let assert Ok(rows) =
    simple_query(
      connection,
      "select relname, oid from pg_class where relname in ("
        <> list.map(names, fn(pair) { "'" <> pair.0 <> "'" })
      |> join(", ")
        <> ") union all select 'strict_text', 'strict_text'::regtype::oid",
    )
  filter_map(rows, fn(row) {
    case row {
      [Some(name), Some(oid)] ->
        parse(oid) |> result.map(fn(oid) { #(name, oid) })
      _ -> Error(Nil)
    }
  })
}
