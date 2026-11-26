//// Random queries for the fuzzer, ported from the proof of concept's
//// `fuzz.py`: SELECT statements up to 3 levels deep, with joins of every
//// kind, subqueries, LATERAL, CTEs, VALUES, set-returning functions,
//// grouping sets, set operations, DISTINCT and LIMIT; and about 15%
//// INSERT, UPDATE, DELETE and MERGE with RETURNING.
////
//// On top of the proof of concept, the select lists also hold the
//// computed values that dream_model trusts as never NULL: non-NULL
//// constants, `count(...)`, `coalesce(...)`, `EXISTS (...)`,
//// `IS [NOT] NULL` and `IS [NOT] DISTINCT FROM`. They land inside outer
//// joins, grouping sets (also as grouping expressions), set operations and
//// subqueries. INSERT and UPDATE also store parameters into columns, for
//// the parameter rules: bare, in an explicit cast to the column's type
//// (a length coercion for `varchar(n)` and the like), or inside a function
//// that rejects NULL. An `ON CONFLICT` names the primary key, a unique
//// column or a unique constraint.

import fuzz/random.{type Random}
import fuzz/schema.{
  type Kind, type Relation, BoolKind, IntArrayKind, IntKind, Relation, TextKind,
  TimestampKind, kind_sql,
}
import gleam/int.{max, to_string}
import gleam/list.{
  any, append, filter_map, flat_map, flatten, fold, index_map, key_find, length,
  map, map2, reverse, sort, take, unique,
}
import gleam/option.{type Option, None, Some}
import gleam/result.{unwrap}
import gleam/string.{compare, join, starts_with}

/// A column that an expression can refer to.
pub type ScopeColumn {
  ScopeColumn(reference: String, kind: Kind, name: String)
}

/// The state of the query generator.
pub type Generator {
  Generator(
    random: Random,
    tables: List(Relation),
    views: List(Relation),
    version: Int,
    aliases: Int,
    /// The SQL type of each column, by `table.column`.
    column_types: List(#(String, String)),
    /// The conflict targets of each table other than its primary key.
    conflict_targets: List(#(String, String)),
  )
}

type Scope =
  List(ScopeColumn)

type Columns =
  List(#(String, Kind))

/// Starts a generator for the tables of a schema.
pub fn new(random: Random, tables: List(Relation), version: Int) -> Generator {
  Generator(
    random:,
    tables:,
    views: [],
    version:,
    aliases: 0,
    column_types: [],
    conflict_targets: [],
  )
}

/// Adds the column types and the conflict targets of a schema, for the
/// parameter stores and `ON CONFLICT`.
pub fn add_schema_facts(
  generator: Generator,
  column_types: List(#(String, String)),
  conflict_targets: List(#(String, String)),
) -> Generator {
  Generator(..generator, column_types:, conflict_targets:)
}

/// Adds a view that queries can read.
pub fn add_view(generator: Generator, view: Relation) -> Generator {
  Generator(..generator, views: append(generator.views, [view]))
}

fn roll(
  generator: Generator,
  draw: fn(Random) -> #(a, Random),
) -> #(a, Generator) {
  let #(value, random) = draw(generator.random)
  #(value, Generator(..generator, random:))
}

fn between(generator: Generator, low: Int, high: Int) -> #(Int, Generator) {
  roll(generator, random.between(_, low, high))
}

fn chance(generator: Generator, probability: Float) -> #(Bool, Generator) {
  roll(generator, random.chance(_, probability))
}

fn choose(
  generator: Generator,
  items: List(a),
  fallback: a,
) -> #(a, Generator) {
  roll(generator, random.choose(_, items, fallback))
}

fn weighted(
  generator: Generator,
  items: List(#(Float, a)),
  fallback: a,
) -> #(a, Generator) {
  roll(generator, random.weighted(_, items, fallback))
}

fn alias(generator: Generator, prefix: String) -> #(String, Generator) {
  let number = generator.aliases + 1
  #(prefix <> to_string(number), Generator(..generator, aliases: number))
}

fn weight(holds: Bool, value: Float) -> Float {
  case holds {
    True -> value
    False -> 0.0
  }
}

fn scope_of(alias: String, columns: Columns) -> Scope {
  map(columns, fn(column) {
    ScopeColumn(alias <> "." <> column.0, column.1, column.0)
  })
}

// --- Literals --------------------------------------------------------------

fn equal_literal(kind: Kind) -> String {
  case kind {
    IntKind -> "1"
    TextKind -> "'a'"
    BoolKind -> "true"
    TimestampKind -> "'2024-01-01 10:00:00'::timestamp"
    IntArrayKind -> "'{1,NULL}'::int[]"
  }
}

