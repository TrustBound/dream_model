# Errors

Each generated function returns `Result(row, client.ModelQueryError)`. `client` is `dream_postgres/client`, and `ModelQueryError` is the alias of `ModelError(QueryError)`. The error is data, with no HTTP status and no text for a user: `NotFound`, `Conflict(constraint)` or `QueryFailed(message, cause)`. Your controller picks the status and the text of each case. This guide gives each error, when it happens, and its exact data.

## Table of Contents

- [The errors at a glance](#the-errors-at-a-glance)
- [Not found](#not-found)
- [Unique violation](#unique-violation)
- [More than one row](#more-than-one-row)
- [Broken promise](#broken-promise)
- [Infinite value](#infinite-value)
- [A numeric text that is not a number](#a-numeric-text-that-is-not-a-number)
- [Every other failure](#every-other-failure)
- [Answer with the error](#answer-with-the-error)
- [Where to go next](#where-to-go-next)

## The errors at a glance

| When | Error | Data |
| --- | --- | --- |
| `returns: one` gets no row | `NotFound` | None |
| A `unique` hint names the violated constraint | `Conflict` | The name of the constraint, for example `users_email_key` |
| `returns: one` or `maybe` gets more than one row | `QueryFailed` | `<model>.<function> returned more than one row` |
| A `not null` column is NULL | `QueryFailed` | `the SQL file <file> promised the column <column> is never NULL, and PostgreSQL returned NULL` |
| A `not null elements` array holds a NULL element | `QueryFailed` | `the SQL file <file> promised the elements of <column> are never NULL, and PostgreSQL returned NULL` |
| A time or date column holds infinity | `QueryFailed` | `<model>.<function>: the column <column> holds infinity, which the Gleam type Timestamp cannot hold` |
| A `numeric` parameter is not a number | `QueryFailed` | `<model>.<function> failed` |
| Any other failure | `QueryFailed` | `<model>.<function> failed` |

`<model>.<function>` is the last part of the module name and the name of the function, for example `user.find`. No message holds SQL, a parameter or a value of a row. The `cause` of a `QueryFailed` is the original `QueryError` of the database call. For more than one row, it is `client.more_than_one_row(count)`.

The outputs in this guide come from the end-to-end app of dream_model. It prints an error as `NotFound`, as `Conflict` and the constraint, or as `QueryFailed`, the message and the constructor of the cause.

Each generated module maps a query error with the same helper:

### The error helper of a generated module <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L229-L246"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn query_error_to_error(
  query_error: client.QueryError,
  query_name: String,
  unique: List(String),
) -> client.ModelQueryError {
  let conflict =
    unique_violation(client.violated_constraint(query_error), unique)
  let promise = client.broken_promise(query_error)
  let infinite = client.infinite_value(query_error)
  case conflict, promise, infinite {
    Ok(constraint), _, _ -> client.Conflict(constraint)
    Error(Nil), Ok(message), _ -> client.QueryFailed(message, query_error)
    Error(Nil), Error(Nil), Ok(message) ->
      client.QueryFailed(query_name <> ": " <> message, query_error)
    Error(Nil), Error(Nil), Error(Nil) ->
      client.QueryFailed(query_name <> " failed", query_error)
  }
}
```

## Not found

`returns: one` gives `NotFound` when the statement gives no row. `NotFound` has no text: the controller writes the text for the user, for example `User not found`. `returns: maybe` gives `Ok(None)`, and `returns: many` gives `Ok([])`.

### The row helper of returns: one <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L167-L180"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn single_row(
  returned: client.Returned(row),
  query_name: String,
) -> Result(row, client.ModelQueryError) {
  case returned.rows {
    [row] -> Ok(row)
    [] -> Error(client.NotFound)
    _ ->
      Error(client.QueryFailed(
        query_name <> " returned more than one row",
        client.more_than_one_row(returned.count),
      ))
  }
}
```

### A missing user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.find of a missing user: NotFound
```

## Unique violation

A `unique` hint maps a violation of one of its constraints to `Conflict` with the name of the constraint. The controller writes the text for the user, for example `Email already taken`. A violation of another constraint is not a `Conflict`: see [Every other failure](#every-other-failure).

### A taken email <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L3"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.create of a taken email: Conflict users_email_key
```

## More than one row

`returns: one` and `returns: maybe` give `QueryFailed` when the statement gives more than one row, with the message `<model>.<function> returned more than one row`. Add a condition on a unique column, or `limit 1`, or use `returns: many`.

## Broken promise

A `-- not null:` hint promises that a computed column is never NULL. The decoder checks the promise on each row. A NULL gives `QueryFailed` with a message that names the file and the column:

### A sum of no rows <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| post.total of a user with no posts: QueryFailed the SQL file src/app/models/post/total.sql promised the column total is never NULL, and PostgreSQL returned NULL (cause: UnexpectedResultType)
```

Fix the query, for example with `coalesce(sum(id), 0)`, and remove the hint.

A `-- not null elements:` hint promises that an array has no NULL element. The decoder checks each element on each row, and a NULL element gives `QueryFailed` with a message that names the file and the column. A NULL array is not an element: it is `None` when the column can be NULL.

### A NULL element of a promised array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L48"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.tags with a NULL element: QueryFailed the SQL file src/app/models/sample/tags.sql promised the elements of tags are never NULL, and PostgreSQL returned NULL (cause: UnexpectedResultType)
```

Drop the NULL elements in the query with `array_remove(tags, null)`, or remove the hint.

## Infinite value

A `timestamp`, `timestamptz` or `date` column can hold `infinity` or `-infinity`, which a Gleam `Timestamp` or `Date` cannot hold. The function gives `QueryFailed` with a message that names the function, the column and the Gleam type:

### The message of each infinite value <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L35-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: QueryFailed sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite timestamptz: QueryFailed sample.get: the column happened_at_zone holds -infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite date: QueryFailed sample.get: the column day holds infinity, which the Gleam type Date cannot hold (cause: UnexpectedResultType)
```

The [Types](types.md#infinity) guide shows how to change the query.

## A numeric text that is not a number

A `numeric` parameter is a `String`, and PostgreSQL parses it. A text that is not a number, for example `12,50`, fails with the PostgreSQL error `22P02` (`invalid input syntax for type numeric`). The function gives `QueryFailed` with the message `<model>.<function> failed`, as for every other database error:

### A numeric text with a comma <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L45"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.echo_amount of text that is not a number: QueryFailed sample.echo_amount failed (cause: PostgresqlError)
```

The generated module cannot tell if the text came from a client or from the app, so it does not give a 400. When the text comes from a request, check it in the controller before the call, and answer with your own 400. The texts that PostgreSQL accepts are a sign, digits with one optional `.`, an optional exponent such as `e-3`, and `NaN`, `Infinity` and `-Infinity`, with any case.

## Every other failure

Every other error gives `QueryFailed` with the message `<model>.<function> failed`: a connection error, a timeout, a foreign key violation, a check violation, a unique violation with no hint, and so on. The message holds no SQL and no data, so it is safe to send to the client. The `cause` holds the details of the database error: log it, but do not send it to the client.

### A delete that a foreign key stops <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L52"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.delete of a user with posts: QueryFailed user.delete failed (cause: ConstraintViolated)
```

## Answer with the error

The controller matches each case of the error and picks the status and the text:

### Answer with the user or the error <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/controllers/user_controller.gleam#L10-L38"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Answers with the email of the user, or with the status and the message
/// of the error.
pub fn show(db: client.Connection, id: Int) -> Response {
  case user.find(db, id) {
    Ok(found) -> text_response(200, found.email)
    Error(error) -> error_response(error)
  }
}

/// Creates a user and answers with the email, or with a 409 when the email
/// is taken.
pub fn create(db: client.Connection, email: String) -> Response {
  case user.create(db, email, None) {
    Ok(created) -> text_response(201, created.email)
    Error(error) -> error_response(error)
  }
}

/// The status and the text of each model error.
fn error_response(error: client.ModelQueryError) -> Response {
  case error {
    client.NotFound -> text_response(404, "User not found")
    client.Conflict("users_email_key") ->
      text_response(409, "Email already taken")
    client.Conflict(constraint:) ->
      text_response(409, "Conflict on " <> constraint)
    client.QueryFailed(message:, cause: _) -> text_response(500, message)
  }
}
```

## Where to go next

- [Hints](hints.md): `unique`, `not null` and `not null elements`
- [Types](types.md): exact numbers, infinity and the other values that a Gleam type cannot hold
