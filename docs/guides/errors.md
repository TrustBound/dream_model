# Errors

Each generated function returns `Result(row, dream_errors.Error(client.QueryError))`. `client` is `dream_postgres/client`, and `dream_errors.Error` is the shared error of the Dream ecosystem. The error is data, with no HTTP status and no text for a user: `NotFound(message)`, `Conflict(message, cause)`, `Timeout(message, cause)`, `Unavailable(message, cause)` or `Failed(message, cause)`. The `cause` is the original `QueryError` of the database call. Your controller picks the status and the text of each case. This guide shows each error, with the exact output of the end-to-end app.

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

| When | Error | Message |
| --- | --- | --- |
| `returns: one` gets no row | `NotFound` | `<model>.<function> found no row` |
| A `unique` hint names the violated constraint | `Conflict` | `<model>.<function>: the query violated the constraint <constraint>` |
| The database does not answer in time | `Timeout` | `<model>.<function>: the database did not answer the query in time` |
| No database connection is available | `Unavailable` | `<model>.<function>: no database connection was available` |
| `returns: one` or `maybe` gets more than one row | `Failed` | `<model>.<function> returned more than one row` |
| A `not null` column is NULL | `Failed` | `the SQL file <file> promised the column <column> is never NULL, and PostgreSQL returned NULL` |
| A `not null elements` array holds a NULL element | `Failed` | `the SQL file <file> promised the elements of <column> are never NULL, and PostgreSQL returned NULL` |
| A time or date column holds infinity | `Failed` | `<model>.<function>: the column <column> holds infinity, which the Gleam type Timestamp cannot hold` |
| A `numeric` parameter is not a number | `Failed` | `<model>.<function>: ` and the PostgreSQL error |
| Any other failure | `Failed` | `<model>.<function>: ` and the message of `client.to_error` |

`<model>.<function>` is the last part of the module name and the name of the function, for example `user.find`. A message is for developers and logs. It can name tables, constraints and the values of a PostgreSQL error, so never send it to a client. The `cause` is the original `QueryError` of the database call. For more than one row, it is `client.more_than_one_row(count)`. `NotFound` has no cause.

The outputs in this guide come from the end-to-end app of dream_model. It prints the kind of an error (`dream_errors.kind_name`), its message and the constructor of its cause. For a constraint violation, it also prints the name of the constraint, from `client.violated_constraint` of the cause.

Each generated module maps a query error with the same helper. `client.to_error` tells a timeout and a lost connection apart from the other errors:

### The error helper of a generated module <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L232-L255"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn query_error_to_error(
  query_error: client.QueryError,
  query_name: String,
  unique: List(String),
) -> dream_errors.Error(client.QueryError) {
  let conflict =
    unique_violation(client.violated_constraint(query_error), unique)
  let promise = client.broken_promise(query_error)
  let infinite = client.infinite_value(query_error)
  let shared = client.to_error(query_error)
  let described = query_name <> ": " <> dream_errors.message(shared)
  case conflict, promise, infinite, shared {
    Ok(_), _, _, _ -> dream_errors.Conflict(described, query_error)
    Error(Nil), Ok(message), _, _ -> dream_errors.Failed(message, query_error)
    Error(Nil), Error(Nil), Ok(message), _ ->
      dream_errors.Failed(query_name <> ": " <> message, query_error)
    Error(Nil), Error(Nil), Error(Nil), dream_errors.Timeout(..) ->
      dream_errors.Timeout(described, query_error)
    Error(Nil), Error(Nil), Error(Nil), dream_errors.Unavailable(..) ->
      dream_errors.Unavailable(described, query_error)
    Error(Nil), Error(Nil), Error(Nil), _ ->
      dream_errors.Failed(described, query_error)
  }
}
```

## Not found

`returns: one` gives `NotFound` when the statement gives no row. The message names the function: the controller writes the text for the user, for example `User not found`. `returns: maybe` gives `Ok(None)`, and `returns: many` gives `Ok([])`.

### The row helper of returns: one <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L170-L183"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn single_row(
  returned: client.Returned(row),
  query_name: String,
) -> Result(row, dream_errors.Error(client.QueryError)) {
  case returned.rows {
    [row] -> Ok(row)
    [] -> Error(dream_errors.NotFound(query_name <> " found no row"))
    _ ->
      Error(dream_errors.Failed(
        query_name <> " returned more than one row",
        client.more_than_one_row(returned.count),
      ))
  }
}
```

### A missing user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.find of a missing user: not_found user.find found no row
```

## Unique violation

A `unique` hint maps a violation of one of its constraints to `Conflict`, with the `QueryError` as the cause. `client.violated_constraint(cause)` gives the name of the constraint, for example `Ok("users_email_key")`. The controller writes the text for the user, for example `Email already taken`. A violation of another constraint is not a `Conflict`: see [Every other failure](#every-other-failure).

### A taken email <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L3"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.create of a taken email: conflict user.create: the query violated the constraint users_email_key (cause: ConstraintViolated of users_email_key)
```