fn other_literal(kind: Kind) -> String {
  case kind {
    IntKind -> "2"
    TextKind -> "'b'"
    BoolKind -> "false"
    TimestampKind -> "'2024-01-02 11:30:00'::timestamp"
    IntArrayKind -> "'{1,2}'::int[]"
  }
}

fn fallback_literal(kind: Kind) -> String {
  case kind {
    IntKind -> "0"
    TextKind -> "'z'"
    BoolKind -> "false"
    TimestampKind -> "'2000-01-01 00:00:00'::timestamp"
    IntArrayKind -> "'{}'::int[]"
  }
}

// --- FROM items ------------------------------------------------------------

type RelationKind {
  TableRelation
  ViewRelation
  CteRelation
}

fn relation(
  generator: Generator,
  ctes: List(Relation),
) -> #(#(String, Scope), Generator) {
  let #(kind, generator) =
    weighted(
      generator,
      [
        #(4.0, TableRelation),
        #(weight(generator.views != [], 1.0), ViewRelation),
        #(weight(ctes != [], 2.0), CteRelation),
      ],
      TableRelation,
    )
  let candidates = case kind {
    TableRelation -> generator.tables
    ViewRelation -> generator.views
    CteRelation -> ctes
  }
  let #(chosen, generator) =
    choose(generator, candidates, Relation("t0", [#("id", IntKind)]))
  let #(name, generator) = alias(generator, "t")
  let #(only, generator) = chance(generator, 0.1)
  let prefix = case kind == TableRelation && only {
    True -> "only "
    False -> ""
  }
  #(
    #(prefix <> chosen.name <> " " <> name, scope_of(name, chosen.columns)),
    generator,
  )
}

type FromKind {
  RelationItem
  SubqueryItem
  JoinItem
  ValuesItem
  FunctionItem
  LateralItem
}

fn from_item(
  generator: Generator,
  depth: Int,
  ctes: List(Relation),
  outer: Scope,
) -> #(#(String, Scope), Generator) {
  let deeper = depth > 0
  let #(kind, generator) =
    weighted(
      generator,
      [
        #(5.0, RelationItem),
        #(weight(deeper, 2.0), SubqueryItem),
        #(weight(deeper, 3.0), JoinItem),
        #(0.5, ValuesItem),
        #(0.5, FunctionItem),
        #(weight(deeper, 1.0), LateralItem),
      ],
      RelationItem,
    )
  case kind {
    RelationItem -> relation(generator, ctes)
    SubqueryItem -> subquery_item(generator, depth, ctes, outer, "s", "")
    LateralItem -> subquery_item(generator, depth, ctes, outer, "l", "lateral ")
    ValuesItem -> values_item(generator)
    FunctionItem -> {
      let #(name, generator) = alias(generator, "g")
      let #(count, generator) = between(generator, 0, 2)
      #(
        #("generate_series(1, " <> to_string(count) <> ") " <> name <> "(gi)", [
          ScopeColumn(name <> ".gi", IntKind, "gi"),
        ]),
        generator,
      )
    }
    JoinItem -> join_item(generator, depth, ctes, outer)
  }
}

fn subquery_item(
  generator: Generator,
  depth: Int,
  ctes: List(Relation),
  outer: Scope,
  prefix: String,
  keyword: String,
) -> #(#(String, Scope), Generator) {
  let #(#(sql, columns), generator) =
    select(generator, depth - 1, ctes, outer, 4)
  let #(name, generator) = alias(generator, prefix)
  #(
    #(keyword <> "(" <> sql <> ") " <> name, scope_of(name, columns)),
    generator,
  )
}

fn values_item(generator: Generator) -> #(#(String, Scope), Generator) {
  let #(name, generator) = alias(generator, "v")
  let #(count, generator) = between(generator, 1, 3)
  let #(rows, generator) =
    random.numbers(1, count)
    |> fold(#([], generator), fn(state, _) {
      let #(rows, generator) = state
      let #(number, generator) = choose(generator, ["1", "2", "null::int"], "1")
      let #(text, generator) = choose(generator, ["'a'", "null::text"], "'a'")
      #(["(" <> number <> ", " <> text <> ")", ..rows], generator)
    })
  #(
    #("(values " <> join(rows, ", ") <> ") " <> name <> "(vi, vt)", [
      ScopeColumn(name <> ".vi", IntKind, "vi"),
      ScopeColumn(name <> ".vt", TextKind, "vt"),
    ]),
    generator,
  )
}

type JoinKind {
  InnerJoin
  LeftJoin
  RightJoin
  FullJoin
  CrossJoin
}

fn join_sql(kind: JoinKind) -> String {
  case kind {
    InnerJoin -> "join"
    LeftJoin -> "left join"
    RightJoin -> "right join"
    FullJoin -> "full join"
    CrossJoin -> "cross join"
  }
}

