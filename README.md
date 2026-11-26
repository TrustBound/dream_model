<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>Typed Gleam models with data errors, from PostgreSQL .sql files</b>

</div>

<br />

<div align="center">
  <a href="https://hex.pm/packages/dream_model"><img src="https://img.shields.io/hexpm/v/dream_model" alt="Hex Package"></a>
  <a href="https://github.com/TrustBound/dream_model/releases"><img src="https://img.shields.io/github/v/release/TrustBound/dream_model?label=Release" alt="Latest Release"></a>
  <a href="https://hexdocs.pm/dream_model"><img src="https://img.shields.io/badge/hex-docs-lightgreen.svg" alt="HexDocs"></a>
  <a href="https://github.com/TrustBound/dream_model/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TrustBound/dream_model/badges/coverage.json" alt="Coverage"></a>
  <a href="https://github.com/TrustBound/dream_model/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache 2.0 License"></a>
  <a href="https://gleam.run"><img src="https://img.shields.io/badge/gleam-%E2%9C%A8-ffaff3" alt="Gleam"></a>
</div>

<br />

# dream_model

dream_model writes the model modules of a [Dream](https://github.com/TrustBound/dream) app from SQL. You write one `.sql` file for each query, in a folder with the name of the model. dream_model analyzes each statement against your PostgreSQL database and writes one typed Gleam module for the folder. Each function of the module returns its error as data, and the controller of the app maps it to a response.

dream_model is a tool for development time. Your app does not run it. The generated code imports only `dream_postgres/client`, `dream_errors` and the Gleam standard library.

## Features

- ✅ One `.sql` file gives one typed function, with a record type for its rows
- ✅ `Option` only where a value can be NULL: the generator reads the schema and the query tree of PostgreSQL to decide
- ✅ Data errors, with the shared `dream_errors.Error` of the Dream ecosystem: no row gives `NotFound`, a violation of a hinted unique constraint gives `Conflict`, a timeout gives `Timeout`, a lost connection gives `Unavailable`, and every other failure gives `Failed`. Each error keeps the original database error as its cause
- ✅ Hints in SQL comments: the row count, the type name, the unique constraints, the parameter names and NULL promises
- ✅ `--check` for CI: it fails when a module differs from its `.sql` files
- ✅ A schema fingerprint in each module, so the app stops at start-up when the schema changed after the generation
- ✅ Tested on PostgreSQL 16, 17, 18 and 19

## Installation

dream_model is a dev dependency. The generated modules import `dream_postgres` and `dream_errors`, so the app needs both as dependencies:

### The dependencies of the generated modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L11-L12"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#the-dependencies-of-the-generated-modules-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```toml
dream_errors = ">= 1.0.0 and < 2.0.0"
dream_postgres = ">= 2.1.0 and < 3.0.0"
```

`gleam add dream_postgres dream_errors` writes these lines.

### The dev dependency of the end-to-end app <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L14-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#the-dev-dependency-of-the-end-to-end-app-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_model = ">= 1.0.0 and < 2.0.0"
```

`gleam add --dev dream_model` writes this line.

dream_model needs PostgreSQL 16 or newer, and the `gleam` program on the `PATH` to format the modules.

## Quick Start

Put the `.sql` files of the user model in `src/app/models/user`. The comment lines at the top are hints.

### Find one user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#find-one-user-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```sql
-- returns: one User
select id, email, nickname from users where id = $1
```

### Create a user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/create.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#create-a-user-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```sql
-- returns: one User
-- unique: users_email_key
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
```

Set `DATABASE_URL` to a database with your schema, and run the command in the app folder:

### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#write-the-modules-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```sh
gleam run -m dream_model
```

The command writes `src/app/models/user.gleam`. It holds the record type, and one function for each `.sql` file:

### The generated type <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L20-L23"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#the-generated-type-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
/// A row of create.sql, find.sql, find_by_email.sql, list.sql and search.sql.
pub type User {
  User(id: Int, email: String, nickname: Option(String))
}
```

### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L83-L94"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#the-function-of-findsql-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```gleam
/// Generated from find.sql.
pub fn find(
  db: client.Connection,
  id: Int,
) -> Result(User, dream_errors.Error(client.QueryError)) {
  "select id, email, nickname from users where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> one_row("user.find", [])
}
```

A controller gives the result to the client. It picks the status and the text of each error, for example a 404 for a missing user and a 409 for a taken email. The cause of a `Conflict` is the database error, and `client.violated_constraint` gives the name of its constraint. The message of an error is for developers and logs, so the controller never sends it:

### Answer with the user or the error <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/controllers/user_controller.gleam#L12-L46"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#answer-with-the-user-or-the-error-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

## Guides

- [Getting started](https://github.com/TrustBound/dream_model/blob/main/docs/guides/getting-started.md): write the `.sql` files of a model, generate its module, call it from a controller and check the schema at start-up
- [Hints](https://github.com/TrustBound/dream_model/blob/main/docs/guides/hints.md): every hint, with a real example and the code that it gives
- [Why is this column Option?](https://github.com/TrustBound/dream_model/blob/main/docs/guides/why-option.md): each reason the generator gives, with an example query and what to do
- [Types](https://github.com/TrustBound/dream_model/blob/main/docs/guides/types.md): the Gleam type of each PostgreSQL type, exact numbers, arrays, infinity and the types that need a cast
- [Errors](https://github.com/TrustBound/dream_model/blob/main/docs/guides/errors.md): the error and the exact data of each failure
- [CI and schema drift](https://github.com/TrustBound/dream_model/blob/main/docs/guides/ci-and-schema-drift.md): `--check` in CI and `client.check_schema` at start-up
- [Command reference](https://github.com/TrustBound/dream_model/blob/main/docs/guides/command-reference.md): every option, setting, exit status and message

## Requirements

- PostgreSQL 16, 17, 18 or 19. dream_model refuses PostgreSQL 15 and older.
- Gleam 1.19.2 or newer.
- `dream` 3.0.0 or newer, `dream_postgres` 2.1.0 or newer and `dream_errors` 1.0.0 or newer in the app.

## About Dream

dream_model is part of [Dream](https://github.com/TrustBound/dream), a web toolkit for Gleam. It is built with the same quality standards as Dream, but your app does not need it at run time.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache 2.0](LICENSE)
