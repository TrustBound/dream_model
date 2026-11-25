//// Random schemas and data sets for the fuzzer, ported from the proof of
//// concept's `fuzz.py`.
////
//// A schema has 2 to 4 tables `t0`, `t1`, ... with an `id` primary key and
//// 1 to 3 columns `k0`, `k1`, ... of type int or text, each NOT NULL half
//// of the time. Sometimes a table has a child table, and on top of the
//// proof of concept, for the parameter rules and the newer rules:
////
//// - a nullable column can have a CHECK, or a domain type with NOT NULL
////   or with a CHECK;
//// - a table can have a BEFORE trigger that rejects NULL in one column;
//// - a table can be partitioned, with a NOT NULL or a CHECK on one
////   partition only;
//// - on PostgreSQL 18 and newer, a NOT NULL can be `NO INHERIT` so the
////   child table allows NULL, and a table can have rows with NULL under a
////   `NOT NULL ... NOT VALID` constraint.
////
//// A data set fills the tables with rows: NULL in the columns that accept
//// it, and rows that do not match the rows of other tables.

import fuzz/random.{type Random}
import gleam/int
import gleam/list
import gleam/string

/// The type of a value.
pub type Kind {
  IntKind
  TextKind
  BoolKind
}

/// A table or view that queries read: its name and its columns.
pub type Relation {
  Relation(name: String, columns: List(#(String, Kind)))
}

/// A column of a table that a data set fills.
pub type TargetColumn {
  TargetColumn(name: String, kind: Kind, accepts_null: Bool)
}

/// A table that a data set fills. The ids of its rows start after
/// `id_offset`.
pub type Target {
  Target(name: String, id_offset: Int, columns: List(TargetColumn))
}

/// A random schema.
pub type Schema {
  Schema(
    /// The tables that queries read and change.
    tables: List(Relation),
    /// The statements that create the schema, in order.
    statements: List(String),
    /// The tables that data sets fill.
    targets: List(Target),
  )
}

/// A data set: a label and the SQL that fills the tables.
pub type DataSet =
  #(String, String)

type Rule {
  Plain
  NotNull
  NotNullNoInherit
  CheckNotNull
  CheckValue
  DomainNotNull
  DomainCheck
}

type ColumnPlan {
  ColumnPlan(name: String, kind: Kind, rule: Rule)
}

type TableShape {
  Simple
  WithChild
  Partitioned
  Legacy
}

const domains =
  "create domain d_not_null_int as int not null;
create domain d_not_null_text as text not null;
create domain d_check_int as int check (value <> 0);
create domain d_check_text as text check (value <> '')"

/// Returns a random schema for a PostgreSQL version.
pub fn generate(random: Random, version: Int) -> #(Schema, Random) {
  let #(count, random) = random.between(random, 2, 4)
  let #(child_table, random) = pick_table(random, count, 0.4)
  let #(partitioned_table, random) = pick_table(random, count, 0.2)
  let #(legacy_table, random) = case version >= 18 {
    True -> pick_table(random, count, 0.25)
    False -> #(-1, random)
  }
  let #(tables, random) =
    random.numbers(0, count - 1)
    |> list.fold(#([], random), fn(state, index) {
      let #(tables, random) = state
      let shape = case index {
        _ if index == child_table -> WithChild
        _ if index == partitioned_table -> Partitioned
        _ if index == legacy_table -> Legacy
        _ -> Simple
      }
      let #(table, random) = generate_table(random, index, shape, version)
      #([table, ..tables], random)
    })
  let tables = list.reverse(tables)
  let schema =
    Schema(
      tables: list.map(tables, fn(table) { table.0 }),
      statements: [domains, ..list.flat_map(tables, fn(table) { table.1 })],
      targets: list.flat_map(tables, fn(table) { table.2 }),
    )
  #(schema, random)
}

fn pick_table(
  random: Random,
  count: Int,
  probability: Float,
) -> #(Int, Random) {
  let #(wanted, random) = random.chance(random, probability)
  let #(index, random) = random.between(random, 0, count - 1)
  case wanted {
    True -> #(index, random)
    False -> #(-1, random)
  }
}