fn join_item(
  generator: Generator,
  depth: Int,
  ctes: List(Relation),
  outer: Scope,
) -> #(#(String, Scope), Generator) {
  let #(#(left_sql, left), generator) =
    from_item(generator, depth - 1, ctes, outer)
  let #(kind, generator) =
    weighted(
      generator,
      [
        #(3.0, InnerJoin),
        #(4.0, LeftJoin),
        #(2.0, RightJoin),
        #(2.0, FullJoin),
        #(1.0, CrossJoin),
      ],
      InnerJoin,
    )
  let right_outer = case kind {
    InnerJoin | LeftJoin | CrossJoin -> append(outer, left)
    RightJoin | FullJoin -> outer
  }
  let #(#(right_sql, right), generator) =
    from_item(generator, depth - 1, ctes, right_outer)
  let lateral = starts_with(right_sql, "lateral")
  let kind = case lateral, kind {
    True, RightJoin | True, FullJoin -> LeftJoin
    _, _ -> kind
  }
  let both = append(left, right)
  let #(using, generator) = chance(generator, 0.25)
  let common = common_columns(left, right)
  case kind, common, using && !lateral {
    CrossJoin, _, _ -> #(
      #(left_sql <> " cross join " <> right_sql, both),
      generator,
    )
    _, [_, ..], True -> {
      let #(#(name, column_kind), generator) =
        choose(generator, common, #("id", IntKind))
      let merged =
        list.filter(both, fn(column) { column.name != name })
        |> append([ScopeColumn(name, column_kind, name)])
      #(
        #(
          "("
            <> left_sql
            <> " "
            <> join_sql(kind)
            <> " "
            <> right_sql
            <> " using ("
            <> name
            <> "))",
          merged,
        ),
        generator,
      )
    }
    _, _, _ -> {
      let #(on, generator) = condition(generator, both, Some(#(left, right)))
      #(
        #(
          "("
            <> left_sql
            <> " "
            <> join_sql(kind)
            <> " "
            <> right_sql
            <> " on "
            <> on
            <> ")",
          both,
        ),
        generator,
      )
    }
  }
}

/// The column names on both sides of a join that have one kind on both.
fn common_columns(left: Scope, right: Scope) -> List(#(String, Kind)) {
  let both = append(left, right)
  map(left, fn(column) { column.name })
  |> unique
  |> list.filter(fn(name) { any(right, fn(column) { column.name == name }) })
  |> filter_map(fn(name) {
    let kinds =
      list.filter(both, fn(column) { column.name == name })
      |> map(fn(column) { column.kind })
      |> unique
    case kinds {
      [kind] -> Ok(#(name, kind))
      _ -> Error(Nil)
    }
  })
  |> sort(fn(left, right) { compare(left.0, right.0) })
}

// --- Conditions and expressions --------------------------------------------

fn condition(
  generator: Generator,
  scope: Scope,
  prefer_join: Option(#(Scope, Scope)),
) -> #(String, Generator) {
  let #(prefer, generator) = chance(generator, 0.8)
  let pairs = case prefer_join, prefer {
    Some(#(left, right)), True ->
      flat_map(left, fn(left) {
        list.filter(right, fn(right) { right.kind == left.kind })
        |> map(fn(right) { left.reference <> " = " <> right.reference })
      })
    _, _ -> []
  }
  case pairs, scope {
    [_, ..], _ -> choose(generator, pairs, "true")
    [], [] -> #("true", generator)
    [], _ -> {
      let #(column, generator) =
        choose(generator, scope, ScopeColumn("1", IntKind, "1"))
      choose(
        generator,
        [
          column.reference <> " is null",
          column.reference <> " is not null",
          column.reference <> " = " <> equal_literal(column.kind),
          "true",
          column.reference <> " <> " <> other_literal(column.kind),
        ],
        "true",
      )
    }
  }
}

type ExpressionKind {
  Bare
  Cast
  Coalesce
  CoalesceColumns
  Function
  Scalar
  CaseWhen
  Constant
  NullTest
  DistinctFrom
  Exists
}

/// A select-list item: mostly bare columns (the risky part), sometimes
/// computed, and sometimes one of the computed values that dream_model
/// trusts as never NULL.
fn expression(
  generator: Generator,
  scope: Scope,
  depth: Int,
  ctes: List(Relation),
) -> #(#(String, Kind), Generator) {
  let #(column, generator) =
    choose(generator, scope, ScopeColumn("1", IntKind, "1"))
  let #(kind, generator) =
    weighted(
      generator,
      [
        #(10.0, Bare),
        #(1.0, Cast),
        #(1.0, Coalesce),
        #(0.5, CoalesceColumns),
        #(1.0, Function),
        #(0.5, Scalar),
        #(0.5, CaseWhen),
        #(1.0, Constant),
        #(1.0, NullTest),
        #(0.5, DistinctFrom),
        #(weight(depth > 0, 0.5), Exists),
      ],
      Bare,
    )
  let reference = column.reference
  case kind {
    Bare -> #(#(reference, column.kind), generator)
    Cast -> #(
      #(reference <> "::" <> kind_sql(column.kind), column.kind),
      generator,
    )
    Coalesce -> #(
      #(
        "coalesce(" <> reference <> ", " <> fallback_literal(column.kind) <> ")",
        column.kind,
      ),
      generator,
    )
    CoalesceColumns -> {
      let #(other, generator) = same_kind(generator, scope, column)
      #(
        #("coalesce(" <> reference <> ", " <> other <> ")", column.kind),
        generator,
      )
    }
    Function -> #(function_of(column), generator)
    CaseWhen -> #(
      #(
        "case when "
          <> reference
          <> " is null then "
          <> reference
          <> " else "
          <> reference
          <> " end",
        column.kind,
      ),
      generator,
    )
    Constant ->
      choose(
        generator,
        [
          #("1", IntKind),
          #("'c'", TextKind),
          #("true", BoolKind),
          #("null::int", IntKind),
        ],
        #("1", IntKind),
      )
    NullTest -> {
      let #(operator, generator) =
        choose(generator, [" is null", " is not null"], " is null")
      #(#(reference <> operator, BoolKind), generator)
    }
    DistinctFrom -> {
      let #(other, generator) = same_kind(generator, scope, column)
      let #(operator, generator) =
        choose(
          generator,
          [" is distinct from ", " is not distinct from "],
          " is distinct from ",
        )
      #(#(reference <> operator <> other, BoolKind), generator)
    }
    Scalar | Exists if depth <= 0 -> #(#(reference, column.kind), generator)
    Scalar -> {
      let #(#(sql, columns), generator) =
        select(generator, depth - 1, ctes, scope, 1)
      let kind = list.first(columns) |> result_kind
      #(#("(" <> sql <> " limit 1)", kind), generator)
    }
    Exists -> {
      let #(#(sql, _), generator) = select(generator, depth - 1, ctes, scope, 1)
      #(#("exists (" <> sql <> ")", BoolKind), generator)
    }
  }
}

