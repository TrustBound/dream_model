//// Tests for `dream_model/generator/gleam_type`, on the generator database.

import dream_model/generator/gleam_type.{
  type GleamType, BitArrayType, BoolType, DateType, FloatType, IntType, ListType,
  NumericType, StringType, TimeOfDayType, TimestampType,
  TimestampWithTimeZoneType, decoder_text, empty_types, encode_call,
  encoder_text, has_numeric, load, promised_list_text, resolve, type_text,
}
import dream_model/nullability.{close, connect, execute}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database.{url}
import gleam/int.{parse}
import gleam/list.{append, map}
import gleam/option.{Some}
import gleam/string.{inspect}

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/generator/gleam_type", [
    resolve_tests(version),
    text_tests(),
  ])
}

/// Resolves the type that a SQL type name names, as `regtype` reads it.
fn resolve_named(version: Int, type_name: String) -> Result(GleamType, String) {
  let assert Ok(analyzer) = connect(url(version))
  let assert Ok([[Some(oid)]]) =
    execute(analyzer, "select $1::text::regtype::oid::text", [
      Some(type_name),
    ])
  let assert Ok(oid) = parse(oid)
  let assert Ok(types) = load(analyzer, [oid])
  let _ = close(analyzer)
  resolve(types, oid)
}

fn resolve_tests(version: Int) {
  let cases = [
    #("smallint", Ok(IntType)),
    #("integer", Ok(IntType)),
    #("bigint", Ok(IntType)),
    #("oid", Ok(IntType)),
    #("real", Ok(FloatType)),
    #("double precision", Ok(FloatType)),
    #("numeric", Ok(NumericType)),
    #("text", Ok(StringType)),
    #("varchar", Ok(StringType)),
    #("char", Ok(StringType)),
    #("name", Ok(StringType)),
    #("citext", Ok(StringType)),
    #("json", Ok(StringType)),
    #("jsonb", Ok(StringType)),
    #("mood", Ok(StringType)),
    #("boolean", Ok(BoolType)),
    #("bytea", Ok(BitArrayType)),
    #("uuid", Ok(BitArrayType)),
    #("timestamp", Ok(TimestampType)),
    #("timestamptz", Ok(TimestampWithTimeZoneType)),
    #("date", Ok(DateType)),
    #("time", Ok(TimeOfDayType)),
    #("positive_int", Ok(IntType)),
    #("money_amount", Ok(NumericType)),
    #("numeric[]", Ok(ListType(NumericType))),
    #("integer[]", Ok(ListType(IntType))),
    #("mood[]", Ok(ListType(StringType))),
    #("text[][]", Ok(ListType(StringType))),
    #("interval", Error("interval")),
    #("interval[]", Error("interval[]")),
    #("\"char\"", Error("\"char\"")),
  ]
  group(
    "resolve",
    map(cases, fn(example) {
      let #(type_name, expected) = example
      it("resolves " <> type_name <> " to " <> inspect(expected), fn() {
        // Act
        let found = resolve_named(version, type_name)

        // Assert
        found
        |> should
        |> be_equal(expected)
        |> or_fail_with("Expected " <> inspect(expected))
      })
    })
      |> append([
        it("refuses a type that load did not read", fn() {
          // Act
          let found = resolve(empty_types(), 999_999)

          // Assert
          found
          |> should
          |> be_equal(Error("the type with oid 999999"))
          |> or_fail_with("Expected the unknown oid")
        }),
      ]),
  )
}

fn text_tests() {
  let every_type = [
    IntType,
    FloatType,
    NumericType,
    StringType,
    BoolType,
    BitArrayType,
    TimestampType,
    TimestampWithTimeZoneType,
    DateType,
    TimeOfDayType,
    ListType(ListType(IntType)),
  ]
  group("texts", [
    it("type_text writes every type", fn() {
      // Act
      let texts = map(every_type, type_text)

      // Assert
      texts
      |> should
      |> be_equal([
        "Int", "Float", "String", "String", "Bool", "BitArray",
        "client.Timestamp", "client.Timestamp", "client.Date",
        "client.TimeOfDay", "List(Option(List(Option(Int))))",
      ])
      |> or_fail_with("Expected the type of each")
    }),
    it("decoder_text writes every decoder", fn() {
      // Act
      let texts = map(every_type, decoder_text(_, "\"day\""))

      // Assert
      texts
      |> should
      |> be_equal([
        "decode.int", "decode.float", "client.numeric_text_decoder()",
        "decode.string", "decode.bool", "decode.bit_array",
        "client.finite_timestamp(client.timestamp_decoder(), \"day\")",
        "client.finite_timestamp(client.timestamp_with_time_zone_decoder(), \"day\")",
        "client.finite_date(client.calendar_date_decoder(), \"day\")",
        "client.calendar_time_of_day_decoder()",
        "decode.list(decode.optional(decode.list(decode.optional(decode.int))))",
      ])
      |> or_fail_with("Expected the decoder of each")
    }),
    it("encoder_text writes every value function", fn() {
      // Act
      let texts = map(every_type, encoder_text)

      // Assert
      texts
      |> should
      |> be_equal([
        "client.int", "client.float", "client.numeric_text", "client.text",
        "client.bool", "client.bytea", "client.timestamp", "client.timestamp",
        "client.calendar_date", "client.calendar_time_of_day",
        "client.array(client.nullable(client.array(client.nullable(client.int, _), _), _), _)",
      ])
      |> or_fail_with("Expected the value function of each")
    }),
    it("encode_call calls the value function", fn() {
      // Act
      let text = encode_call(IntType, "id", False)

      // Assert
      text
      |> should
      |> be_equal("client.int(id)")
      |> or_fail_with("Expected client.int(id)")
    }),
    it("encode_call sends a list with client.array", fn() {
      // Act
      let text = encode_call(ListType(IntType), "ids", False)

      // Assert
      text
      |> should
      |> be_equal("client.array(client.nullable(client.int, _), ids)")
      |> or_fail_with("Expected client.array of client.nullable elements")
    }),
    it("encode_call sends an optional list with client.nullable", fn() {
      // Act
      let text = encode_call(ListType(IntType), "ids", True)

      // Assert
      text
      |> should
      |> be_equal(
        "client.nullable(client.array(client.nullable(client.int, _), _), ids)",
      )
      |> or_fail_with("Expected client.nullable of client.array")
    }),
    it("encode_call sends a numeric as text", fn() {
      // Act
      let text = encode_call(NumericType, "amount", False)

      // Assert
      text
      |> should
      |> be_equal("client.numeric_text(amount)")
      |> or_fail_with("Expected client.numeric_text(amount)")
    }),
    it("encode_call sends an optional numeric with client.nullable", fn() {
      // Act
      let text = encode_call(NumericType, "amount", True)

      // Assert
      text
      |> should
      |> be_equal("client.nullable(client.numeric_text, amount)")
      |> or_fail_with("Expected client.nullable of client.numeric_text")
    }),
    it("promised_list_text writes a list without Option elements", fn() {
      // Act
      let text = promised_list_text(NumericType)

      // Assert
      text
      |> should
      |> be_equal("List(String)")
      |> or_fail_with("Expected List(String)")
    }),
    it("has_numeric finds a numeric in each type", fn() {
      // Act
      let found =
        map(
          [
            NumericType,
            ListType(NumericType),
            ListType(ListType(NumericType)),
            FloatType,
            ListType(IntType),
            StringType,
          ],
          has_numeric,
        )

      // Assert
      found
      |> should
      |> be_equal([True, True, True, False, False, False])
      |> or_fail_with("Expected True only for numeric and its arrays")
    }),
  ])
}