fn generate_table(
  random: Random,
  index: Int,
  shape: TableShape,
  version: Int,
) -> #(#(Relation, List(String), List(Target)), Random) {
  let name = "t" <> int.to_string(index)
  let #(count, random) = random.between(random, 1, 3)
  let #(plans, random) =
    random.numbers(0, count - 1)
    |> list.fold(#([], random), fn(state, number) {
      let #(plans, random) = state
      let #(plan, random) = generate_column(random, number, shape, version)
      #([plan, ..plans], random)
    })
  let plans = list.reverse(plans)
  let relation =
    Relation(name, [
      #("id", IntKind),
      ..list.map(plans, fn(plan) { #(plan.name, plan.kind) })
    ])
  let #(trigger_column, random) = pick_trigger_column(random, plans)
  let base = base_columns(plans, trigger_column)
  let #(statements, targets, random) = case shape {
    Simple -> #(
      [create_table(name, plans, "")],
      [Target(name, 0, base)],
      random,
    )
    WithChild -> {
      let #(statements, targets) = with_child(name, plans, base)
      #(statements, targets, random)
    }
    Partitioned -> partitioned(random, name, plans, base)
    Legacy -> legacy(random, name, plans)
  }
  let trigger = case trigger_column {
    "" -> []
    column -> [reject_null_trigger(name, column)]
  }
  #(#(relation, list.append(statements, trigger), targets), random)
}

fn generate_column(
  random: Random,
  number: Int,
  shape: TableShape,
  version: Int,
) -> #(ColumnPlan, Random) {
  let #(kind, random) = random.choose(random, [IntKind, TextKind], IntKind)
  let no_inherit = case shape == WithChild && version >= 18 {
    True -> 0.3
    False -> 0.0
  }
  let #(rule, random) =
    random.weighted(
      random,
      [
        #(0.5 *. { 1.0 -. no_inherit }, NotNull),
        #(0.5 *. no_inherit, NotNullNoInherit),
        #(0.38, Plain),
        #(0.03, CheckNotNull),
        #(0.03, CheckValue),
        #(0.03, DomainNotNull),
        #(0.03, DomainCheck),
      ],
      Plain,
    )
  #(ColumnPlan("k" <> int.to_string(number), kind, rule), random)
}

/// A table without a child table can have a BEFORE trigger that rejects
/// NULL in one of its plain columns.
fn pick_trigger_column(
  random: Random,
  plans: List(ColumnPlan),
) -> #(String, Random) {
  let plain =
    list.filter(plans, fn(plan) { plan.rule == Plain })
    |> list.map(fn(plan) { plan.name })
  let #(wanted, random) = random.chance(random, 0.1)
  case wanted {
    True -> random.choose(random, plain, "")
    False -> #("", random)
  }
}

fn base_columns(
  plans: List(ColumnPlan),
  trigger_column: String,
) -> List(TargetColumn) {
  [
    TargetColumn("id", IntKind, False),
    ..list.map(plans, fn(plan) {
      TargetColumn(
        plan.name,
        plan.kind,
        accepts_null(plan.rule) && plan.name != trigger_column,
      )
    })
  ]
}

fn accepts_null(rule: Rule) -> Bool {
  case rule {
    Plain | CheckValue | DomainCheck -> True
    NotNull | NotNullNoInherit | CheckNotNull | DomainNotNull -> False
  }
}

fn create_table(name: String, plans: List(ColumnPlan), tail: String) -> String {
  let key = case tail {
    "" -> "id int primary key"
    _ -> "id int not null, primary key (id)"
  }
  "create table "
  <> name
  <> " ("
  <> string.join([key, ..list.map(plans, column_definition)], ", ")
  <> ")"
  <> tail
}

fn column_definition(plan: ColumnPlan) -> String {
  let type_name = kind_sql(plan.kind)
  case plan.rule {
    Plain -> plan.name <> " " <> type_name
    NotNull -> plan.name <> " " <> type_name <> " not null"
    NotNullNoInherit -> plan.name <> " " <> type_name <> " not null no inherit"
    CheckNotNull ->
      plan.name
      <> " "
      <> type_name
      <> " check ("
      <> plan.name
      <> " is not null)"
    CheckValue ->
      plan.name
      <> " "
      <> type_name
      <> " check ("
      <> plan.name
      <> " <> "
      <> excluded_value(plan.kind)
      <> ")"
    DomainNotNull -> plan.name <> " d_not_null_" <> type_name
    DomainCheck -> plan.name <> " d_check_" <> type_name
  }
}