fn result_kind(first: Result(#(String, Kind), Nil)) -> Kind {
  case first {
    Ok(#(_, kind)) -> kind
    Error(Nil) -> IntKind
  }
}

fn function_of(column: ScopeColumn) -> #(String, Kind) {
  case column.kind {
    IntKind -> #("abs(" <> column.reference <> ")", IntKind)
    TextKind -> #("lower(" <> column.reference <> ")", TextKind)
    BoolKind -> #("not " <> column.reference, BoolKind)
    TimestampKind -> #(
      "date_trunc('day', " <> column.reference <> ")",
      TimestampKind,
    )
    IntArrayKind -> #("cardinality(" <> column.reference <> ")", IntKind)
  }
}

/// Another column of the same kind, or a literal of that kind.
fn same_kind(
  generator: Generator,
  scope: Scope,
  column: ScopeColumn,
) -> #(String, Generator) {
  let others =
    list.filter(scope, fn(other) { other.kind == column.kind })
    |> map(fn(other) { other.reference })
  choose(
    generator,
    [equal_literal(column.kind), ..others],
    equal_literal(column.kind),
  )
}

// --- SELECT ----------------------------------------------------------------

/// Returns a SELECT statement and its result columns, `x0`, `x1`, ...
fn select(
  generator: Generator,
  depth: Int,
  ctes: List(Relation),
  outer: Scope,
  max_columns: Int,
) -> #(#(String, Columns), Generator) {
  let #(with_ctes, generator) = chance(generator, 0.2)
  let #(#(with_sql, local_ctes), generator) = case depth > 0 && with_ctes {
    True -> common_table_expressions(generator, depth, ctes)
    False -> #(#("", ctes), generator)
  }
  let #(#(from_sql, scope), generator) =
    from_item(generator, depth, local_ctes, outer)
  let visible = append(scope, outer)
  let #(count, generator) = between(generator, 1, max_columns)
  let #(group, generator) = chance(generator, 0.15)
  let #(aggregate, generator) = chance(generator, 0.1)
  let #(#(items, columns, group_by), generator) = case group, aggregate {
    True, _ -> grouped_items(generator, scope, count)
    False, True -> aggregate_items(generator, scope, count)
    False, False -> plain_items(generator, visible, depth, local_ctes, count)
  }
  let #(filtered, generator) = chance(generator, 0.3)
  let #(where, generator) = case filtered {
    True -> {
      let #(on, generator) = condition(generator, visible, None)
      #(" where " <> on, generator)
    }
    False -> #("", generator)
  }
  let #(distinct, generator) = chance(generator, 0.1)
  let distinct = case distinct {
    True -> "distinct "
    False -> ""
  }
  let #(limited, generator) = chance(generator, 0.1)
  let #(limit, generator) = between(generator, 0, 3)
  let tail = case limited {
    True -> " limit " <> to_string(limit)
    False -> ""
  }
  let sql =
    with_sql
    <> "select "
    <> distinct
    <> join(items, ", ")
    <> " from "
    <> from_sql
    <> where
    <> group_by
    <> tail
  let #(combined, generator) = chance(generator, 0.15)
  case depth > 0 && combined && with_sql == "" {
    True -> set_operation(generator, sql, columns, depth, ctes)
    False -> #(#(sql, columns), generator)
  }
}

