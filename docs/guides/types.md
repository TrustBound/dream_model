# Types

dream_model gives each column and each parameter a Gleam type from its PostgreSQL type. This guide gives the type of each PostgreSQL type, shows exact numbers, arrays and the values `infinity` and `-infinity`, and tells what to do with a type that dream_model does not support.

## Table of Contents

- [The type of each PostgreSQL type](#the-type-of-each-postgresql-type)
- [Exact numbers](#exact-numbers)
- [Arrays](#arrays)
- [Infinity](#infinity)
- [Types that need a cast](#types-that-need-a-cast)
- [Where to go next](#where-to-go-next)

## The type of each PostgreSQL type

| PostgreSQL | Gleam | Decoder | Value function |
| --- | --- | --- | --- |
| `int2`, `int4`, `int8`, `oid` | `Int` | `decode.int` | `client.int` |
| `float4`, `float8` | `Float` | `decode.float` | `client.float` |
| `numeric` | `String`, the exact text of the number | `client.numeric_text_decoder()` | `client.numeric_text` |
| `text`, `varchar`, `bpchar`, `name`, `citext`, `json`, `jsonb`, an enum | `String` | `decode.string` | `client.text` |
| `bool` | `Bool` | `decode.bool` | `client.bool` |
| `bytea` | `BitArray` | `decode.bit_array` | `client.bytea` |
| `uuid` | `BitArray`, the 16 bytes | `decode.bit_array` | `client.bytea` |
| `timestamp` | `client.Timestamp` | `client.finite_timestamp(client.timestamp_decoder(), ...)` | `client.timestamp` |
| `timestamptz` | `client.Timestamp` | `client.finite_timestamp(client.timestamp_with_time_zone_decoder(), ...)` | `client.timestamp` |
| `date` | `client.Date` | `client.finite_date(client.calendar_date_decoder(), ...)` | `client.calendar_date` |
| `time` | `client.TimeOfDay` | `client.calendar_time_of_day_decoder()` | `client.calendar_time_of_day` |
| an array of a supported type | `List(Option(T))`, or `List(T)` with the `-- not null elements:` hint | `decode.list(decode.optional(...))` | `client.array(client.nullable(..., _), _)`, but not for `numeric[]` |
| a domain | the type of its base type | | |

`client.Timestamp`, `client.Date` and `client.TimeOfDay` are the types of `gleam/time`. The generated module names them through `dream_postgres/client`, so it imports no `gleam_time` module.

A column that can be NULL is `Option` of the type in the table. The decoder is then `decode.optional(...)`, and the value function of a parameter is `client.nullable(..., value)`.

The `samples` table of the end-to-end app has a column of each type:

### The samples table <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/schema.sql#L24-L49"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
create table samples (
  id serial primary key,
  small smallint,
  big bigint,
  object oid,
  real_number real,
  double_number double precision,
  amount numeric,
  label varchar(20),
  code char(3),
  short_name name,
  nickname citext,
  document json,
  binary_document jsonb,
  feeling mood,
  flag boolean,
  data bytea,
  identifier uuid,
  happened_at timestamp,
  happened_at_zone timestamptz,
  day date,
  clock time,
  tags text[],
  scores int[],
  rating positive_int
);
```

### The type of a samples row <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L18-L46"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// A row of get.sql.
pub type Sample {
  Sample(
    id: Int,
    small: Option(Int),
    big: Option(Int),
    object: Option(Int),
    real_number: Option(Float),
    double_number: Option(Float),
    amount: Option(String),
    label: Option(String),
    code: Option(String),
    short_name: Option(String),
    nickname: Option(String),
    document: Option(String),
    binary_document: Option(String),
    feeling: Option(String),
    flag: Option(Bool),
    data: Option(BitArray),
    identifier: Option(BitArray),
    happened_at: Option(client.Timestamp),
    happened_at_zone: Option(client.Timestamp),
    day: Option(client.Date),
    clock: Option(client.TimeOfDay),
    tags: Option(List(Option(String))),
    scores: Option(List(Option(Int))),
    rating: Option(Int),
  )
}
```

## Exact numbers

A `numeric` value is a `String`: the exact text of the number, the same text as `value::text` in PostgreSQL. A `Float` cannot hold every `numeric`, for example `0.1` or a number with 30 digits, and it loses the scale, so `1.50` became `1.5`. The text keeps every digit, the scale and the trailing zeros, and also `NaN`, `Infinity` and `-Infinity`. Parse the text in the app, for example with a decimal package, when you need to calculate.

This applies to a result column, to a parameter, to an element of an array, and to a domain over `numeric`. No cast and no hint is necessary. A query with a `numeric` result column calls `client.numeric_as_text`, and the decoder is `client.numeric_text_decoder()`. A parameter is sent as text with `client.numeric_text`, and PostgreSQL parses it:

### A numeric parameter and a numeric column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample/echo_amount.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
-- params: amount
-- not null: exact
select $1::numeric as exact
```

### The generated function <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L65-L84"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from echo_amount.sql.
pub fn echo_amount(
  db: client.Connection,
  amount: String,
) -> Result(String, client.ModelQueryError) {
  "select $1::numeric as exact"
  |> client.query
  |> client.parameter(client.numeric_text(amount))
  |> client.numeric_as_text
  |> client.returning(decode.at(
    [0],
    client.promised_not_null(
      client.numeric_text_decoder(),
      "src/app/models/sample/echo_amount.sql",
      "exact",
    ),
  ))
  |> client.execute(db)
  |> one_row("sample.echo_amount", [])
}
```

The end-to-end app sends each text and compares the result with it. Each one comes back exactly:

### Exact round trips <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L38-L44"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.echo_amount of 1.50: Ok(#("1.50", True))
| sample.echo_amount of 123456789012345678901234567890.123456789012345678901234567890: Ok(#("123456789012345678901234567890.123456789012345678901234567890", True))
| sample.echo_amount of 0.000000000000000000000000000000000000000000000000001: Ok(#("0.000000000000000000000000000000000000000000000000001", True))
| sample.echo_amount of -42.10: Ok(#("-42.10", True))
| sample.echo_amount of NaN: Ok(#("NaN", True))
| sample.echo_amount of Infinity: Ok(#("Infinity", True))
| sample.echo_amount of -Infinity: Ok(#("-Infinity", True))
```

A text that is not a number fails in PostgreSQL with the error `22P02` (`invalid input syntax for type numeric`), and the function gives `QueryFailed`, as for every other database error. [Errors](errors.md#a-numeric-text-that-is-not-a-number) tells why, and how to check the text first.

### An array of numeric as a parameter

The driver sends an array in binary, and a `numeric` element as text is not possible there. So dream_model refuses a `numeric[]` parameter, with the file and the line of the parameter:

`the parameter $1 is an array of numeric, which dream_model cannot send exactly; take a text array and cast it in the SQL, for example $1::text[]::numeric[], and the parameter is a List(Option(String))`

Cast a text array in the SQL. The parameter is then a `text[]`, so the function takes a `List(Option(String))`, and PostgreSQL parses each element. A `numeric[]` result column needs no cast: each element is read as exact text.

### Send an array of numbers as text <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample/amounts.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
-- params: amounts
select $1::text[]::numeric[] as amounts
```

### The generated function of the cast <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L48-L63"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from amounts.sql.
pub fn amounts(
  db: client.Connection,
  amounts: List(Option(String)),
) -> Result(Option(List(Option(String))), client.ModelQueryError) {
  "select $1::text[]::numeric[] as amounts"
  |> client.query
  |> client.parameter(client.array(client.nullable(client.text, _), amounts))
  |> client.numeric_as_text
  |> client.returning(decode.at(
    [0],
    decode.optional(decode.list(decode.optional(client.numeric_text_decoder()))),
  ))
  |> client.execute(db)
  |> one_row("sample.amounts", [])
}
```

### The array round trip <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L46"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.amounts of a text array: Ok(Some([Some("1.50"), None, Some("-0.001")]))
```

The cast takes the parameter out of a store, so dream_model cannot name it from a column, and the parameter is required. The `-- params:` hint names it. Write `-- params: amounts?` to make it `Option`.

## Arrays

PostgreSQL never forbids a NULL element in an array. A NOT NULL constraint on an array column forbids only a NULL array. So each element of a `List` is an `Option`. An array column that can be NULL is `Option(List(Option(T)))`.

### Read an array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L235-L238"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
  use tags <- decode.field(
    21,
    decode.optional(decode.list(decode.optional(decode.string))),
  )
```

### Send an array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L161-L164"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
  |> client.parameter(client.nullable(
    client.array(client.nullable(client.text, _), _),
    tags,
  ))
```

The end-to-end app stores `["a", NULL]` and reads it back:

### A NULL element round trip <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L34"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| array with a NULL element round trip: Ok(True)
```

To get `List(String)`, promise that the elements are never NULL with the `-- not null elements:` hint. The generated code checks the promise on each row: a NULL element gives `QueryFailed` with a message that names the file and the column. The hint is only about the elements. A column that can be NULL stays `Option`, so `tags` is an `Option(List(String))`:

### Promise the elements of an array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample/tags.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
-- not null elements: tags
select tags from samples where id = $1
```

### The generated function of the promise <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L175-L193"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from tags.sql.
pub fn tags(
  db: client.Connection,
  id: Int,
) -> Result(Option(List(String)), client.ModelQueryError) {
  "select tags from samples where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.returning(decode.at(
    [0],
    decode.optional(client.promised_elements_not_null(
      decode.string,
      "src/app/models/sample/tags.sql",
      "tags",
    )),
  ))
  |> client.execute(db)
  |> one_row("sample.tags", [])
}
```

### A NULL element breaks the promise <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L48-L50"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.tags with a NULL element: QueryFailed the SQL file src/app/models/sample/tags.sql promised the elements of tags are never NULL, and PostgreSQL returned NULL (cause: UnexpectedResultType)
| sample.tags with no NULL element: Ok(Some(["a", "b"]))
| sample.tags of a NULL array: Ok(None)
```

[Hints](hints.md#not-null-elements) gives the rules of the hint. To drop the NULL elements instead, use `array_remove(tags, null)` in the query and promise the elements.

## Infinity

A `timestamp`, `timestamptz` or `date` column can hold `'infinity'` and `'-infinity'`. A `client.Timestamp` or a `client.Date` cannot hold them. The generated decoder fails such a row, and the function gives `QueryFailed`. The message names the function, the column and the Gleam type:

### The message of each infinite value <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L35-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: QueryFailed sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite timestamptz: QueryFailed sample.get: the column happened_at_zone holds -infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite date: QueryFailed sample.get: the column day holds infinity, which the Gleam type Date cannot hold (cause: UnexpectedResultType)
```

If a column can hold infinity, change the query. Skip the infinite rows with `isfinite`:

### Skip the infinite rows <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/types/finite_rows.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many
select id, happened_at from samples
where isfinite(happened_at)
```

Or cast the column to `text`. The field is then `Option(String)`, with the text `infinity` or `-infinity`:

### Read the time as text <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/types/time_as_text.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many
select id, happened_at::text as happened_at from samples
```

## Types that need a cast

dream_model refuses every other type, for example `interval`, `inet`, `point`, a range or a composite type. For a result column, the message is:

`the column 'span' has the PostgreSQL type interval, which dream_model does not support; cast it in the SQL to a supported type, for example span::text`

Cast the column in the SQL:

### Read an interval as text <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/types/interval_as_text.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many
select id, span::text as span from spans
```

For a parameter, the message is `the parameter $1 has the PostgreSQL type interval, which dream_model does not support; cast it in the SQL from a supported type, for example $1::text::interval`. Write `$1::text::interval` in the SQL, and give the function a `String`.

## Where to go next

- [Why is this column Option?](why-option.md): when a type is `Option`
- [Errors](errors.md): the message of an infinite value and the other errors
