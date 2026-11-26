//// Tests for `dream_model/nullability/rules` with trees written by hand:
//// shapes that PostgreSQL does not produce for valid SQL, where the rules
//// must still decide `Option`.

import dream_model/nullability/reason.{
  ColumnNotFound, ColumnUntraceable, Computed, CteNotFound,
  JoinColumnUntraceable, RangeResult, Table,
}
import dream_model/nullability/rules.{
  type Traced, CatalogOids, Traced, collect_catalog_oids, trace_output_columns,
}
import dream_model/postgres/catalog.{load, new}
import dream_model/postgres/node.{type Node, Empty}
import dream_model/postgres/wire.{close, simple_query}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/attack_database.{database}
import fixtures/servers.{connect}
import gleam/int.{compare, to_string}
import gleam/list.{sort}
import gleam/option.{Some}
import gleam/result.{unwrap}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/nullability/rules", [
    group("trace_output_columns", [
      trace_case(
        "a subquery column that the subquery does not hold",
        query_over(
          "{RANGETBLENTRY :rtekind 1 :subquery {QUERY :commandType 1 :targetList <>}}",
        ),
        Traced(False, Computed, ColumnUntraceable),
      ),
      trace_case(
        "a relation that the catalog does not hold",
        query_over("{RANGETBLENTRY :rtekind 0 :relid 1 :inh false}"),
        Traced(False, Table, ColumnNotFound),
      ),
      trace_case(
        "a join column that the join does not hold",
        query_over("{RANGETBLENTRY :rtekind 2 :joinaliasvars <>}"),
        Traced(False, Computed, JoinColumnUntraceable),
      ),
      trace_case(
        "a CTE that the query does not hold",
        query_over("{RANGETBLENTRY :rtekind 6 :ctename x :ctelevelsup 0}"),
        Traced(False, Computed, CteNotFound),
      ),
      trace_case(
        "a tuplestore range",
        query_over("{RANGETBLENTRY :rtekind 7}"),
        Traced(False, Computed, RangeResult("tuplestore")),
      ),
      trace_case(
        "a result range",
        query_over("{RANGETBLENTRY :rtekind 8}"),
        Traced(False, Computed, RangeResult("result")),
      ),
      trace_case(
        "a range kind that the rules do not know",
        query_over("{RANGETBLENTRY :rtekind 42}"),
        Traced(False, Computed, RangeResult("unknown")),
      ),
      it("a column number that the table does not have", fn() {
        // Arrange
        let connection = connect(version, database())
        let assert Ok([[Some(oid)]]) =
          simple_query(connection, "select 'users'::regclass::oid")
        let oid = int.parse(oid) |> unwrap(0)
        let assert Ok(loaded) = load(new(version), connection, [oid], [], [])
        let _ = close(connection)
        let query =
          parse(
            "{QUERY :commandType 1 :rtable ({RANGETBLENTRY :rtekind 0 :relid "
            <> to_string(oid)
            <> " :inh false}) :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 99 :varlevelsup 0} :resno 1 :resjunk false})}",
          )

        // Act
        let traced = trace_output_columns(query, 1, loaded)

        // Assert
        traced
        |> should
        |> be_equal([Traced(False, Table, ColumnNotFound)])
        |> or_fail_with("Expected ColumnNotFound")
      }),
    ]),
    group("collect_catalog_oids", [
      it(
        "collects relations, views, aggregates, operator functions and types once",
        fn() {
          // Arrange
          let query =
            parse(
              "{QUERY :rtable ({RANGETBLENTRY :rtekind 0 :relid 10} {RANGETBLENTRY :rtekind 1 :relid 11} {RANGETBLENTRY :rtekind 1 :relid 0} {RANGETBLENTRY :rtekind 0 :relid 10}) :targetList ({AGGREF :aggfnoid 2803} {DISTINCTEXPR :opfuncid 67} {COERCETODOMAIN :arg {PARAM :paramkind 0 :paramid 1 :paramtype 25} :resulttype 9000})}",
            )

          // Act
          let oids = collect_catalog_oids(query)

          // Assert
          CatalogOids(
            relations: sort(oids.relations, compare),
            functions: sort(oids.functions, compare),
            types: sort(oids.types, compare),
          )
          |> should
          |> be_equal(
            CatalogOids(relations: [10, 11], functions: [67, 2803], types: [
              25,
              9000,
            ]),
          )
          |> or_fail_with("Expected the oids")
        },
      ),
    ]),
  ])
}

fn parse(text: String) -> Node {
  node.parse(text) |> unwrap(Empty)
}

/// A SELECT of column 1 of the first range entry.
fn query_over(entry: String) -> Node {
  parse(
    "{QUERY :commandType 1 :setOperations <> :rtable ("
    <> entry
    <> ") :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :varlevelsup 0 :varnullingrels (b)} :resno 1 :resjunk false})}",
  )
}

fn trace_case(name: String, query: Node, expected: Traced) {
  it(name, fn() {
    // Arrange
    let empty = new(16)

    // Act
    let traced = trace_output_columns(query, 1, empty)

    // Assert
    traced
    |> should
    |> be_equal([expected])
    |> or_fail_with("Expected " <> name <> " to be Option")
  })
}