fn common_table_expressions(
  generator: Generator,
  depth: Int,
  ctes: List(Relation),
) -> #(#(String, List(Relation)), Generator) {
  let #(count, generator) = between(generator, 1, 2)
  let #(#(parts, local_ctes), generator) =
    random.numbers(1, count)
    |> fold(#(#([], ctes), generator), fn(state, _) {
      let #(#(parts, local_ctes), generator) = state
      let #(#(sql, columns), generator) =
        select(generator, depth - 1, local_ctes, [], 4)
      let #(name, generator) = alias(generator, "c")
      let #(materialized, generator) =
        choose(generator, ["", "materialized ", "not materialized "], "")
      #(
        #(
          [name <> " as " <> materialized <> "(" <> sql <> ")", ..parts],
          append(local_ctes, [Relation(name, columns)]),
        ),
        generator,
      )
    })
  #(#("with " <> join(reverse(parts), ", ") <> " ", local_ctes), generator)
}

fn set_operation(
  generator: Generator,
  sql: String,
  columns: Columns,
  depth: Int,
  ctes: List(Relation),
) -> #(#(String, Columns), Generator) {
  let #(#(other, other_columns), generator) =
    select(generator, depth - 1, ctes, [], length(columns))
  let #(operator, generator) =
    choose(
      generator,
      [
        "union",
        "union all",
        "intersect",
        "except",
        "except all",
        "intersect all",
      ],
      "union",
    )
  let kinds = fn(columns: Columns) { map(columns, fn(column) { column.1 }) }
  case kinds(columns) == kinds(other_columns) {
    True -> #(
      #(
        "(select * from ("
          <> sql
          <> ") q1) "
          <> operator
          <> " (select * from ("
          <> other
          <> ") q2)",
        columns,
      ),
      generator,
    )
    False -> #(#(sql, columns), generator)
  }
}

fn name_items(expressions: List(#(String, Kind))) -> #(List(String), Columns) {
  let named =
    index_map(expressions, fn(expression, index) {
      let name = "x" <> to_string(index)
      #(expression.0 <> " as " <> name, #(name, expression.1))
    })
  #(map(named, fn(pair) { pair.0 }), map(named, fn(pair) { pair.1 }))
}

fn plain_items(
  generator: Generator,
  visible: Scope,
  depth: Int,
  ctes: List(Relation),
  count: Int,
) -> #(#(List(String), Columns, String), Generator) {
  let #(expressions, generator) =
    random.numbers(1, count)
    |> fold(#([], generator), fn(state, _) {
      let #(expressions, generator) = state
      let #(item, generator) = expression(generator, visible, depth, ctes)
      #([item, ..expressions], generator)
    })
  let #(items, columns) = name_items(reverse(expressions))
  #(#(items, columns, ""), generator)
}

/// A select list of aggregates only, with no GROUP BY: one row even when
/// the FROM item is empty.
fn aggregate_items(
  generator: Generator,
  scope: Scope,
  count: Int,
) -> #(#(List(String), Columns, String), Generator) {
  let #(expressions, generator) =
    random.numbers(1, count)
    |> fold(#([], generator), fn(state, _) {
      let #(expressions, generator) = state
      let #(column, generator) =
        choose(generator, scope, ScopeColumn("1", IntKind, "1"))
      let #(item, generator) =
        choose(
          generator,
          [
            #("count(*)", IntKind),
            #("count(" <> column.reference <> ")", IntKind),
            #("count(distinct " <> column.reference <> ")", IntKind),
            #(maximum(column), column.kind),
            #(
              "coalesce("
                <> maximum(column)
                <> ", "
                <> fallback_literal(column.kind)
                <> ")",
              column.kind,
            ),
          ],
          #("count(*)", IntKind),
        )
      #([item, ..expressions], generator)
    })
  let #(items, columns) = name_items(reverse(expressions))
  #(#(items, columns, ""), generator)
}

/// `max` of int, text, timestamp and arrays, `bool_or` of boolean:
/// PostgreSQL has no `max` of boolean.
fn maximum(column: ScopeColumn) -> String {
  case column.kind {
    BoolKind -> "bool_or(" <> column.reference <> ")"
    IntKind | TextKind | TimestampKind | IntArrayKind ->
      "max(" <> column.reference <> ")"
  }
}

type GroupMode {
  GroupBy
  Rollup
  Cube
  GroupingSets
}

