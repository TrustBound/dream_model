# Errors

Each generated function returns `Result(row, dream/http/error.Error)`. The error is one of three Dream errors: `NotFound` (404), `Conflict` (409) or `InternalServerError` (500). A controller gives it to the client with `error.to_status_code` and `error.message`. This guide gives each error, when it happens, and its exact text.

## Table of Contents

- [The errors at a glance](#the-errors-at-a-glance)
- [Not found](#not-found)
- [Unique violation](#unique-violation)
- [More than one row](#more-than-one-row)
- [Broken promise](#broken-promise)
- [Infinite value](#infinite-value)
- [Every other failure](#every-other-failure)
- [Answer with the error](#answer-with-the-error)
- [Where to go next](#where-to-go-next)

## The errors at a glance

| When | Error | Text |
| --- | --- | --- |
| `returns: one` gets no row | `NotFound` (404) | The `not found` hint, or `<Type> not found` |
| A `unique` hint names the violated constraint | `Conflict` (409) | The text of the hint |
| `returns: one` or `maybe` gets more than one row | `InternalServerError` (500) | `<model>.<function> returned more than one row` |
| A `not null` column is NULL | `InternalServerError` (500) | `the SQL file <file> promised the column <column> is never NULL, and PostgreSQL returned NULL` |
| A time or date column holds infinity | `InternalServerError` (500) | `<model>.<function>: the column <column> holds infinity, which the Gleam type Timestamp cannot hold` |
| Any other failure | `InternalServerError` (500) | `<model>.<function> failed` |

`<model>.<function>` is the last part of the module name and the name of the function, for example `user.find`. No text holds SQL, a parameter or a value of a row.

Each generated module maps a query error with the same helper:

### The error helper of a generated module <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L224-L240"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn query_error_to_error(
  query_error: client.QueryError,
  query_name: String,
  unique: List(#(String, String)),
) -> Error {
  let conflict = unique_message(client.violated_constraint(query_error), unique)
  let promise = client.broken_promise(query_error)
  let infinite = client.infinite_value(query_error)
  case conflict, promise, infinite {
    Ok(message), _, _ -> error.Conflict(message)
    Error(Nil), Ok(message), _ -> error.InternalServerError(message)
    Error(Nil), Error(Nil), Ok(message) ->
      error.InternalServerError(query_name <> ": " <> message)
    Error(Nil), Error(Nil), Error(Nil) ->
      error.InternalServerError(query_name <> " failed")
  }
}
```

## Not found

`returns: one` gives `NotFound` when the statement gives no row. The text is the `not found` hint, or `<Type> not found` with the type of the rows, for example `User not found`. `returns: maybe` gives `Ok(None)`, and `returns: many` gives `Ok([])`.

### The row helper of returns: one <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L163-L176"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn single_row(
  rows: List(row),
  query_name: String,
  not_found: String,
) -> Result(row, Error) {
  case rows {
    [row] -> Ok(row)
    [] -> Error(error.NotFound(not_found))
    _ ->
      Error(error.InternalServerError(
        query_name <> " returned more than one row",
      ))
  }
}
```

### A missing user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.find of a missing user: 404 User not found
```

## Unique violation

A `unique` hint maps a violation of its constraint to `Conflict` with the text of the hint. A violation of another constraint is not a `Conflict`: see [Every other failure](#every-other-failure).

### A taken email <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L3"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.create of a taken email: 409 Email already taken
```

## More than one row

`returns: one` and `returns: maybe` give `InternalServerError` when the statement gives more than one row, with the text `<model>.<function> returned more than one row`. Add a condition on a unique column, or `limit 1`, or use `returns: many`.

## Broken promise

A `-- not null:` hint promises that a computed column is never NULL. The decoder checks the promise on each row. A NULL gives `InternalServerError` with a text that names the file and the column:

### A sum of no rows <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| post.total of a user with no posts: 500 the SQL file src/app/models/post/total.sql promised the column total is never NULL, and PostgreSQL returned NULL
```

Fix the query, for example with `coalesce(sum(id), 0)`, and remove the hint.

## Infinite value

A `timestamp`, `timestamptz` or `date` column can hold `infinity` or `-infinity`, which a Gleam `Timestamp` or `Date` cannot hold. The function gives `InternalServerError` with the name of the function, the column and the Gleam type:

### The message of each infinite value <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L34-L36"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: 500 sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold
| sample.get of an infinite timestamptz: 500 sample.get: the column happened_at_zone holds -infinity, which the Gleam type Timestamp cannot hold
| sample.get of an infinite date: 500 sample.get: the column day holds infinity, which the Gleam type Date cannot hold
```

The [Types](types.md#infinity) guide shows how to change the query.

## Every other failure

Every other error gives `InternalServerError` with the text `<model>.<function> failed`: a connection error, a timeout, a foreign key violation, a check violation, a unique violation with no hint, and so on. The text holds no SQL and no data, so it is safe to send to the client. Log the error in your app if you need the details: call the query yourself with `dream_postgres/client`.

### A delete that a foreign key stops <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L38"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.delete of a user with posts: 500 user.delete failed
```

## Answer with the error

`error.to_status_code` gives the status, and `error.message` gives the text:

### Answer with the user or the error <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/controllers/user_controller.gleam#L9-L17"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Answers with the email of the user, or with the status and the message
/// of the error.
pub fn show(db: client.Connection, id: Int) -> Response {
  case user.find(db, id) {
    Ok(found) -> text_response(200, found.email)
    Error(problem) ->
      text_response(error.to_status_code(problem), error.message(problem))
  }
}
```

## Where to go next

- [Hints](hints.md): `not found`, `unique` and `not null`
- [Types](types.md): infinity and the other values that a Gleam type cannot hold