/// Returns the SQL name of a kind.
pub fn kind_sql(kind: Kind) -> String {
  case kind {
    IntKind -> "int"
    TextKind -> "text"
    BoolKind -> "boolean"
  }
}

fn excluded_value(kind: Kind) -> String {
  case kind {
    IntKind -> "0"
    TextKind | BoolKind -> "''"
  }
}

fn reject_null_trigger(name: String, column: String) -> String {
  let function = name <> "_reject_null"
  "create function "
  <> function
  <> "() returns trigger language plpgsql as $$ begin if new."
  <> column
  <> " is null then raise exception '"
  <> column
  <> " required'; end if; return new; end $$; create trigger "
  <> function
  <> " before insert or update on "
  <> name
  <> " for each row execute function "
  <> function
  <> "()"
}

/// A child table that inherits the table. The child's rows have ids from
/// 101. A `NOT NULL NO INHERIT` column accepts NULL in the child, and the
/// parent's trigger does not run for the child.
fn with_child(
  name: String,
  plans: List(ColumnPlan),
  base: List(TargetColumn),
) -> #(List(String), List(Target)) {
  let child = name <> "_child"
  let dropped =
    list.filter(plans, fn(plan) { plan.rule == NotNullNoInherit })
    |> list.map(fn(plan) {
      "alter table "
      <> child
      <> " alter column "
      <> plan.name
      <> " drop not null"
    })
  let child_columns =
    list.map(base, fn(column) {
      let plan = list.find(plans, fn(plan) { plan.name == column.name })
      let rule = case plan {
        Ok(plan) -> plan.rule
        Error(Nil) -> NotNull
      }
      TargetColumn(
        ..column,
        accepts_null: rule == NotNullNoInherit || accepts_null(rule),
      )
    })
  let statements = [
    create_table(name, plans, ""),
    "create table " <> child <> " () inherits (" <> name <> ")",
    ..dropped
  ]
  #(statements, [Target(name, 0, base), Target(child, 100, child_columns)])
}

/// A table partitioned by id: ids below 100 go to the low partition, the
/// others to the high one. The low partition can have a NOT NULL or a
/// CHECK on one plain column that the table does not have.
fn partitioned(
  random: Random,
  name: String,
  plans: List(ColumnPlan),
  base: List(TargetColumn),
) -> #(List(String), List(Target), Random) {
  let plain =
    list.filter(plans, fn(plan) { plan.rule == Plain })
    |> list.map(fn(plan) { plan.name })
  let #(column, random) = random.choose(random, plain, "")
  let #(not_null, random) = random.chance(random, 0.5)
  let low = name <> "_low"
  let plan = list.find(plans, fn(plan) { plan.name == column })
  let #(constraint, low_rejects_null) = case plan, not_null {
    Error(Nil), _ -> #("", False)
    Ok(plan), True -> #(" (" <> plan.name <> " not null)", True)
    Ok(plan), False -> #(
      " (constraint "
        <> low
        <> "_check check ("
        <> plan.name
        <> " <> "
        <> excluded_value(plan.kind)
        <> "))",
      False,
    )
  }
  let low_columns =
    list.map(base, fn(target) {
      TargetColumn(
        ..target,
        accepts_null: target.accepts_null
          && !{ low_rejects_null && target.name == column },
      )
    })
  let statements = [
    create_table(name, plans, " partition by range (id)"),
    "create table "
      <> low
      <> " partition of "
      <> name
      <> constraint
      <> " for values from (minvalue) to (100)",
    "create table "
      <> name
      <> "_high partition of "
      <> name
      <> " for values from (100) to (maxvalue)",
  ]
  #(statements, [Target(name, 0, low_columns), Target(name, 100, base)], random)
}