/// A grouped select list: the grouped columns, sometimes a never-NULL
/// computed value that is itself a grouping expression, and aggregates.
fn grouped_items(
  generator: Generator,
  scope: Scope,
  count: Int,
) -> #(#(List(String), Columns, String), Generator) {
  let #(size, generator) = between(generator, 1, 2)
  let #(grouped, generator) = roll(generator, random.sample(_, scope, size))
  let #(mode, generator) =
    choose(generator, [GroupBy, GroupBy, Rollup, Cube, GroupingSets], GroupBy)
  let #(computed, generator) = chance(generator, 0.3)
  let #(extra, generator) = case computed, grouped {
    True, [column, ..] ->
      choose(
        generator,
        [
          [
            #(
              "coalesce("
                <> column.reference
                <> ", "
                <> fallback_literal(column.kind)
                <> ")",
              column.kind,
            ),
          ],
          [#(column.reference <> " is null", BoolKind)],
          [
            #(
              column.reference
                <> " is not distinct from "
                <> equal_literal(column.kind),
              BoolKind,
            ),
          ],
        ],
        [],
      )
    _, _ -> #([], generator)
  }
  let expressions =
    append(map(grouped, fn(column) { #(column.reference, column.kind) }), extra)
  let #(aggregates, generator) = grouped_aggregates(generator, grouped, scope)
  let #(candidates, generator) =
    roll(generator, random.shuffle(_, append(expressions, aggregates)))
  let chosen = case take(candidates, count) {
    [] -> [#("count(*)", IntKind)]
    chosen -> chosen
  }
  let #(items, columns) = name_items(chosen)
  let references = join(map(expressions, fn(item) { item.0 }), ", ")
  let group_by = case expressions, mode {
    [], _ -> ""
    _, GroupBy -> " group by " <> references
    _, Rollup -> " group by rollup (" <> references <> ")"
    _, Cube -> " group by cube (" <> references <> ")"
    _, GroupingSets -> " group by grouping sets ((" <> references <> "), ())"
  }
  #(#(items, columns, group_by), generator)
}

fn grouped_aggregates(
  generator: Generator,
  grouped: Scope,
  scope: Scope,
) -> #(List(#(String, Kind)), Generator) {
  let #(column, generator) =
    choose(generator, scope, ScopeColumn("1", IntKind, "1"))
  let #(grouped_column, generator) = choose(generator, grouped, column)
  roll(generator, random.sample(
    _,
    [
      #("count(*)", IntKind),
      #("count(" <> column.reference <> ")", IntKind),
      #("1", IntKind),
      #(grouped_column.reference <> " is null", BoolKind),
      #(
        "coalesce("
          <> grouped_column.reference
          <> ", "
          <> fallback_literal(grouped_column.kind)
          <> ")",
        grouped_column.kind,
      ),
    ],
    2,
  ))
}

// --- Statements ------------------------------------------------------------

type StatementKind {
  Select
  Insert
  Update
  Delete
  Merge
}

/// Returns a view definition: a SELECT two levels deep.
pub fn view(generator: Generator) -> #(#(String, Columns), Generator) {
  select(generator, 2, [], [], 4)
}

/// Returns a random statement up to `depth` levels deep: a SELECT, or in
/// about 15% of the cases an INSERT, UPDATE, DELETE or MERGE (PostgreSQL
/// 17 and newer) with RETURNING.
pub fn statement(generator: Generator, depth: Int) -> #(String, Generator) {
  let #(changes, generator) = chance(generator, 0.15)
  let #(kind, generator) =
    weighted(
      generator,
      [
        #(1.0, Insert),
        #(1.0, Update),
        #(1.0, Delete),
        #(weight(generator.version >= 17, 1.0), Merge),
      ],
      Insert,
    )
  case changes {
    False -> {
      let #(#(sql, _), generator) = select(generator, depth, [], [], 4)
      #(sql, generator)
    }
    True -> change(generator, kind, depth)
  }
}

fn change(
  generator: Generator,
  kind: StatementKind,
  depth: Int,
) -> #(String, Generator) {
  let #(table, generator) =
    choose(generator, generator.tables, Relation("t0", [#("id", IntKind)]))
  let #(name, generator) = alias(generator, "t")
  let #(returning, generator) = returning_list(generator, table, name)
  let inner = max(depth - 1, 0)
  case kind {
    Select -> {
      let #(#(sql, _), generator) = select(generator, depth, [], [], 4)
      #(sql, generator)
    }
    Insert -> insert(generator, table, name, returning, inner)
    Update -> update(generator, table, name, returning, inner)
    Delete -> delete(generator, table, name, returning, inner)
    Merge -> merge(generator, table, name, returning, inner)
  }
}

fn returning_list(
  generator: Generator,
  table: Relation,
  name: String,
) -> #(String, Generator) {
  let #(old_new, generator) = chance(generator, 0.4)
  let #(which, generator) = choose(generator, ["old", "new"], "old")
  let prefix = case generator.version >= 18 && old_new {
    True -> which
    False -> name
  }
  #(
    map(table.columns, fn(column) { prefix <> "." <> column.0 })
      |> join(", "),
    generator,
  )
}

