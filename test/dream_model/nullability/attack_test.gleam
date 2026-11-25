//// The attack tests of the proof of concept, ported, and the attacks on
//// the computed values that are never NULL.
////
//// Each attack has two tests on each PostgreSQL version:
////
//// 1. The analysis: each column's NULL decision, origin and reason, and
////    each parameter's decision and reason, or the refusal.
//// 2. The data: the query runs on each data set, inside a transaction that
////    is rolled back. A column typed never NULL must never return NULL,
////    and every `Option` parameter must accept NULL.
////
//// The expectations are the proof of concept's output (attack16.txt to
//// attack19.txt), except where never-NULL computed values change them.

import dream_model/nullability.{type AnalysisError}
import dream_model/nullability/reason.{
  type ColumnReason, type Origin, type ParameterReason, Computed, Table,
}
import dream_model/postgres/wire
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/attack_database
import fixtures/harness.{type Outcome, PromiseEnforced, Sound}
import fixtures/servers
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// What the analysis must give.
pub type Expected {
  Decided(
    columns: List(#(String, Bool, Origin, ColumnReason)),
    parameters: List(#(Int, Bool, ParameterReason)),
  )
  Refused(error: AnalysisError)
}

/// One attack.
pub type Attack {
  Attack(
    name: String,
    minimum_version: Int,
    sql: String,
    expected: Expected,
    parameter_sets: Option(List(List(Option(String)))),
    outcome: Outcome,
  )
}

/// The attack tests on one PostgreSQL version.
pub fn tests(version: Int) -> TestSuite {
  describe(
    "attacks on PostgreSQL " <> int.to_string(version),
    attacks(version)
      |> list.filter(fn(attack) { version >= attack.minimum_version })
      |> list.map(attack_tests(version, _)),
  )
}

fn attack_tests(version: Int, attack: Attack) -> unit.UnitNode {
  let analysis_test =
    it("analysis matches the expected decisions", fn() {
      // Arrange
      let analyzer = connect(version)

      // Act
      let analyzed = nullability.analyze(analyzer, attack.sql)
      let _ = nullability.close(analyzer)

      // Assert
      summarize(analyzed)
      |> should
      |> be_equal(attack.expected)
      |> or_fail_with(
        "Expected the decisions of attack '" <> attack.name <> "'",
      )
    })
  let data_test =
    it("data never contradicts the analysis", fn() {
      // Arrange
      let analyzer = connect(version)
      let assert Ok(#(analysis, _)) = nullability.analyze(analyzer, attack.sql)
      let _ = nullability.close(analyzer)
      let connection = servers.connect(version, attack_database.database)

      // Act
      let outcome =
        harness.check(
          connection,
          analysis,
          attack.name,
          attack.sql,
          attack_database.data_sets_for(version),
          attack.parameter_sets,
          attack_database.reset,
        )
      let _ = wire.close(connection)

      // Assert
      outcome
      |> should
      |> be_equal(attack.outcome)
      |> or_fail_with(
        "Expected the data checks of attack '" <> attack.name <> "' to pass",
      )
    })
  case attack.expected {
    Decided(..) -> group(attack.name, [analysis_test, data_test])
    Refused(_) -> group(attack.name, [analysis_test])
  }
}

fn connect(version: Int) -> nullability.Analyzer {
  let assert Ok(analyzer) =
    nullability.connect(servers.url(version, attack_database.database))
  analyzer
}

fn summarize(
  analyzed: Result(#(nullability.Analysis, nullability.Analyzer), AnalysisError),
) -> Expected {
  case analyzed {
    Ok(#(analysis, _)) ->
      Decided(
        columns: list.map(analysis.columns, fn(column) {
          #(column.name, column.not_null, column.origin, column.reason)
        }),
        parameters: list.map(analysis.parameters, fn(parameter) {
          #(parameter.position, parameter.optional, parameter.reason)
        }),
      )
    Error(error) -> Refused(error)
  }
}

fn column(
  name: String,
  not_null: Bool,
  origin: Origin,
  why: ColumnReason,
) -> #(String, Bool, Origin, ColumnReason) {
  #(name, not_null, origin, why)
}

fn parameter(
  position: Int,
  optional: Bool,
  why: ParameterReason,
) -> #(Int, Bool, ParameterReason) {
  #(position, optional, why)
}

/// Every attack, with the expectations for one version. On 16 and 17 a
/// grouping set shows as `GroupingSet`; on 18 and newer PostgreSQL marks
/// it like an outer join.
pub fn attacks(version: Int) -> List(Attack) {
  let grouping = case version >= 18 {
    True -> reason.OuterJoinOrGroupingSet
    False -> reason.GroupingSet
  }
  list.append(proof_of_concept_attacks(grouping), computed_attacks(grouping))
}

/// The 118 attacks of the proof of concept.
fn proof_of_concept_attacks(grouping: ColumnReason) -> List(Attack) {
  [
    Attack(
      name: "left join",
      minimum_version: 16,
      sql: "select u.email, p.title from users u left join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "right join",
      minimum_version: 16,
      sql: "select u.email, p.title from users u right join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.OuterJoinOrGroupingSet),
          column("title", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "full join",
      minimum_version: 16,
      sql: "select u.email, p.title from users u full join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.OuterJoinOrGroupingSet),
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "full join using, merged column",
      minimum_version: 16,
      sql: "select id from users full join (select user_id as id, title from posts) p using (id)",
      expected: Decided(
        columns: [
          column("id", False, Computed, reason.ComputedValue("coalesceexpr")),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "inner join using, merged column",
      minimum_version: 16,
      sql: "select id, email from users join (select user_id as id from posts) p using (id)",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "right join using, merged column",
      minimum_version: 16,
      sql: "select id from users right join (select user_id as id from posts) p using (id)",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "natural left join",
      minimum_version: 16,
      sql: "select title from users natural left join (select user_id as id, title from posts) p",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join, inner join inside right side",
      minimum_version: 16,
      sql: "select p.title, t.tag from users u left join (posts p join tags t on t.post_id = p.id) on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
          column("tag", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "inner join, left join inside",
      minimum_version: 16,
      sql: "select p.title, t.tag from users u join (posts p left join tags t on t.post_id = p.id) on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("title", True, Table, reason.NotNullInSchema),
          column("tag", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join to subquery with inner join",
      minimum_version: 16,
      sql: "select x.title, x.tag from users u left join (select p.user_id, p.title, t.tag from posts p join tags t on t.post_id = p.id) x on x.user_id = u.id",
      expected: Decided(
        columns: [
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
          column("tag", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join lateral",
      minimum_version: 16,
      sql: "select x.title from users u left join lateral (select title from posts p where p.user_id = u.id limit 1) x on true",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cross join lateral, inner",
      minimum_version: 16,
      sql: "select x.title from users u cross join lateral (select title from posts p where p.user_id = u.id) x",
      expected: Decided(
        columns: [column("title", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "lateral reads a left-joined column",
      minimum_version: 16,
      sql: "select x.t from users u left join posts p on p.user_id = u.id cross join lateral (select p.title as t) x",
      expected: Decided(
        columns: [column("t", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "lateral reads left-joined column through function",
      minimum_version: 16,
      sql: "select x.t from users u left join posts p on p.user_id = u.id cross join lateral (select p.title as t offset 0) x",
      expected: Decided(
        columns: [column("t", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join, WHERE makes it inner",
      minimum_version: 16,
      sql: "select p.title from users u left join posts p on p.user_id = u.id where p.title = 'p1'",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join, IS NOT NULL filter",
      minimum_version: 16,
      sql: "select p.title from users u left join posts p on p.user_id = u.id where p.id is not null",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "join alias over left join",
      minimum_version: 16,
      sql: "select j.title from (users u left join posts p on p.user_id = u.id) j",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "join alias with column aliases",
      minimum_version: 16,
      sql: "select j.c from (users u left join (select user_id, title from posts) p(uid, c) on p.uid = u.id) j",
      expected: Decided(
        columns: [column("c", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "chain of left joins",
      minimum_version: 16,
      sql: "select u.email, p.title, t.tag from users u left join posts p on p.user_id = u.id left join tags t on t.post_id = p.id",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
          column("tag", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join nested on left",
      minimum_version: 16,
      sql: "select t.tag from (posts p left join tags t on t.post_id = p.id) left join users u on u.id = p.user_id",
      expected: Decided(
        columns: [column("tag", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "self join",
      minimum_version: 16,
      sql: "select a.email, b.email as other from users a left join users b on b.id = a.id + 100",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("other", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "star over right join",
      minimum_version: 16,
      sql: "select u.* from users u right join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [
          column("id", False, Table, reason.OuterJoinOrGroupingSet),
          column("email", False, Table, reason.OuterJoinOrGroupingSet),
          column("nickname", False, Table, reason.OuterJoinOrGroupingSet),
          column("created_at", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "distinct on with left join",
      minimum_version: 16,
      sql: "select distinct on (u.id) u.id, p.title from users u left join posts p on p.user_id = u.id order by u.id, p.id",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("title", False, Table, reason.OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "group by right-side column",
      minimum_version: 16,
      sql: "select p.title from users u left join posts p on p.user_id = u.id group by p.title",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join in where-exists subquery only",
      minimum_version: 16,
      sql: "select u.email from users u where exists (select 1 from posts p left join tags t on t.post_id = p.id where p.user_id = u.id)",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "correlated scalar subquery over left join",
      minimum_version: 16,
      sql: "select (select p.title) as t from users u left join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [column("t", False, Computed, reason.ComputedValue("sublink"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "left join anti-join pattern",
      minimum_version: 16,
      sql: "select u.email from users u left join posts p on p.user_id = u.id where p.id is null",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cte",
      minimum_version: 16,
      sql: "with t as (select id, email from users) select email from t",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cte with left join",
      minimum_version: 16,
      sql: "with t as (select u.id, p.title from users u left join posts p on p.user_id = u.id) select title from t",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cte on nullable side",
      minimum_version: 16,
      sql: "with t as (select user_id, title from posts) select t.title from users u left join t on t.user_id = u.id",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cte materialized",
      minimum_version: 16,
      sql: "with t as materialized (select email from users) select email from t",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "nested cte, outer reference",
      minimum_version: 16,
      sql: "with a as (select id, email from users) select x.email from (with b as (select * from a) select email from b) x",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "data-modifying cte insert",
      minimum_version: 16,
      sql: "with ins as (insert into users (id, email) values (50, 'n@x') returning id, email, nickname) select * from ins",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
          column("nickname", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "data-modifying cte delete",
      minimum_version: 16,
      sql: "with del as (delete from posts returning title, body) select title, body from del",
      expected: Decided(
        columns: [
          column("title", True, Table, reason.NotNullInSchema),
          column("body", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "recursive cte",
      minimum_version: 16,
      sql: "with recursive r(n, e) as (select id, email from users union all select n + 1, e from r where n < 3) select e from r",
      expected: Decided(
        columns: [column("e", False, Computed, reason.RecursiveCte)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "subquery limit 0",
      minimum_version: 16,
      sql: "select s.email from (select email from users limit 0) s",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "subquery offset",
      minimum_version: 16,
      sql: "select s.email from (select email from users offset 1) s",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "subquery with window",
      minimum_version: 16,
      sql: "select s.email from (select email, row_number() over () from users) s",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "scalar subquery of not-null column",
      minimum_version: 16,
      sql: "select (select email from users where id = 99) as e",
      expected: Decided(
        columns: [column("e", False, Computed, reason.ComputedValue("sublink"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "values",
      minimum_version: 16,
      sql: "select v.a from (values (1), (null)) v(a)",
      expected: Decided(
        columns: [column("a", False, Computed, reason.RangeResult("values"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "union all not null",
      minimum_version: 16,
      sql: "select email as x from users union all select title from posts",
      expected: Decided(
        columns: [column("x", True, Table, reason.NotNullInEveryBranch)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "union with nullable arm",
      minimum_version: 16,
      sql: "select email as x from users union all select body from posts",
      expected: Decided(
        columns: [column("x", False, Table, reason.ColumnAllowsNull)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "intersect",
      minimum_version: 16,
      sql: "select email as x from users intersect select title from posts",
      expected: Decided(
        columns: [column("x", True, Table, reason.NotNullInEveryBranch)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "except",
      minimum_version: 16,
      sql: "select email as x from users except select body from posts",
      expected: Decided(
        columns: [column("x", False, Table, reason.ColumnAllowsNull)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "union of left join",
      minimum_version: 16,
      sql: "select email as x from users union all select p.title from users u left join posts p on p.user_id = u.id",
      expected: Decided(
        columns: [column("x", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    // Changed from the proof of concept: the constant 'z' is never NULL, so
    // every branch is never NULL.
    Attack(
      name: "nested set ops",
      minimum_version: 16,
      sql: "(select email as x from users union select title from posts) except select 'z'",
      expected: Decided(
        columns: [column("x", True, Computed, reason.NotNullInEveryBranch)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "union in subquery",
      minimum_version: 16,
      sql: "select s.x from (select email as x from users union all select title from posts) s",
      expected: Decided(
        columns: [column("x", True, Table, reason.NotNullInEveryBranch)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "union with null literal",
      minimum_version: 16,
      sql: "select email as x from users union all select null",
      expected: Decided(
        columns: [column("x", False, Computed, reason.ComputedValue("const"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    // Changed from the proof of concept: count is never NULL by rule.
    Attack(
      name: "group by",
      minimum_version: 16,
      sql: "select email, count(*) from users group by email",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("count", True, Computed, reason.CountAggregate),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "rollup",
      minimum_version: 16,
      sql: "select email from users group by rollup (email)",
      expected: Decided(
        columns: [column("email", False, Table, grouping)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "cube",
      minimum_version: 16,
      sql: "select email, nickname from users group by cube (email, nickname)",
      expected: Decided(
        columns: [
          column("email", False, Table, grouping),
          column("nickname", False, Table, grouping),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "grouping sets",
      minimum_version: 16,
      sql: "select email from users group by grouping sets ((email), ())",
      expected: Decided(
        columns: [column("email", False, Table, grouping)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    // Changed from the proof of concept: count is never NULL by rule.
    Attack(
      name: "group by ()",
      minimum_version: 16,
      sql: "select count(*) from users group by ()",
      expected: Decided(
        columns: [column("count", True, Computed, reason.CountAggregate)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "rollup in subquery",
      minimum_version: 16,
      sql: "select s.email from (select email from users group by rollup (email)) s",
      expected: Decided(
        columns: [column("email", False, Table, grouping)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "having",
      minimum_version: 16,
      sql: "select email from users group by email having count(*) > 0",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "distinct",
      minimum_version: 16,
      sql: "select distinct email from users",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "group by on primary key, other column",
      minimum_version: 16,
      sql: "select u.id, u.email from users u group by u.id",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view",
      minimum_version: 16,
      sql: "select email from v_inner",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view with left join",
      minimum_version: 16,
      sql: "select title from v_user_posts",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view of view",
      minimum_version: 16,
      sql: "select title from v_of_view",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view left joined",
      minimum_version: 16,
      sql: "select v.title from posts p left join v_inner v on v.id = p.user_id",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view with union",
      minimum_version: 16,
      sql: "select v from v_union",
      expected: Decided(
        columns: [column("v", True, Table, reason.NotNullInEveryBranch)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "view computed column",
      minimum_version: 16,
      sql: "select low from v_computed",
      expected: Decided(
        columns: [
          column("low", False, Computed, reason.ComputedValue("funcexpr")),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "security barrier view",
      minimum_version: 16,
      sql: "select email from v_secure",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "materialized view",
      minimum_version: 16,
      sql: "select email from mv_users",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.RelationKindWithoutNotNull("m")),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "inheritance parent",
      minimum_version: 16,
      sql: "select name from animals",
      expected: Decided(
        columns: [column("name", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "inheritance only",
      minimum_version: 16,
      sql: "select name from only animals",
      expected: Decided(
        columns: [column("name", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "partitioned table",
      minimum_version: 16,
      sql: "select kind, payload from events",
      expected: Decided(
        columns: [
          column("kind", True, Table, reason.NotNullInSchema),
          column("payload", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "partition read directly",
      minimum_version: 16,
      sql: "select payload from events_b",
      expected: Decided(
        columns: [column("payload", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "domain not null column",
      minimum_version: 16,
      sql: "select email from contacts",
      expected: Decided(
        columns: [column("email", False, Table, reason.ColumnAllowsNull)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "generated stored not null",
      minimum_version: 16,
      sql: "select b from generated_t",
      expected: Decided(
        columns: [column("b", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "NOT NULL NO INHERIT parent, nullable child",
      minimum_version: 18,
      sql: "select label from things",
      expected: Decided(
        columns: [column("label", False, Table, reason.ChildTableAllowsNull)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "NOT NULL NOT VALID with old NULL rows",
      minimum_version: 18,
      sql: "select code from legacy",
      expected: Decided(
        columns: [column("code", False, Table, reason.NotNullNotValid)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "virtual generated not null",
      minimum_version: 18,
      sql: "select b from virt",
      expected: Decided(
        columns: [column("b", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "insert returning",
      minimum_version: 16,
      sql: "insert into users (id, email) values (60, 'r@x') returning id, email, nickname",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
          column("nickname", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "insert on conflict do nothing returning",
      minimum_version: 16,
      sql: "insert into users (id, email) values (1, 'r@x') on conflict do nothing returning email",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "insert on conflict do update returning",
      minimum_version: 16,
      sql: "insert into users (id, email) values (1, 'r@x') on conflict (id) do update set nickname = null returning email, nickname",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("nickname", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "insert select from left join returning",
      minimum_version: 16,
      sql: "insert into posts (id, user_id, title, body) select 100 + u.id, u.id, 'x', p.body from users u left join posts p on p.user_id = u.id returning title, body",
      expected: Decided(
        columns: [
          column("title", True, Table, reason.NotNullInSchema),
          column("body", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "update from returning other table",
      minimum_version: 16,
      sql: "update users u set nickname = 'z' from posts p where p.user_id = u.id returning u.email, p.title",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("title", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "update from left join returning",
      minimum_version: 16,
      sql: "update users u set nickname = 'z' from users u2 left join posts p on p.user_id = u2.id where u2.id = u.id returning p.title",
      expected: Decided(
        columns: [column("title", False, Table, reason.OuterJoinOrGroupingSet)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "delete using returning",
      minimum_version: 16,
      sql: "delete from posts p using users u where u.id = p.user_id returning p.title, u.email",
      expected: Decided(
        columns: [
          column("title", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "insert into view returning",
      minimum_version: 16,
      sql: "insert into v_updatable (id, email) values (70, 'v@x') returning email, nickname",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("nickname", False, Table, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "returning old on insert",
      minimum_version: 18,
      sql: "insert into users (id, email) values (61, 'o@x') returning old.email, new.email",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.ReturningOldNew),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "returning new on delete",
      minimum_version: 18,
      sql: "delete from users where id = 1 returning new.email, old.email",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.ReturningOldNew),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "returning old on update",
      minimum_version: 18,
      sql: "update users set nickname = 'q' returning old.email, new.email",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "returning old on upsert",
      minimum_version: 18,
      sql: "insert into users (id, email) values (1, 'u@x'), (80, 'w@x') on conflict (id) do update set nickname = 'k' returning old.email, new.email",
      expected: Decided(
        columns: [
          column("email", False, Table, reason.ReturningOldNew),
          column("email", False, Table, reason.ReturningOldNew),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "merge returning",
      minimum_version: 17,
      sql: "merge into users u using posts p on p.user_id = u.id when matched then update set nickname = 'm' when not matched then insert (id, email) values (p.id + 500, 'm@x') returning u.email, p.title",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("title", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "merge not matched by source returning source",
      minimum_version: 17,
      sql: "merge into users u using posts p on p.user_id = u.id when not matched by source then delete when matched then do nothing returning u.email, p.title",
      expected: Decided(
        columns: [
          column("email", True, Table, reason.NotNullInSchema),
          column("title", False, Table, reason.MergeNotMatchedBySource),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "merge returning merge_action",
      minimum_version: 17,
      sql: "merge into users u using posts p on p.user_id = u.id when matched then update set nickname = 'm' returning merge_action(), u.email",
      expected: Decided(
        columns: [
          column(
            "merge_action",
            False,
            Computed,
            reason.ComputedValue("mergesupportfunc"),
          ),
          column("email", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "weird names",
      minimum_version: 16,
      sql: "select * from \"Weird Table\"",
      expected: Decided(
        columns: [
          column("Weird Name", True, Table, reason.NotNullInSchema),
          column("with\"quote", True, Table, reason.NotNullInSchema),
          column("a(b)", True, Table, reason.NotNullInSchema),
          column("x:y{z}", True, Table, reason.NotNullInSchema),
          column("ñame", False, Table, reason.ColumnAllowsNull),
          column("select", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "whole row",
      minimum_version: 16,
      sql: "select u from users u",
      expected: Decided(
        columns: [column("u", False, Computed, reason.WholeRow)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "system column",
      minimum_version: 16,
      sql: "select ctid, xmin from users",
      expected: Decided(
        columns: [
          column("ctid", True, Table, reason.SystemColumn),
          column("xmin", True, Table, reason.SystemColumn),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "table function",
      minimum_version: 16,
      sql: "select g from generate_series(1, 3) g",
      expected: Decided(
        columns: [column("g", False, Computed, reason.RangeResult("function"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "unnest",
      minimum_version: 16,
      sql: "select x from unnest(array[1, null]) x",
      expected: Decided(
        columns: [column("x", False, Computed, reason.RangeResult("function"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "binary-compatible cast",
      minimum_version: 16,
      sql: "select email::varchar as e from users",
      expected: Decided(
        columns: [column("e", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "collate",
      minimum_version: 16,
      sql: "select email collate \"C\" as e from users",
      expected: Decided(
        columns: [column("e", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "real cast",
      minimum_version: 16,
      sql: "select id::bigint as b from users",
      expected: Decided(
        columns: [
          column("b", False, Computed, reason.ComputedValue("funcexpr")),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "null literal",
      minimum_version: 16,
      sql: "select null::int as x",
      expected: Decided(
        columns: [column("x", False, Computed, reason.ComputedValue("const"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "parameter echo",
      minimum_version: 16,
      sql: "select $1::int as x",
      expected: Decided(
        columns: [column("x", False, Computed, reason.ComputedValue("param"))],
        parameters: [parameter(1, False, reason.Required)],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "TABLE command",
      minimum_version: 16,
      sql: "table users",
      expected: Decided(
        columns: [
          column("id", True, Table, reason.NotNullInSchema),
          column("email", True, Table, reason.NotNullInSchema),
          column("nickname", False, Table, reason.ColumnAllowsNull),
          column("created_at", True, Table, reason.NotNullInSchema),
        ],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "zero columns",
      minimum_version: 16,
      sql: "select from users",
      expected: Decided(columns: [], parameters: []),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "for update",
      minimum_version: 16,
      sql: "select email from users for update",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "order limit",
      minimum_version: 16,
      sql: "select email from users order by email limit 1",
      expected: Decided(
        columns: [column("email", True, Table, reason.NotNullInSchema)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "json_table",
      minimum_version: 17,
      sql: "select jt.a from json_table('[{\"a\":1},{}]', '$[*]' columns (a int path '$.a')) jt",
      expected: Decided(
        columns: [column("a", False, Computed, reason.RangeResult("tablefunc"))],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    // Changed from the proof of concept: count is never NULL by rule, so the
    // hint is not needed and is refused.
    Attack(
      name: "hint on computed",
      minimum_version: 16,
      sql: "-- not null: n\nselect count(*) as n from users",
      expected: Refused(
        nullability.HintsRefused([
          nullability.HintNotNeeded("n", reason.CountAggregate),
        ]),
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "hint broken at run time",
      minimum_version: 16,
      sql: "-- not null: newest\nselect max(id) as newest from posts",
      expected: Decided(
        columns: [column("newest", True, Computed, reason.NotNullHint)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: PromiseEnforced(
        "hint broken at run time: the SQL file promised 'newest' is never NULL, and PostgreSQL returned NULL (data: empty)",
      ),
    ),
    Attack(
      name: "hint on table column (must be refused)",
      minimum_version: 16,
      sql: "-- not null: email\nselect email from users",
      expected: Refused(
        nullability.HintsRefused([
          nullability.HintNamesTableColumn("email", reason.NotNullInSchema),
        ]),
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "hint on outer-joined table column (must be refused)",
      minimum_version: 16,
      sql: "-- not null: title\nselect p.title from users u left join posts p on p.user_id = u.id",
      expected: Refused(
        nullability.HintsRefused([
          nullability.HintNamesTableColumn(
            "title",
            reason.OuterJoinOrGroupingSet,
          ),
        ]),
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "hint on unknown column (must be refused)",
      minimum_version: 16,
      sql: "-- not null: nope\nselect email from users",
      expected: Refused(
        nullability.HintsRefused([nullability.HintNamesUnknownColumn("nope")]),
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "nullable hint",
      minimum_version: 16,
      sql: "-- nullable: email\nselect email from users",
      expected: Decided(
        columns: [column("email", False, Table, reason.NullableHint)],
        parameters: [],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "param into nullable column",
      minimum_version: 16,
      sql: "insert into users (id, email, nickname) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.BeforeTrigger),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("p@x"), Some("nick")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param into domain not null column",
      minimum_version: 16,
      sql: "insert into contacts (id, email, note) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.DomainNotNull),
          parameter(3, True, reason.StoredIntoNullableColumn),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("p@x"), Some("n")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param into column with CHECK",
      minimum_version: 16,
      sql: "insert into checked (id, code, other) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.CheckConstraint),
          parameter(3, False, reason.CheckConstraint),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("c"), Some("o")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param in upsert set",
      minimum_version: 16,
      sql: "insert into users (id, email) values ($1, $2) on conflict (id) do update set nickname = $3 returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.BeforeTrigger),
        ],
      ),
      parameter_sets: Some([[Some("1"), Some("p@x"), Some("n")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param in update coalesce",
      minimum_version: 16,
      sql: "update users set nickname = coalesce($2, nickname) where id = $1 returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.Required),
          parameter(2, False, reason.Required),
        ],
      ),
      parameter_sets: Some([[Some("1"), Some("n")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param into partitioned table, stricter partition",
      minimum_version: 16,
      sql: "insert into events (id, kind, payload) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.PartitionNotNull),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("b"), Some("x")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param into view",
      minimum_version: 16,
      sql: "insert into v_updatable (id, email, nickname) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.BeforeTrigger),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("p@x"), Some("n")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param rejected by trigger",
      minimum_version: 16,
      sql: "insert into users (id, email, nickname) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.BeforeTrigger),
        ],
      ),
      parameter_sets: Some([
        [Some("300"), Some("trigger@example.com"), Some("n")],
      ]),
      outcome: Sound,
    ),
  ]
}

fn decided(columns: List(#(String, Bool, Origin, ColumnReason))) -> Expected {
  Decided(columns:, parameters: [])
}

fn attack(name: String, sql: String, expected: Expected) -> Attack {
  Attack(
    name:,
    minimum_version: 16,
    sql:,
    expected:,
    parameter_sets: None,
    outcome: Sound,
  )
}

/// The attacks on the computed values that are never NULL: count,
/// constants, coalesce, EXISTS, IS NULL and IS DISTINCT FROM, on the
/// nullable side of outer joins, in grouping sets and in set operations.
fn computed_attacks(grouping: ColumnReason) -> List(Attack) {
  [
    attack(
      "count star",
      "select count(*) as n from users",
      decided([column("n", True, Computed, reason.CountAggregate)]),
    ),
    attack(
      "count of a nullable expression",
      "select count(length(nickname)) as n from users",
      decided([column("n", True, Computed, reason.CountAggregate)]),
    ),
    attack(
      "count with a filter",
      "select count(*) filter (where nickname is null) as n from users",
      decided([column("n", True, Computed, reason.CountAggregate)]),
    ),
    attack(
      "count as a window function",
      "select count(*) over () as n from users",
      decided([column("n", False, Computed, reason.ComputedValue("windowfunc"))]),
    ),
    attack(
      "aggregate named count outside pg_catalog",
      "select public.count(email) as n from users",
      decided([column("n", False, Computed, reason.ComputedValue("aggref"))]),
    ),
    attack(
      "count in a left-joined subquery",
      "select x.n from users u left join (select user_id, count(*) as n from posts group by user_id) x on x.user_id = u.id",
      decided([column("n", False, Computed, reason.OuterJoinOrGroupingSet)]),
    ),
    attack(
      "scalar subquery of count",
      "select (select count(*) from posts) as n",
      decided([column("n", False, Computed, reason.ComputedValue("sublink"))]),
    ),
    attack(
      "constants",
      "select 1 as k, 'x' as s, 'y'::varchar as v, true as b from users",
      decided([
        column("k", True, Computed, reason.NonNullConstant),
        column("s", True, Computed, reason.NonNullConstant),
        column("v", True, Computed, reason.NonNullConstant),
        column("b", True, Computed, reason.NonNullConstant),
      ]),
    ),
    attack(
      "constant in an inner-joined subquery",
      "select x.k from users u join (select 1 as k) x on true",
      decided([column("k", True, Computed, reason.NonNullConstant)]),
    ),
    attack(
      "constant in a left-joined subquery",
      "select x.k from users u left join (select 1 as k) x on u.nickname = 'zz'",
      decided([column("k", False, Computed, reason.OuterJoinOrGroupingSet)]),
    ),
    attack(
      "constant in a left-joined CTE",
      "with c as (select 1 as k) select c.k from users u left join c on u.nickname = 'zz'",
      decided([column("k", False, Computed, reason.OuterJoinOrGroupingSet)]),
    ),
    attack(
      "constant through a join alias",
      "select j.k from (users u left join (select 1 as k) x on u.nickname = 'zz') j",
      decided([column("k", False, Computed, reason.OuterJoinOrGroupingSet)]),
    ),
    attack(
      "constant in a left join lateral",
      "select x.k from users u left join lateral (select 1 as k where u.nickname = 'zz') x on true",
      decided([column("k", False, Computed, reason.OuterJoinOrGroupingSet)]),
    ),
    attack(
      "constants in VALUES",
      "select v.a from (values (1), (2)) v(a)",
      decided([column("a", False, Computed, reason.RangeResult("values"))]),
    ),
    attack(
      "coalesce with a constant last",
      "select coalesce(nickname, 'none') as n from users",
      decided([
        column("n", True, Computed, reason.CoalesceWithNonNullLastArgument),
      ]),
    ),
    attack(
      "coalesce with a not-null column last",
      "select coalesce(nickname, email) as n from users",
      decided([
        column("n", True, Computed, reason.CoalesceWithNonNullLastArgument),
      ]),
    ),
    attack(
      "coalesce with a nullable last argument",
      "select coalesce(email, nickname) as n from users",
      decided([
        column("n", False, Computed, reason.ComputedValue("coalesceexpr")),
      ]),
    ),
    attack(
      "coalesce with an outer-joined last argument",
      "select coalesce(p.body, p.title) as n from users u left join posts p on p.user_id = u.id",
      decided([
        column("n", False, Computed, reason.ComputedValue("coalesceexpr")),
      ]),
    ),
    attack(
      "nested coalesce",
      "select coalesce(nickname, coalesce(nickname, 'x')) as n from users",
      decided([
        column("n", True, Computed, reason.CoalesceWithNonNullLastArgument),
      ]),
    ),
    attack(
      "coalesce with a NULL constant last",
      "select coalesce(nickname, null) as n from users",
      decided([
        column("n", False, Computed, reason.ComputedValue("coalesceexpr")),
      ]),
    ),
    attack(
      "exists",
      "select exists (select 1 from posts p where p.user_id = u.id) as e from users u",
      decided([column("e", True, Computed, reason.ExistsSubquery)]),
    ),
    attack(
      "not exists",
      "select not exists (select 1 from posts p where p.user_id = u.id) as e from users u",
      decided([column("e", False, Computed, reason.ComputedValue("boolexpr"))]),
    ),
    attack(
      "in subquery",
      "select u.id in (select p.user_id from posts p) as e from users u",
      decided([column("e", False, Computed, reason.ComputedValue("sublink"))]),
    ),
    attack(
      "is null and is not null",
      "select nickname is null as a, nickname is not null as b from users",
      decided([
        column("a", True, Computed, reason.NullTest),
        column("b", True, Computed, reason.NullTest),
      ]),
    ),
    attack(
      "is null on an outer-joined column",
      "select p.body is null as a from users u left join posts p on p.user_id = u.id",
      decided([column("a", True, Computed, reason.NullTest)]),
    ),
    attack(
      "is distinct from",
      "select nickname is distinct from 'x' as d from users",
      decided([column("d", True, Computed, reason.DistinctFrom)]),
    ),
    attack(
      "is not distinct from",
      "select nickname is not distinct from 'x' as d from users",
      decided([column("d", False, Computed, reason.ComputedValue("boolexpr"))]),
    ),
    attack(
      "is distinct from with an operator that returns NULL",
      "select 'happy'::mood is distinct from 'sad'::mood as d",
      decided([
        column("d", False, Computed, reason.ComputedValue("distinctexpr")),
      ]),
    ),
    attack(
      "constant grouped by rollup",
      "select 1 as k, count(*) as n from users group by rollup (1)",
      decided([
        column("k", False, Computed, grouping),
        column("n", True, Computed, reason.CountAggregate),
      ]),
    ),
    attack(
      "coalesce grouped by rollup",
      "select coalesce(nickname, 'x') as n from users group by rollup (coalesce(nickname, 'x'))",
      decided([column("n", False, Computed, grouping)]),
    ),
    attack(
      "constant equal to a grouping expression",
      "select 1 as a, 1 as b from users group by rollup (1)",
      decided([
        column("a", False, Computed, grouping),
        column("b", False, Computed, grouping),
      ]),
    ),
    attack(
      "constant not grouped, with rollup",
      "select 2 as k, email from users group by rollup (email)",
      decided([
        column("k", True, Computed, reason.NonNullConstant),
        column("email", False, Table, grouping),
      ]),
    ),
    attack(
      "coalesce over a grouped column",
      "select coalesce(nickname, 'x') as n from users group by rollup (nickname)",
      decided([
        column("n", True, Computed, reason.CoalesceWithNonNullLastArgument),
      ]),
    ),
    attack(
      "coalesce whose last argument is grouped",
      "select coalesce(null::boolean, nickname is null) as n from users group by rollup (nickname is null)",
      decided([
        column("n", False, Computed, reason.ComputedValue("coalesceexpr")),
      ]),
    ),
    attack(
      "is null grouped by rollup",
      "select nickname is null as a from users group by rollup (nickname is null)",
      decided([column("a", False, Computed, grouping)]),
    ),
    attack(
      "count of a text column resolves to the aggregate outside pg_catalog",
      "select count(nickname) as n from users",
      decided([column("n", False, Computed, reason.ComputedValue("aggref"))]),
    ),
    attack(
      "coalesce whose last argument equals a grouped constant",
      "select 1 as k, coalesce(null::int, 1) as c from users group by rollup (1)",
      decided([
        column("k", False, Computed, grouping),
        column("c", False, Computed, reason.ComputedValue("coalesceexpr")),
      ]),
    ),
    attack(
      "constant grouped by rollup in a subquery",
      "select s.k from (select 1 as k from users group by rollup (1)) s",
      decided([column("k", False, Computed, grouping)]),
    ),
    attack(
      "cast of coalesce grouped by rollup",
      "select coalesce(nickname, 'x')::varchar as n from users group by rollup (coalesce(nickname, 'x')::varchar)",
      decided([column("n", False, Computed, grouping)]),
    ),
    attack(
      "union with a nullable first arm",
      "select body as x from posts union all select email from users",
      decided([column("x", False, Table, reason.ColumnAllowsNull)]),
    ),
    Attack(
      name: "param into domain columns",
      minimum_version: 16,
      sql: "insert into domain_targets (id, checked, plain) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.DomainCheck),
          parameter(3, True, reason.StoredIntoNullableColumn),
        ],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "param into a table with row-level security",
      minimum_version: 16,
      sql: "insert into secured (id, note) values ($1, $2) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.RowLevelSecurity),
        ],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "param into a partition with a CHECK",
      minimum_version: 16,
      sql: "insert into measures (id, kind, value) values ($1, $2, $3) returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [
          parameter(1, False, reason.ColumnIsNotNull),
          parameter(2, False, reason.ColumnIsNotNull),
          parameter(3, False, reason.PartitionCheck),
        ],
      ),
      parameter_sets: Some([[Some("300"), Some("a"), Some("x")]]),
      outcome: Sound,
    ),
    Attack(
      name: "param stored and compared",
      minimum_version: 16,
      sql: "update users set nickname = $1 where nickname = $1 returning id",
      expected: Decided(
        columns: [column("id", True, Table, reason.NotNullInSchema)],
        parameters: [parameter(1, False, reason.AlsoUsedOutsideStore)],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    Attack(
      name: "params hint",
      minimum_version: 16,
      sql: "-- params: x?\nselect $1::int as x",
      expected: Decided(
        columns: [column("x", False, Computed, reason.ComputedValue("param"))],
        parameters: [parameter(1, True, reason.ParamsHint)],
      ),
      parameter_sets: None,
      outcome: Sound,
    ),
    attack(
      "union of constants",
      "select 1 as k union all select 2",
      decided([column("k", True, Computed, reason.NotNullInEveryBranch)]),
    ),
    attack(
      "union of a constant and NULL",
      "select 1 as k union all select null",
      decided([column("k", False, Computed, reason.ComputedValue("const"))]),
    ),
    attack(
      "union of a constant and a table column",
      "select 'x' as v union all select email from users",
      decided([column("v", True, Computed, reason.NotNullInEveryBranch)]),
    ),
    attack(
      "hint on a constant (must be refused)",
      "-- not null: k\nselect 1 as k",
      Refused(
        nullability.HintsRefused([
          nullability.HintNotNeeded("k", reason.NonNullConstant),
        ]),
      ),
    ),
    attack(
      "hint on computed, not proven",
      "-- not null: low\nselect lower(email) as low from users",
      decided([column("low", True, Computed, reason.NotNullHint)]),
    ),
    attack(
      "nullable hint on a proven column",
      "-- nullable: n\nselect count(*) as n from users",
      decided([column("n", False, Computed, reason.NullableHint)]),
    ),
    attack(
      "weird result names",
      "select 1 as \":resno\", 2 as \"<>\", 3 as \"{\", 4 as \")\", 5 as \"a\\b\", 6 as \"x\ny\", 7 as \"(\"",
      decided([
        column(":resno", True, Computed, reason.NonNullConstant),
        column("<>", True, Computed, reason.NonNullConstant),
        column("{", True, Computed, reason.NonNullConstant),
        column(")", True, Computed, reason.NonNullConstant),
        column("a\\b", True, Computed, reason.NonNullConstant),
        column("x\ny", True, Computed, reason.NonNullConstant),
        column("(", True, Computed, reason.NonNullConstant),
      ]),
    ),
    attack(
      "CTE with a weird name",
      "with \"my {cte}\" as (select email from users) select email from \"my {cte}\"",
      decided([column("email", True, Table, reason.NotNullInSchema)]),
    ),
  ]
}