## More than one row

`returns: one` and `returns: maybe` give `Failed` when the statement gives more than one row, with the message `<model>.<function> returned more than one row`. Add a condition on a unique column, or `limit 1`, or use `returns: many`.

## Broken promise

A `-- not null:` hint promises that a computed column is never NULL. The decoder checks the promise on each row. A NULL gives `Failed` with a message that names the file and the column:

### A sum of no rows <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| post.total of a user with no posts: failed the SQL file src/app/models/post/total.sql promised the column total is never NULL, and PostgreSQL returned NULL (cause: UnexpectedResultType)
```

Fix the query, for example with `coalesce(sum(id), 0)`, and remove the hint.

A `-- not null elements:` hint promises that an array has no NULL element. The decoder checks each element on each row, and a NULL element gives `Failed` with a message that names the file and the column. A NULL array is not an element: it is `None` when the column can be NULL.

### A NULL element of a promised array <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L48"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.tags with a NULL element: failed the SQL file src/app/models/sample/tags.sql promised the elements of tags are never NULL, and PostgreSQL returned NULL (cause: UnexpectedResultType)
```

Drop the NULL elements in the query with `array_remove(tags, null)`, or remove the hint.

## Infinite value

A `timestamp`, `timestamptz` or `date` column can hold `infinity` or `-infinity`, which a Gleam `Timestamp` or `Date` cannot hold. The function gives `Failed` with a message that names the function, the column and the Gleam type:

### The message of each infinite value <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L35-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: failed sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite timestamptz: failed sample.get: the column happened_at_zone holds -infinity, which the Gleam type Timestamp cannot hold (cause: UnexpectedResultType)
| sample.get of an infinite date: failed sample.get: the column day holds infinity, which the Gleam type Date cannot hold (cause: UnexpectedResultType)
```

The [Types](types.md#infinity) guide shows how to change the query.

## A numeric text that is not a number

A `numeric` parameter is a `String`, and PostgreSQL parses it. A text that is not a number, for example `12,50`, fails with the PostgreSQL error `22P02` (`invalid input syntax for type numeric`). The function gives `Failed`, as for every other database error. The message names the function and the PostgreSQL error, with the text that failed:

### A numeric text with a comma <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L45"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.echo_amount of text that is not a number: failed sample.echo_amount: the database failed the query with invalid_text_representation (22P02): invalid input syntax for type numeric: "12,50" (cause: PostgresqlError)
```

The generated module cannot tell if the text came from a client or from the app, so it does not give a 400. When the text comes from a request, check it in the controller before the call, and answer with your own 400. The texts that PostgreSQL accepts are a sign, digits with one optional `.`, an optional exponent such as `e-3`, and `NaN`, `Infinity` and `-Infinity`, with any case.

## Every other failure

A timeout gives `Timeout`, and a pool with no free connection gives `Unavailable`. Every other error gives `Failed`: a foreign key violation, a check violation, a unique violation with no hint, a PostgreSQL error, and so on. The message is the name of the function and the message of `client.to_error`. Log the message and the `cause`, but do not send them to the client.

### A delete that a foreign key stops <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L52"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user.delete of a user with posts: failed user.delete: the query violated the constraint posts_user_id_fkey (cause: ConstraintViolated of posts_user_id_fkey)
```

## Answer with the error

The controller matches each case of the error and picks the status and the text. It reads the constraint of a `Conflict` from the cause, and it sends no message of an error:

### Answer with the user or the error <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/controllers/user_controller.gleam#L12-L46"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Answers with the email of the user, or with the status and the text of
/// the error.
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

/// The status and the text of each model error. The cause of a `Conflict`
/// is the error of the database, and `client.violated_constraint` gives
/// the name of its constraint.
fn error_response(error: dream_errors.Error(client.QueryError)) -> Response {
  case error {
    dream_errors.NotFound(..) -> text_response(404, "User not found")
    dream_errors.Conflict(cause:, ..) ->
      case client.violated_constraint(cause) {
        Ok("users_email_key") -> text_response(409, "Email already taken")
        _ -> text_response(409, "Conflict")
      }
    dream_errors.Unavailable(..) -> text_response(503, "Service unavailable")
    dream_errors.Timeout(..) -> text_response(504, "Timed out")
    dream_errors.Invalid(..) | dream_errors.Failed(..) ->
      text_response(500, "Internal server error")
  }
}
```

## Where to go next

- [Hints](hints.md): `unique`, `not null` and `not null elements`
- [Types](types.md): exact numbers, infinity and the other values that a Gleam type cannot hold