fn non_key_columns(table: Relation) -> Columns {
  list.filter(table.columns, fn(column) { column.0 != "id" })
}

fn insert(
  generator: Generator,
  table: Relation,
  name: String,
  returning: String,
  depth: Int,
) -> #(String, Generator) {
  let targets = non_key_columns(table)
  let #(with_parameters, generator) = chance(generator, 0.5)
  let #(#(source, assigned), generator) = case with_parameters {
    True -> {
      let #(#(values, parameters), generator) =
        parameter_values(generator, table.name, targets)
      #(
        #(
          " ("
            <> join(["id", ..map(targets, fn(column) { column.0 })], ", ")
            <> ") values (1000, "
            <> join(values, ", ")
            <> ")",
          parameters,
        ),
        generator,
      )
    }
    False -> {
      let #(#(sql, _), generator) = select(generator, depth, [], [], 4)
      #(
        #(
          " (id) select (row_number() over ())::int + 1000 from ("
            <> sql
            <> ") z",
          [],
        ),
        generator,
      )
    }
  }
  let #(conflict, generator) =
    on_conflict(generator, table.name, targets, assigned)
  #(
    "insert into "
      <> table.name
      <> " as "
      <> name
      <> source
      <> conflict
      <> " returning "
      <> returning,
    generator,
  )
}

/// The values of an INSERT ... VALUES: a new parameter, a parameter of the
/// same kind used before, or a literal. Returns the values and the
/// parameters with their kinds.
fn parameter_values(
  generator: Generator,
  table: String,
  targets: Columns,
) -> #(#(List(String), List(#(Int, Kind))), Generator) {
  let #(#(values, parameters), generator) =
    fold(targets, #(#([], []), generator), fn(state, target) {
      let #(#(values, parameters), generator) = state
      let #(#(value, parameters), generator) =
        parameter_value(generator, table, target, parameters)
      #(#([value, ..values], parameters), generator)
    })
  #(#(reverse(values), parameters), generator)
}

type ValueKind {
  NewParameter
  CastParameter
  RequiredParameter
  ReusedParameter
  LiteralValue
}

