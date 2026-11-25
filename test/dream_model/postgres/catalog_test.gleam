//// Tests for `dream_model/postgres/catalog`, on the attack database.

import dream_model/postgres/catalog.{Attribute, Domain, Function}
import dream_model/postgres/wire
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/attack_database
import fixtures/servers
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result

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
      "get_attribute returns a column by its number",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "users"))
        |> result.try(catalog.get_attribute(_, 2))
      },
      Ok(Attribute(2, "email", True, 25, False)),
    ),
    catalog_case(
      "get_attribute_by_name returns a column by its name",
      version,
      fn(catalog, oids) {
        catalog.get_relation(catalog, oid_of(oids, "contacts"))
        |> result.try(catalog.get_attribute_by_name(_, "email"))
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
        |> result.map(fn(relation) {
          list.sort(relation.check_columns, int.compare)
        })
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
      "get_function returns the name and schema of a function",
      version,
      fn(catalog, _oids) { catalog.get_function(catalog, 2803) },
      Ok(Function("count", "pg_catalog")),
    ),
    catalog_case(
      "get_relation returns an error for a relation that was not loaded",
      version,
      fn(catalog, _oids) {
        catalog.get_relation(catalog, 1)
        |> result.replace(Nil)
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
]

fn oid_of(oids: List(#(String, Int)), name: String) -> Int {
  list.key_find(oids, name) |> result.unwrap(0)
}

fn catalog_case(
  name: String,
  version: Int,
  read: fn(catalog.Catalog, List(#(String, Int))) -> a,
  expected: a,
) {
  it(name, fn() {
    // Arrange
    let connection = servers.connect(version, attack_database.database)
    let oids = read_oids(connection)
    let relations =
      names
      |> list.map(fn(pair) { oid_of(oids, pair.0) })

    // Act
    let assert Ok(loaded) =
      catalog.load(catalog.new(version), connection, relations, [2803])
    let assert Ok(loaded) = catalog.load(loaded, connection, relations, [2803])
    let _ = wire.close(connection)

    // Assert
    read(loaded, oids)
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the catalog fact")
  })
}

fn read_oids(connection: wire.Connection) -> List(#(String, Int)) {
  let assert Ok(rows) =
    wire.simple_query(
      connection,
      "select relname, oid from pg_class where relname in ('users', 'contacts', 'animals', 'dogs', 'checked', 'secured') union all select 'strict_text', 'strict_text'::regtype::oid",
    )
  list.filter_map(rows, fn(row) {
    case row {
      [Some(name), Some(oid)] ->
        int.parse(oid) |> result.map(fn(oid) { #(name, oid) })
      _ -> Error(Nil)
    }
  })
}
