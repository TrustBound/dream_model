# Types

dream_model gives each column and each parameter a Gleam type from its PostgreSQL type. This guide gives the type of each PostgreSQL type, shows arrays and the values `infinity` and `-infinity`, and tells what to do with a type that dream_model does not support.

## Table of Contents

- [The type of each PostgreSQL type](#the-type-of-each-postgresql-type)
- [Arrays](#arrays)
- [Infinity](#infinity)
- [Types that need a cast](#types-that-need-a-cast)
- [Where to go next](#where-to-go-next)

## The type of each PostgreSQL type

| PostgreSQL | Gleam | Decoder | Value function |
| --- | --- | --- | --- |
| `int2`, `int4`, `int8`, `oid` | `Int` | `decode.int` | `client.int` |
| `float4`, `float8` | `Float` | `decode.float` | `client.float` |
| `numeric` | `Float` | `client.numeric_decoder()` | `client.float` |
| `text`, `varchar`, `bpchar`, `name`, `citext`, `json`, `jsonb`, an enum | `String` | `decode.string` | `client.text` |
| `bool` | `Bool` | `decode.bool` | `client.bool` |
| `bytea` | `BitArray` | `decode.bit_array` | `client.bytea` |
| `uuid` | `BitArray`, the 16 bytes | `decode.bit_array` | `client.bytea` |
| `timestamp` | `client.Timestamp` | `client.finite_timestamp(client.timestamp_decoder(), ...)` | `client.timestamp` |
| `timestamptz` | `client.Timestamp` | `client.finite_timestamp(client.timestamp_with_time_zone_decoder(), ...)` | `client.timestamp` |
| `date` | `client.Date` | `client.finite_date(client.calendar_date_decoder(), ...)` | `client.calendar_date` |
| `time` | `client.TimeOfDay` | `client.calendar_time_of_day_decoder()` | `client.calendar_time_of_day` |
| an array of a supported type | `List(Option(T))` | `decode.list(decode.optional(...))` | `client.array(client.nullable(..., _), _)` |
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

### The type of a samples row <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L19-L47"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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
    amount: Option(Float),
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

## Arrays

PostgreSQL never forbids a NULL element in an array. A NOT NULL constraint on an array column forbids only a NULL array. So each element of a `List` is an `Option`, and no hint changes that. An array column that can be NULL is `Option(List(Option(T)))`.

### Read an array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L176-L179"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
  use tags <- decode.field(
    21,
    decode.optional(decode.list(decode.optional(decode.string))),
  )
```

### Send an array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/sample.gleam#L120-L123"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
  |> client.parameter(client.nullable(
    client.array(client.nullable(client.text, _), _),
    tags,
  ))
```

The end-to-end app stores `["a", NULL]` and reads it back:

### A NULL element round trip <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L33"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| array with a NULL element round trip: Ok(True)
```

To get `List(String)`, drop the NULL elements in the query, for example `array_remove(tags, null)`. The value is then a computed value, so it is `Option` unless you promise it with `-- not null:`. The elements stay `Option`.

## Infinity

A `timestamp`, `timestamptz` or `date` column can hold `'infinity'` and `'-infinity'`. A `client.Timestamp` or a `client.Date` cannot hold them. The generated decoder fails such a row, and the function gives `InternalServerError` (500). The message names the function, the column and the Gleam type:

### The message of each infinite value <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L34-L36"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: 500 sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold
| sample.get of an infinite timestamptz: 500 sample.get: the column happened_at_zone holds -infinity, which the Gleam type Timestamp cannot hold
| sample.get of an infinite date: 500 sample.get: the column day holds infinity, which the Gleam type Date cannot hold
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