/// A value stored into a column: a new parameter (bare, in an explicit
/// cast to the column's type, or inside a function that rejects NULL), a
/// parameter of the same kind used before, or a literal.
fn parameter_value(
  generator: Generator,
  table: String,
  target: #(String, Kind),
  parameters: List(#(Int, Kind)),
) -> #(#(String, List(#(Int, Kind))), Generator) {
  let kind = target.1
  let same =
    list.filter(parameters, fn(parameter) { parameter.1 == kind })
    |> map(fn(parameter) { parameter.0 })
  let #(value_kind, generator) =
    weighted(
      generator,
      [
        #(0.4, NewParameter),
        #(0.15, CastParameter),
        #(0.05, RequiredParameter),
        #(weight(same != [], 0.2), ReusedParameter),
        #(0.2, LiteralValue),
      ],
      NewParameter,
    )
  let number = length(parameters) + 1
  let new_parameter = "$" <> to_string(number)
  let added = append(parameters, [#(number, kind)])
  case value_kind {
    NewParameter -> #(#(new_parameter, added), generator)
    CastParameter -> {
      let sql_type =
        key_find(generator.column_types, table <> "." <> target.0)
        |> unwrap(kind_sql(kind))
      #(#(new_parameter <> "::" <> sql_type, added), generator)
    }
    RequiredParameter -> #(
      #(required_function(kind) <> "(" <> new_parameter <> ")", added),
      generator,
    )
    ReusedParameter -> {
      let #(number, generator) = choose(generator, same, 1)
      #(#("$" <> to_string(number), parameters), generator)
    }
    LiteralValue -> #(#(equal_literal(kind), parameters), generator)
  }
}

/// The function that rejects NULL, for a kind (see `fuzz/schema`).
fn required_function(kind: Kind) -> String {
  case kind {
    IntKind | BoolKind -> "fuzz_required_int"
    TextKind -> "fuzz_required_text"
    TimestampKind -> "fuzz_required_timestamp"
    IntArrayKind -> "fuzz_required_int_array"
  }
}

fn on_conflict(
  generator: Generator,
  table: String,
  targets: Columns,
  parameters: List(#(Int, Kind)),
) -> #(String, Generator) {
  let first = list.first(targets)
  let #(choice, generator) = between(generator, 0, 3)
  let unique_targets =
    list.filter(generator.conflict_targets, fn(target) { target.0 == table })
    |> map(fn(target) { target.1 })
  let #(conflict_target, generator) =
    choose(generator, ["(id)", "(id)", ..unique_targets], "(id)")
  let prefix = " on conflict " <> conflict_target <> " do update set "
  case first, choice {
    Error(Nil), _ | _, 0 -> #("", generator)
    _, 1 -> #(" on conflict do nothing", generator)
    Ok(#(column, _)), 2 -> #(
      prefix <> column <> " = excluded." <> column,
      generator,
    )
    Ok(#(column, kind)), _ -> {
      let #(#(value, _), generator) =
        parameter_value(generator, table, #(column, kind), parameters)
      #(prefix <> column <> " = " <> value, generator)
    }
  }
}

fn from_and_condition(
  generator: Generator,
  table: Relation,
  name: String,
  depth: Int,
) -> #(#(String, String, String), Generator) {
  let #(#(from_sql, scope), generator) = from_item(generator, depth, [], [])
  let extra = case take(scope, 2) {
    [] -> "1"
    columns -> join(map(columns, fn(column) { column.reference }), ", ")
  }
  let target = scope_of(name, table.columns)
  let #(on, generator) =
    condition(generator, append(target, scope), Some(#(target, scope)))
  #(#(from_sql, on, extra), generator)
}

fn update(
  generator: Generator,
  table: Relation,
  name: String,
  returning: String,
  depth: Int,
) -> #(String, Generator) {
  let #(#(from_sql, on, extra), generator) =
    from_and_condition(generator, table, name, depth)
  let targets = non_key_columns(table)
  let #(with_parameters, generator) = chance(generator, 0.5)
  let #(#(set, filter), generator) = case with_parameters, targets {
    True, [_, ..] -> {
      let #(#(values, parameters), generator) =
        parameter_values(generator, table.name, targets)
      let set =
        map2(targets, values, fn(target, value) { target.0 <> " = " <> value })
        |> join(", ")
      let #(reuse, generator) = chance(generator, 0.2)
      let filter = case reuse, parameters {
        True, [#(number, _), ..] ->
          " and $" <> to_string(number) <> " is not null"
        _, _ -> ""
      }
      #(#(set, filter), generator)
    }
    _, _ -> #(#("id = " <> name <> ".id", ""), generator)
  }
  #(
    "update "
      <> table.name
      <> " "
      <> name
      <> " set "
      <> set
      <> " from "
      <> from_sql
      <> " where "
      <> on
      <> filter
      <> " returning "
      <> returning
      <> ", "
      <> extra,
    generator,
  )
}

fn delete(
  generator: Generator,
  table: Relation,
  name: String,
  returning: String,
  depth: Int,
) -> #(String, Generator) {
  let #(#(from_sql, on, extra), generator) =
    from_and_condition(generator, table, name, depth)
  #(
    "delete from "
      <> table.name
      <> " "
      <> name
      <> " using "
      <> from_sql
      <> " where "
      <> on
      <> " returning "
      <> returning
      <> ", "
      <> extra,
    generator,
  )
}

fn merge(
  generator: Generator,
  table: Relation,
  name: String,
  returning: String,
  depth: Int,
) -> #(String, Generator) {
  let #(#(source, columns), generator) = select(generator, depth, [], [], 4)
  let #(source_name, generator) = alias(generator, "m")
  let on = case columns {
    [#(column, IntKind), ..] -> name <> ".id = " <> source_name <> "." <> column
    _ -> "false"
  }
  let #(matched, generator) = chance(generator, 0.6)
  let #(matched_action, generator) =
    choose(
      generator,
      [
        "when matched then update set id = " <> name <> ".id",
        "when matched then delete",
        "when matched then do nothing",
      ],
      "when matched then delete",
    )
  let #(by_source, generator) = chance(generator, 0.5)
  let #(by_source_action, generator) =
    choose(
      generator,
      ["delete", "update set id = " <> name <> ".id", "do nothing"],
      "delete",
    )
  let #(not_matched, generator) = chance(generator, 0.5)
  let actions =
    flatten([
      when(matched, matched_action),
      when(by_source, "when not matched by source then " <> by_source_action),
    ])
  let actions = case not_matched || actions == [] {
    True -> append(actions, ["when not matched then do nothing"])
    False -> actions
  }
  let extra =
    take(columns, 2)
    |> map(fn(column) { source_name <> "." <> column.0 })
    |> join(", ")
  #(
    "merge into "
      <> table.name
      <> " "
      <> name
      <> " using ("
      <> source
      <> ") "
      <> source_name
      <> " on "
      <> on
      <> " "
      <> join(actions, " ")
      <> " returning "
      <> returning
      <> ", "
      <> extra,
    generator,
  )
}

fn when(holds: Bool, item: String) -> List(String) {
  case holds {
    True -> [item]
    False -> []
  }
}
