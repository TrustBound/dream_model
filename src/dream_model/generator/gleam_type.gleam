//// The Gleam type of each PostgreSQL type that generated code supports,
//// with the decoder that reads it and the value function that sends it.
////
//// | PostgreSQL | Gleam |
//// | --- | --- |
//// | `int2`, `int4`, `int8`, `oid` | `Int` |
//// | `float4`, `float8` | `Float` |
//// | `numeric` | `String`, the exact text of `value::text` (`client.numeric_text_decoder()`) |
//// | `text`, `varchar`, `bpchar`, `name`, `citext`, `json`, `jsonb`, enums | `String` |
//// | `bool` | `Bool` |
//// | `bytea`, `uuid` | `BitArray` (a `uuid` is its 16 bytes) |
//// | `timestamp`, `timestamptz` | `client.Timestamp` (`timestamptz` is read with `client.timestamp_with_time_zone_decoder()`) |
//// | `date` | `client.Date` |
//// | `time` | `client.TimeOfDay` |
//// | an array of a supported type | `List(Option(T))` |
////
//// A domain has the type of its base type. Every other type is refused.
////
//// A query with a `numeric` result column, also in an array or a domain,
//// reads each `numeric` value as text (`client.numeric_as_text`). A
//// `numeric` parameter is sent as text (`client.numeric_text`), which
//// PostgreSQL parses. An array of `numeric` cannot be a parameter: the
//// driver sends an array in binary, and a `numeric` element as text is not
//// possible there. The SQL can take a `text[]` and cast it, as
//// `$1::text[]::numeric[]`.
////
//// PostgreSQL never forbids a NULL element in an array, so each element of
//// a `List` is an `Option`, unless a `-- not null elements:` hint promised
//// that the elements are never NULL. A `timestamp`, `timestamptz` or `date` value
//// can be `infinity` or `-infinity`, which a `Timestamp` or a `Date`
//// cannot hold: the decoder fails such a value with a message that names
//// the column.

import dream_model/nullability.{type AnalysisError, type Analyzer}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string

/// A Gleam type of a column or a parameter.
pub type GleamType {
  IntType
  FloatType
  /// A `numeric`: a `String`, the exact text of the number, read with
  /// `client.numeric_text_decoder()`.
  NumericType
  StringType
  BoolType
  BitArrayType
  /// A `timestamp`.
  TimestampType
  /// A `timestamptz`: the same Gleam type as a `timestamp`, read with
  /// another decoder.
  TimestampWithTimeZoneType
  DateType
  TimeOfDayType
  ListType(element: GleamType)
}

/// The catalog facts of one PostgreSQL type.
pub type TypeFacts {
  TypeFacts(
    name: String,
    schema: String,
    /// `typtype`: `b` base, `d` domain, `e` enum, and so on.
    kind: String,
    /// `typcategory`: `A` for an array.
    category: String,
    element: Int,
    base: Int,
    /// The name as `format_type` writes it, for example `interval`.
    display_name: String,
  )
}

/// The facts of the types read so far, by oid.
pub type Types =
  Dict(Int, TypeFacts)

const types_sql =
  "with recursive types(oid) as (
  select oid from unnest($1::pg_catalog.oid[]) as oid
  union
  select next.oid from types
  join pg_catalog.pg_type t on t.oid = types.oid
  cross join lateral (values (t.typelem), (t.typbasetype)) as next(oid)
  where next.oid <> 0
)
select t.oid, t.typname, n.nspname, t.typtype, t.typcategory, t.typelem,
  t.typbasetype, pg_catalog.format_type(t.oid, null)
from types
join pg_catalog.pg_type t on t.oid = types.oid
join pg_catalog.pg_namespace n on n.oid = t.typnamespace"

const integer_names = ["int2", "int4", "int8", "oid"]

const float_names = ["float4", "float8"]

const string_names = ["text", "varchar", "bpchar", "name", "json", "jsonb"]

const bit_array_names = ["bytea", "uuid"]

/// Returns no type facts.
pub fn empty_types() -> Types {
  dict.new()
}

/// Reads the facts of the types and of their element and base types.
pub fn load(
  analyzer: Analyzer,
  oids: List(Int),
) -> Result(Types, AnalysisError) {
  let array =
    "{" <> string.join(list.map(list.unique(oids), int.to_string), ",") <> "}"
  use rows <- result.map(
    nullability.execute(analyzer, types_sql, [Some(array)]),
  )
  list.filter_map(rows, decode_row)
  |> dict.from_list
}

/// Returns the Gleam type of a PostgreSQL type, or the name of the type
/// when it is not supported.
pub fn resolve(types: Types, oid: Int) -> Result(GleamType, String) {
  use facts <- result.try(
    dict.get(types, oid)
    |> result.replace_error("the type with oid " <> int.to_string(oid)),
  )
  let is_array = facts.category == "A" && facts.element != 0
  case facts.kind, is_array {
    "d", _ -> resolve(types, facts.base)
    "e", _ -> Ok(StringType)
    _, True ->
      resolve(types, facts.element)
      |> result.map(ListType)
      |> result.replace_error(facts.display_name)
    _, False -> resolve_base(facts)
  }
}

