//// Tests for `dream_model/nullability/rules` with trees written by hand:
//// shapes that PostgreSQL does not produce for valid SQL, where the rules
//// must still decide `Option`.

import dream_model/nullability/reason.{Computed, Table}
import dream_model/nullability/rules.{type Traced, CatalogOids, Traced}
import dream_model/postgres/catalog
import dream_model/postgres/node
import dream_model/postgres/wire
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/attack_database
import fixtures/servers
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/nullability/rules", [
    group("trace_output_columns", [
      trace_case(
        "a subquery column that the subquery does not hold",
        query_over(
          "{RANGETBLENTRY :rtekind 1 :subquery {QUERY :commandType 1 :targetList <>}}",
        ),
        Traced(False, Computed, reason.ColumnUntraceable),
      ),
      trace_case(
        "a relation that the catalog does not hold",
        query_over("{RANGETBLENTRY :rtekind 0 :relid 1 :inh false}"),
        Traced(False, Table, reason.ColumnNotFound),
      ),
      trace_case(
        "a join column that the join does not hold",
        query_over("{RANGETBLENTRY :rtekind 2 :joinaliasvars <>}"),
        Traced(False, Computed, reason.JoinColumnUntraceable),
      ),
      trace_case(
        "a CTE that the query does not hold",
        query_over("{RANGETBLENTRY :rtekind 6 :ctename x :ctelevelsup 0}"),
        Traced(False, Computed, reason.CteNotFound),
      ),
      trace_case(
        "a tuplestore range",
        query_over("{RANGETBLENTRY :rtekind 7}"),
        Traced(False, Computed, reason.RangeResult("tuplestore")),
      ),
      trace_case(
        "a result range",
        query_over("{RANGETBLENTRY :rtekind 8}"),
        Traced(False, Computed, reason.RangeResult("result")),
      ),
      trace_case(
        "a range kind that the rules do not know",
        query_over("{RANGETBLENTRY :rtekind 42}"),
        Traced(False, Computed, reason.RangeResult("unknown")),
      ),
      it("a column number that the table does not have", fn() {
        // Arrange
        let connection = servers.connect(version, attack_database.database)
        let assert Ok([[Some(oid)]]) =
          wire.simple_query(connection, "select 'users'::regclass::oid")
        let oid = int.parse(oid) |> result.unwrap(0)
        let assert Ok(loaded) =
          catalog.load(catalog.new(version), connection, [oid], [])
        let _ = wire.close(connection)
        let query =
          parse(
            "{QUERY :commandType 1 :rtable ({RANGETBLENTRY :rtekind 0 :relid "
            <> int.to_string(oid)
            <> " :inh false}) :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 99 :varlevelsup 0} :resno 1 :resjunk false})}",
          )

        // Act
        let traced = rules.trace_output_columns(query, 1, loaded)

        // Assert
        traced
        |> should
        |> be_equal([Traced(False, Table, reason.ColumnNotFound)])
        |> or_fail_with("Expected ColumnNotFound")
      }),
    ]),
    group("collect_catalog_oids", [
      it("collects relations, aggregates and operator functions once", fn() {
        // Arrange
        let query =
          parse(
            "{QUERY :rtable ({RANGETBLENTRY :rtekind 0 :relid 10} {RANGETBLENTRY :rtekind 1 :relid 11} {RANGETBLENTRY :rtekind 0 :relid 10}) :targetList ({AGGREF :aggfnoid 2803} {DISTINCTEXPR :opfuncid 67})}",
          )

        // Act
        let oids = rules.collect_catalog_oids(query)

        // Assert
        CatalogOids(
          relations: list.sort(oids.relations, int.compare),
          functions: list.sort(oids.functions, int.compare),
        )
        |> should
        |> be_equal(CatalogOids(relations: [10], functions: [67, 2803]))
        |> or_fail_with("Expected the oids")
      }),
    ]),
  ])
}

fn parse(text: String) -> node.Node {
  node.parse(text) |> result.unwrap(node.Empty)
}

/// A SELECT of column 1 of the first range entry.
fn query_over(entry: String) -> node.Node {
  parse(
    "{QUERY :commandType 1 :setOperations <> :rtable ("
    <> entry
    <> ") :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :varlevelsup 0 :varnullingrels (b)} :resno 1 :resjunk false})}",
  )
}

fn trace_case(name: String, query: node.Node, expected: Traced) {
  it(name, fn() {
    // Arrange
    let empty = catalog.new(16)

    // Act
    let traced = rules.trace_output_columns(query, 1, empty)

    // Assert
    traced
    |> should
    |> be_equal([expected])
    |> or_fail_with("Expected " <> name <> " to be Option")
  })
}