/// A table with rows that hold NULL in a column whose NOT NULL constraint
/// is NOT VALID (PostgreSQL 18 and newer). The rows are there before the
/// data sets, and the data sets do not fill this table.
fn legacy(
  random: Random,
  name: String,
  plans: List(ColumnPlan),
) -> #(List(String), List(Target), Random) {
  let plain = list.filter(plans, fn(plan) { plan.rule == Plain })
  let #(chosen, random) =
    random.choose(random, plain, ColumnPlan("", IntKind, Plain))
  let values = fn(id: Int, null_column: String) {
    let others =
      list.map(plans, fn(plan) {
        case plan.name == null_column {
          True -> "null"
          False -> safe_value(plan.kind)
        }
      })
    "(" <> string.join([int.to_string(id), ..others], ", ") <> ")"
  }
  let statements = case chosen.name {
    "" -> [create_table(name, plans, "")]
    column -> [
      create_table(name, plans, ""),
      "insert into "
        <> name
        <> " values "
        <> values(900, column)
        <> ", "
        <> values(901, ""),
      "alter table "
        <> name
        <> " add constraint "
        <> name
        <> "_legacy not null "
        <> column
        <> " not valid",
    ]
  }
  #(statements, [], random)
}

fn safe_value(kind: Kind) -> String {
  case kind {
    IntKind -> "1"
    TextKind -> "'a'"
    BoolKind -> "true"
  }
}

// --- Data sets -------------------------------------------------------------

/// Returns the data sets of a schema. The first one fills every table with
/// five rows, so the parameter checks, which run on the first data set,
/// have rows to change. Then an empty one, and five with random rows.
pub fn data_sets(random: Random, schema: Schema) -> #(List(DataSet), Random) {
  let #(full, random) =
    fill(random, schema.targets, fn(random) { #([1, 2, 3, 4, 5], random) })
  let #(sets, random) =
    random.numbers(1, 5)
    |> list.fold(#([], random), fn(state, number) {
      let #(sets, random) = state
      let #(set, random) =
        fill(random, schema.targets, fn(random) {
          let #(count, random) = random.choose(random, [0, 0, 1, 2, 3, 4], 0)
          random.sample(random, [1, 2, 3, 4, 5], count)
        })
      #([#("random" <> int.to_string(number), set), ..sets], random)
    })
  #([#("full", full), #("empty", ""), ..list.reverse(sets)], random)
}

fn fill(
  random: Random,
  targets: List(Target),
  pick_ids: fn(Random) -> #(List(Int), Random),
) -> #(String, Random) {
  let #(statements, random) =
    list.fold(targets, #([], random), fn(state, target) {
      let #(statements, random) = state
      let #(ids, random) = pick_ids(random)
      let #(rows, random) =
        list.fold(ids, #([], random), fn(state, id) {
          let #(rows, random) = state
          let #(row, random) = row_values(random, target, id)
          #([row, ..rows], random)
        })
      let statement = case rows {
        [] -> []
        _ -> [
          "insert into "
          <> target.name
          <> " values "
          <> string.join(list.reverse(rows), ", "),
        ]
      }
      #(list.append(statements, statement), random)
    })
  #(string.join(statements, "; "), random)
}

fn row_values(random: Random, target: Target, id: Int) -> #(String, Random) {
  let #(values, random) =
    list.fold(target.columns, #([], random), fn(state, column) {
      let #(values, random) = state
      let #(value, random) = column_value(random, column, id + target.id_offset)
      #([value, ..values], random)
    })
  #("(" <> string.join(list.reverse(values), ", ") <> ")", random)
}

fn column_value(
  random: Random,
  column: TargetColumn,
  id: Int,
) -> #(String, Random) {
  let #(value, random) = case column.kind {
    IntKind -> {
      let #(number, random) = random.between(random, 1, 3)
      #(int.to_string(number), random)
    }
    TextKind -> random.choose(random, ["'a'", "'b'"], "'a'")
    BoolKind -> random.choose(random, ["true", "false"], "true")
  }
  let #(null, random) = random.chance(random, 0.4)
  case column.name, column.accepts_null && null {
    "id", _ -> #(int.to_string(id), random)
    _, True -> #("null", random)
    _, False -> #(value, random)
  }
}