fn resolve_base(facts: TypeFacts) -> Result(GleamType, String) {
  let name = facts.name
  let in_catalog = facts.schema == "pg_catalog"
  let found = [
    #(in_catalog && list.contains(integer_names, name), IntType),
    #(in_catalog && list.contains(float_names, name), FloatType),
    #(in_catalog && name == "numeric", NumericType),
    #(in_catalog && list.contains(string_names, name), StringType),
    #(name == "citext", StringType),
    #(in_catalog && name == "bool", BoolType),
    #(in_catalog && list.contains(bit_array_names, name), BitArrayType),
    #(in_catalog && name == "timestamp", TimestampType),
    #(in_catalog && name == "timestamptz", TimestampWithTimeZoneType),
    #(in_catalog && name == "date", DateType),
    #(in_catalog && name == "time", TimeOfDayType),
  ]
  list.find(found, fn(pair) { pair.0 })
  |> result.map(fn(pair) { pair.1 })
  |> result.replace_error(facts.display_name)
}

/// Returns the type as generated code writes it, for example
/// `client.Timestamp` or `List(Int)`.
pub fn type_text(gleam_type: GleamType) -> String {
  case gleam_type {
    IntType -> "Int"
    FloatType -> "Float"
    StringType | NumericType -> "String"
    BoolType -> "Bool"
    BitArrayType -> "BitArray"
    TimestampType | TimestampWithTimeZoneType -> "client.Timestamp"
    DateType -> "client.Date"
    TimeOfDayType -> "client.TimeOfDay"
    ListType(element) -> "List(Option(" <> type_text(element) <> "))"
  }
}

/// Returns the type of an array whose elements a `-- not null elements:`
/// hint promised are never NULL, for example `List(String)`.
pub fn promised_list_text(element: GleamType) -> String {
  "List(" <> type_text(element) <> ")"
}

/// Returns True for a `numeric`, also as the element of an array. A query
/// with such a result column needs `client.numeric_as_text`.
pub fn has_numeric(gleam_type: GleamType) -> Bool {
  case gleam_type {
    NumericType -> True
    ListType(element) -> has_numeric(element)
    _ -> False
  }
}

/// Returns the decoder of the type for a column, for example
/// `decode.int`. A decoder of a time or a date fails an infinite value
/// with a message that names the column, which `column_literal` gives as
/// a Gleam string literal.
pub fn decoder_text(gleam_type: GleamType, column_literal: String) -> String {
  case gleam_type {
    IntType -> "decode.int"
    FloatType -> "decode.float"
    NumericType -> "client.numeric_text_decoder()"
    StringType -> "decode.string"
    BoolType -> "decode.bool"
    BitArrayType -> "decode.bit_array"
    TimestampType ->
      finite(
        "client.finite_timestamp",
        "client.timestamp_decoder()",
        column_literal,
      )
    TimestampWithTimeZoneType ->
      finite(
        "client.finite_timestamp",
        "client.timestamp_with_time_zone_decoder()",
        column_literal,
      )
    DateType ->
      finite(
        "client.finite_date",
        "client.calendar_date_decoder()",
        column_literal,
      )
    TimeOfDayType -> "client.calendar_time_of_day_decoder()"
    ListType(element) ->
      "decode.list(decode.optional("
      <> decoder_text(element, column_literal)
      <> "))"
  }
}

fn finite(wrapper: String, decoder: String, column_literal: String) -> String {
  wrapper <> "(" <> decoder <> ", " <> column_literal <> ")"
}

/// Returns the value function of the type as a function, for example
/// `client.int` or `client.array(client.nullable(client.int, _), _)`.
pub fn encoder_text(gleam_type: GleamType) -> String {
  case gleam_type {
    IntType -> "client.int"
    FloatType -> "client.float"
    NumericType -> "client.numeric_text"
    StringType -> "client.text"
    BoolType -> "client.bool"
    BitArrayType -> "client.bytea"
    TimestampType | TimestampWithTimeZoneType -> "client.timestamp"
    DateType -> "client.calendar_date"
    TimeOfDayType -> "client.calendar_time_of_day"
    ListType(element) ->
      "client.array(" <> element_encoder_text(element) <> ", _)"
  }
}

/// Returns the call that makes the value of `argument`, for example
/// `client.int(id)`, or `client.nullable(client.int, id)` when the
/// argument is optional.
pub fn encode_call(
  gleam_type: GleamType,
  argument: String,
  optional: Bool,
) -> String {
  case optional, gleam_type {
    True, _ ->
      "client.nullable(" <> encoder_text(gleam_type) <> ", " <> argument <> ")"
    False, ListType(element) ->
      "client.array("
      <> element_encoder_text(element)
      <> ", "
      <> argument
      <> ")"
    False, _ -> encoder_text(gleam_type) <> "(" <> argument <> ")"
  }
}

/// The value function of an array element, which can be NULL.
fn element_encoder_text(element: GleamType) -> String {
  "client.nullable(" <> encoder_text(element) <> ", _)"
}

fn decode_row(row: List(Option(String))) -> Result(#(Int, TypeFacts), Nil) {
  use oid <- result.try(get_integer(row, 0))
  use name <- result.try(get_text(row, 1))
  use schema <- result.try(get_text(row, 2))
  use kind <- result.try(get_text(row, 3))
  use category <- result.try(get_text(row, 4))
  use element <- result.try(get_integer(row, 5))
  use base <- result.try(get_integer(row, 6))
  use display_name <- result.map(get_text(row, 7))
  #(
    oid,
    TypeFacts(name:, schema:, kind:, category:, element:, base:, display_name:),
  )
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
