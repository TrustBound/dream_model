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
////   `NOT NULL ... NOT VALID` constraint;
//// - a column can have a type with a length or a precision (`varchar(n)`,
////   `char(n)`, `numeric(p,s)`, `timestamp(p)`), whose length coercion
////   keeps a stored NULL as NULL, or be a `timestamp` or an `int[]`;
//// - a column of a simple table or of a table with a child table can have
////   a unique constraint or a unique index, which an `ON CONFLICT` can
////   name.
////
//// A data set fills the tables with rows: NULL in the columns that accept
//// it, arrays with NULL elements, distinct values in the unique columns,
//// and rows that do not match the rows of other tables.

import fuzz/random.{type Random}
import gleam/int.{to_string}
import gleam/list.{append, filter, find, flat_map, flatten, fold, map, reverse}
import gleam/string.{join}

/// The type of a value.
pub type Kind {
  IntKind
  TextKind
  BoolKind
  TimestampKind
  IntArrayKind
}

/// A table or view that queries read: its name and its columns.
pub type Relation {
  Relation(name: String, columns: List(#(String, Kind)))
}

/// A column of a table that a data set fills.
pub type TargetColumn {
  TargetColumn(name: String, kind: Kind, accepts_null: Bool, unique: Bool)
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
    /// The SQL type of each column, by `table.column`, for example
    /// `#("t0.k1", "varchar(10)")`.
    column_types: List(#(String, String)),
    /// The conflict targets of each table other than its primary key, for
    /// example `#("t0", "(k1)")` or `#("t0", "on constraint t0_k1_key")`.
    conflict_targets: List(#(String, String)),
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

type Uniqueness {
  NotUnique
  UniqueConstraint
  UniqueIndex
}

type ColumnPlan {
  ColumnPlan(
    name: String,
    kind: Kind,
    rule: Rule,
    /// The SQL type without the domain, for example `varchar(10)`.
    sql_type: String,
    uniqueness: Uniqueness,
  )
}

/// What a table adds to the schema.
type TableParts {
  TableParts(
    relation: Relation,
    statements: List(String),
    targets: List(Target),
    column_types: List(#(String, String)),
    conflict_targets: List(#(String, String)),
  )
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
create domain d_not_null_timestamp as timestamp not null;
create domain d_not_null_int_array as int[] not null;
create domain d_check_int as int check (value <> 0);
create domain d_check_text as text check (value <> '');
create domain d_check_timestamp as timestamp
  check (value <> '2000-01-01 00:00:00');
create domain d_check_int_array as int[] check (value <> '{}')"

/// Functions that are not strict and reject NULL: a parameter inside one
/// of them is not stored straight, so it must stay required.
const required_functions =
  "create function fuzz_required_int(value int) returns int
  language plpgsql as $$ begin if value is null then
  raise exception 'value required'; end if; return value; end $$;
create function fuzz_required_text(value text) returns text
  language plpgsql as $$ begin if value is null then
  raise exception 'value required'; end if; return value; end $$;
create function fuzz_required_timestamp(value timestamp) returns timestamp
  language plpgsql as $$ begin if value is null then
  raise exception 'value required'; end if; return value; end $$;
create function fuzz_required_int_array(value int[]) returns int[]
  language plpgsql as $$ begin if value is null then
  raise exception 'value required'; end if; return value; end $$"

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
    |> fold(#([], random), fn(state, index) {
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
  let tables = reverse(tables)
  let schema =
    Schema(
      tables: map(tables, fn(table) { table.relation }),
      statements: [
        domains,
        required_functions,
        ..flat_map(tables, fn(table) { table.statements })
      ],
      targets: flat_map(tables, fn(table) { table.targets }),
      column_types: flat_map(tables, fn(table) { table.column_types }),
      conflict_targets: flat_map(tables, fn(table) { table.conflict_targets }),
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
) -> #(TableParts, Random) {
  let name = "t" <> to_string(index)
  let #(count, random) = random.between(random, 1, 3)
  let #(plans, random) =
    random.numbers(0, count - 1)
    |> fold(#([], random), fn(state, number) {
      let #(plans, random) = state
      let #(plan, random) = generate_column(random, number, shape, version)
      #([plan, ..plans], random)
    })
  let plans = reverse(plans)
  let relation =
    Relation(name, [
      #("id", IntKind),
      ..map(plans, fn(plan) { #(plan.name, plan.kind) })
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
  let unique_indexes =
    filter(plans, fn(plan) { plan.uniqueness == UniqueIndex })
    |> map(fn(plan) {
      "create unique index "
      <> name
      <> "_"
      <> plan.name
      <> "_index on "
      <> name
      <> " ("
      <> plan.name
      <> ")"
    })
  let column_types =
    map(plans, fn(plan) { #(name <> "." <> plan.name, column_type(plan)) })
  let conflict_targets =
    flat_map(plans, fn(plan) {
      case plan.uniqueness {
        NotUnique -> []
        UniqueIndex -> [#(name, "(" <> plan.name <> ")")]
        UniqueConstraint -> [
          #(name, "(" <> plan.name <> ")"),
          #(name, "on constraint " <> name <> "_" <> plan.name <> "_key"),
        ]
      }
    })
  let parts =
    TableParts(
      relation:,
      statements: flatten([statements, unique_indexes, trigger]),
      targets:,
      column_types:,
      conflict_targets:,
    )
  #(parts, random)
}

fn generate_column(
  random: Random,
  number: Int,
  shape: TableShape,
  version: Int,
) -> #(ColumnPlan, Random) {
  let #(kind, random) =
    random.weighted(
      random,
      [
        #(0.35, IntKind),
        #(0.35, TextKind),
        #(0.15, TimestampKind),
        #(0.15, IntArrayKind),
      ],
      IntKind,
    )
  let #(sql_type, random) = random.choose(random, sql_types(kind), "int")
  // A unique constraint of a partitioned table must hold the partition
  // key, and the rows of a legacy table repeat their values.
  let unique_weight = case shape == Simple || shape == WithChild {
    True -> 0.1
    False -> 0.0
  }
  let #(uniqueness, random) =
    random.weighted(
      random,
      [
        #(0.8, NotUnique),
        #(unique_weight, UniqueConstraint),
        #(unique_weight, UniqueIndex),
      ],
      NotUnique,
    )
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
  let plan =
    ColumnPlan(
      name: "k" <> to_string(number),
      kind:,
      rule:,
      sql_type:,
      uniqueness:,
    )
  #(plan, random)
}

/// The SQL types of a kind: the plain type, and the types with a length
/// or a precision, whose length coercion keeps NULL as NULL.
fn sql_types(kind: Kind) -> List(String) {
  case kind {
    IntKind -> ["int", "int", "numeric(8,2)", "numeric(6,0)"]
    TextKind -> ["text", "text", "varchar(10)", "char(4)"]
    BoolKind -> ["boolean"]
    TimestampKind -> ["timestamp", "timestamp(0)", "timestamp(3)"]
    IntArrayKind -> ["int[]"]
  }
}

/// A table without a child table can have a BEFORE trigger that rejects
/// NULL in one of its plain columns.
fn pick_trigger_column(
  random: Random,
  plans: List(ColumnPlan),
) -> #(String, Random) {
  let plain =
    filter(plans, fn(plan) { plan.rule == Plain })
    |> map(fn(plan) { plan.name })
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
    TargetColumn("id", IntKind, False, False),
    ..map(plans, fn(plan) {
      TargetColumn(
        plan.name,
        plan.kind,
        accepts_null(plan.rule) && plan.name != trigger_column,
        plan.uniqueness != NotUnique,
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
  let definitions =
    flatten([
      [key],
      map(plans, column_definition),
      flat_map(plans, unique_constraint(name, _)),
    ])
  "create table " <> name <> " (" <> join(definitions, ", ") <> ")" <> tail
}

/// The type of a column as its definition writes it: a domain, or the
/// SQL type.
fn column_type(plan: ColumnPlan) -> String {
  case plan.rule {
    DomainNotNull -> "d_not_null_" <> domain_suffix(plan.kind)
    DomainCheck -> "d_check_" <> domain_suffix(plan.kind)
    Plain | NotNull | NotNullNoInherit | CheckNotNull | CheckValue ->
      plan.sql_type
  }
}

fn domain_suffix(kind: Kind) -> String {
  case kind {
    IntKind -> "int"
    TextKind -> "text"
    BoolKind -> "boolean"
    TimestampKind -> "timestamp"
    IntArrayKind -> "int_array"
  }
}

fn column_definition(plan: ColumnPlan) -> String {
  let start = plan.name <> " " <> column_type(plan)
  let rule = case plan.rule {
    Plain | DomainNotNull | DomainCheck -> ""
    NotNull -> " not null"
    NotNullNoInherit -> " not null no inherit"
    CheckNotNull -> " check (" <> plan.name <> " is not null)"
    CheckValue ->
      " check (" <> plan.name <> " <> " <> excluded_value(plan.kind) <> ")"
  }
  start <> rule
}

/// The table constraint of a column with a unique constraint.
fn unique_constraint(table: String, plan: ColumnPlan) -> List(String) {
  case plan.uniqueness {
    UniqueConstraint -> [
      "constraint "
      <> table
      <> "_"
      <> plan.name
      <> "_key unique ("
      <> plan.name
      <> ")",
    ]
    NotUnique | UniqueIndex -> []
  }
}

/// Returns the SQL name of a kind.
pub fn kind_sql(kind: Kind) -> String {
  case kind {
    IntKind -> "int"
    TextKind -> "text"
    BoolKind -> "boolean"
    TimestampKind -> "timestamp"
    IntArrayKind -> "int[]"
  }
}

fn excluded_value(kind: Kind) -> String {
  case kind {
    IntKind -> "0"
    TextKind | BoolKind -> "''"
    TimestampKind -> "'2000-01-01 00:00:00'"
    IntArrayKind -> "'{}'"
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
    filter(plans, fn(plan) { plan.rule == NotNullNoInherit })
    |> map(fn(plan) {
      "alter table "
      <> child
      <> " alter column "
      <> plan.name
      <> " drop not null"
    })
  let child_columns =
    map(base, fn(column) {
      let plan = find(plans, fn(plan) { plan.name == column.name })
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
    filter(plans, fn(plan) { plan.rule == Plain })
    |> map(fn(plan) { plan.name })
  let #(column, random) = random.choose(random, plain, "")
  let #(not_null, random) = random.chance(random, 0.5)
  let low = name <> "_low"
  let plan = find(plans, fn(plan) { plan.name == column })
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
    map(base, fn(target) {
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
  let plain = filter(plans, fn(plan) { plan.rule == Plain })
  let #(chosen, random) =
    random.choose(
      random,
      plain,
      ColumnPlan("", IntKind, Plain, "int", NotUnique),
    )
  let values = fn(id: Int, null_column: String) {
    let others =
      map(plans, fn(plan) {
        case plan.name == null_column {
          True -> "null"
          False -> safe_value(plan.kind)
        }
      })
    "(" <> join([to_string(id), ..others], ", ") <> ")"
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
    TimestampKind -> "'2024-01-01 10:00:00'"
    IntArrayKind -> "'{1,NULL}'"
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
    |> fold(#([], random), fn(state, number) {
      let #(sets, random) = state
      let #(set, random) =
        fill(random, schema.targets, fn(random) {
          let #(count, random) = random.choose(random, [0, 0, 1, 2, 3, 4], 0)
          random.sample(random, [1, 2, 3, 4, 5], count)
        })
      #([#("random" <> to_string(number), set), ..sets], random)
    })
  #([#("full", full), #("empty", ""), ..reverse(sets)], random)
}

fn fill(
  random: Random,
  targets: List(Target),
  pick_ids: fn(Random) -> #(List(Int), Random),
) -> #(String, Random) {
  let #(statements, random) =
    fold(targets, #([], random), fn(state, target) {
      let #(statements, random) = state
      let #(ids, random) = pick_ids(random)
      let #(rows, random) =
        fold(ids, #([], random), fn(state, id) {
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
          <> join(reverse(rows), ", "),
        ]
      }
      #(append(statements, statement), random)
    })
  #(join(statements, "; "), random)
}

fn row_values(random: Random, target: Target, id: Int) -> #(String, Random) {
  let #(values, random) =
    fold(target.columns, #([], random), fn(state, column) {
      let #(values, random) = state
      let #(value, random) = column_value(random, column, id + target.id_offset)
      #([value, ..values], random)
    })
  #("(" <> join(reverse(values), ", ") <> ")", random)
}

fn column_value(
  random: Random,
  column: TargetColumn,
  id: Int,
) -> #(String, Random) {
  let #(value, random) = case column.kind {
    IntKind -> {
      let #(number, random) = random.between(random, 1, 3)
      #(to_string(number), random)
    }
    TextKind -> random.choose(random, ["'a'", "'b'"], "'a'")
    BoolKind -> random.choose(random, ["true", "false"], "true")
    TimestampKind ->
      random.choose(
        random,
        ["'2024-01-01 10:00:00'", "'2024-01-02 11:30:00.123'"],
        "'2024-01-01 10:00:00'",
      )
    IntArrayKind ->
      random.choose(random, ["'{1,2}'", "'{1,NULL}'", "'{NULL}'"], "'{1,2}'")
  }
  let #(null, random) = random.chance(random, 0.4)
  case column.name, column.accepts_null && null, column.unique {
    "id", _, _ -> #(to_string(id), random)
    _, True, _ -> #("null", random)
    _, False, True -> #(unique_value(column.kind, id), random)
    _, False, False -> #(value, random)
  }
}

/// A value that no other row and no parameter of a query has: the base
/// parameters of the checks are 1, '2024-01-01 10:00:00' and '{1,NULL}'.
fn unique_value(kind: Kind, id: Int) -> String {
  let number = to_string(id)
  case kind {
    IntKind -> to_string(id * 10 + 7)
    TextKind -> "'u" <> number <> "'"
    BoolKind -> "true"
    TimestampKind ->
      "'2024-03-01 00:00:00'::timestamp + interval '" <> number <> " days'"
    IntArrayKind -> "'{" <> to_string(id + 100) <> ",NULL}'"
  }
}
