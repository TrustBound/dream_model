# Getting started

Your Dream app needs to read and write rows in PostgreSQL. You know the SQL. You do not want to write the decoders, the parameter lists and the error mapping by hand for each query. This guide writes three `.sql` files of a user model, generates the Gleam module, calls it from a controller, and checks the schema when the app starts.

The examples are the files of the end-to-end app in `e2e/model_app`. The tests of dream_model generate its models and run them on PostgreSQL 16, 17, 18 and 19.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Step 1: Write the SQL files](#step-1-write-the-sql-files)
- [Step 2: Generate the module](#step-2-generate-the-module)
- [Step 3: Call the model from a controller](#step-3-call-the-model-from-a-controller)
- [Step 4: Check the schema at start-up](#step-4-check-the-schema-at-start-up)
- [Step 5: Check the modules in CI](#step-5-check-the-modules-in-ci)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you:

- Write `find.sql`, `create.sql` and `count.sql` in `src/app/models/user`.
- Generate `src/app/models/user.gleam`, with a `User` type and one function for each file.
- Answer a request with the user, or with a 404 when there is no user, and with a 409 when an email is taken.
- Stop the app at start-up when the schema changed after the generation.
- Fail CI when a module differs from its `.sql` files.

## Before you start

Add dream_model as a dev dependency. The app also needs `dream`, `dream_postgres` and `dream_errors`. The generated modules use only `dream_postgres` and `dream_errors`, and the controllers use `dream`:

### The dev dependency of the end-to-end app <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L14-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_model = ">= 1.0.0 and < 2.0.0"
```

`gleam add --dev dream_model` writes this line. Add the two packages of the generated modules as dependencies:

### The dependencies of the generated modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L11-L12"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
dream_errors = ">= 1.0.0 and < 2.0.0"
dream_postgres = ">= 2.1.0 and < 3.0.0"
```

`gleam add dream_postgres dream_errors` writes these lines.

You need:

- A PostgreSQL 16, 17, 18 or 19 database that has the schema of your app. dream_model reads the schema and runs no statement of your `.sql` files.
- The `gleam` program on the `PATH`. dream_model formats each module with `gleam format`.

The examples use this table:

### The users table <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/schema.sql#L9-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
create table users (
  id bigserial primary key,
  email citext not null unique,
  nickname text,
  created_at timestamptz not null default now()
);
```

## Step 1: Write the SQL files

Put the files of a model in one folder under `src`. The name of the folder is the name of the model, and the name of each file is the name of its function. Each file holds one statement. The comment lines at the top of a file are hints. The [Hints](hints.md) guide shows each hint.

### Find one user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
select id, email, nickname from users where id = $1
```

`returns: one User` says that the statement gives one row, as the type `User`. When there is no row, the function gives `dream_errors.NotFound`.

### Create a user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/create.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- unique: users_email_key
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
```

`unique: users_email_key` turns a violation of that unique constraint into a `dream_errors.Conflict`, with the database error as the cause. The hint holds no text for a user: the controller writes it.

### Count the users <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/count.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
select count(*) as total from users
```

`returns: one` with no type name and one result column gives the value of that column.

## Step 2: Generate the module

Set `DATABASE_URL` to the URL of the database, for example `postgresql://user:password@localhost:5432/app`. Then run the command in the app folder:

### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model
```

The command writes `src/app/models/user.gleam` and prints `wrote src/app/models/user.gleam`. A module that did not change prints `unchanged`. Commit the generated modules with your code.

The module starts with the record type. Each file that returns `User` must give it the same fields:

### The generated type <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L27-L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// A row of create.sql, find.sql, find_by_email.sql, list.sql and search.sql.
pub type User {
  User(id: Int, email: String, nickname: Option(String))
}
```

`nickname` is `Option(String)`, because the column allows NULL. `email` is `String`, because the column is NOT NULL. The [Why is this column Option?](why-option.md) guide gives each reason.

Each `.sql` file gives one function. Its first argument is the connection, and the other arguments are the parameters of the statement:

### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L82-L90"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from find.sql.
pub fn find(db: Connection, id: Int) -> Result(User, Error(QueryError)) {
  "select id, email, nickname from users where id = $1"
  |> query
  |> parameter(int(id))
  |> returning(user_decoder())
  |> execute(db)
  |> one_row("user.find", [])
}
```

### The function of create.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L41-L55"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from create.sql.
pub fn create(
  db: Connection,
  email: String,
  nickname: Option(String),
) -> Result(User, Error(QueryError)) {
  "insert into users (email, nickname) values ($1, $2)
returning id, email, nickname"
  |> query
  |> parameter(text(email))
  |> parameter(nullable(text, nickname))
  |> returning(user_decoder())
  |> execute(db)
  |> one_row("user.create", ["users_email_key"])
}
```

`create` takes `nickname` as an `Option`, because the statement stores the parameter straight into a column that allows NULL.

## Step 3: Call the model from a controller

Each function returns `Result(row, dream_errors.Error(client.QueryError))`, the shared error of the Dream ecosystem. The error is data: `NotFound`, `Conflict`, `Timeout`, `Unavailable` or `Failed`, each with a message for developers and, except `NotFound`, the database error as the cause. The controller picks the status and the text of each case, and reads the constraint of a `Conflict` with `client.violated_constraint`. It never sends the message, which can name tables, constraints and values:

### Answer with the user or the error <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/controllers/user_controller.gleam#L16-L49"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Answers with the email of the user, or with the status and the text of
/// the error.
pub fn show(db: Connection, id: Int) -> Response {
  case find(db, id) {
    Ok(found) -> text_response(200, found.email)
    Error(error) -> error_response(error)
  }
}

/// Creates a user and answers with the email, or with a 409 when the email
/// is taken.
pub fn create(db: Connection, email: String) -> Response {
  case user.create(db, email, None) {
    Ok(created) -> text_response(201, created.email)
    Error(error) -> error_response(error)
  }
}

/// The status and the text of each model error. The cause of a `Conflict`
/// is the error of the database, and `violated_constraint` gives
/// the name of its constraint.
fn error_response(error: Error(QueryError)) -> Response {
  case error {
    NotFound(..) -> text_response(404, "User not found")
    Conflict(cause:, ..) ->
      case violated_constraint(cause) {
        Ok("users_email_key") -> text_response(409, "Email already taken")
        _ -> text_response(409, "Conflict")
      }
    Unavailable(..) -> text_response(503, "Service unavailable")
    Timeout(..) -> text_response(504, "Timed out")
    Invalid(..) | Failed(..) -> text_response(500, "Internal server error")
  }
}
```

For user 1, the answer is 200 with the email. For a missing user, the answer is 404 with `User not found`. For a taken email, the answer is 409 with `Email already taken`:

### What the controller answers <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L20-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user_controller.show: 200 Text("ann@example.com")
| user_controller.show of a missing user: 404 Text("User not found")
| user_controller.create of a taken email: 409 Text("Email already taken")
```

The [Errors](errors.md) guide gives every error and its text.

## Step 4: Check the schema at start-up

Each module holds `schema_fingerprint`: the tables of the module and a hash of their schema at generation time. Give the fingerprints to `client.check_schema` right after the pool starts:

### Compare the models with the database <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/startup.gleam#L10-L18"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Compares the schema fingerprint of each model with the database.
pub fn check_models(db: client.Connection) -> Result(Nil, String) {
  client.check_schema(db, [
    user.schema_fingerprint,
    post.schema_fingerprint,
    sample.schema_fingerprint,
  ])
  |> result.map_error(client.format_schema_check_error)
}
```

When a migration changed a table after the generation, `check_models` returns an error. Stop the app with that message, and generate the modules again:

### The message after a new column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L53"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| startup.check_models after a new column: Error("The database schema changed after dream_model generated these modules. Regenerate them with dream_model:")
```

## Step 5: Check the modules in CI

`--check` writes nothing. It exits with status 1 and lists each module that is missing or that differs from its `.sql` files:

### Check the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/check-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model -- --check
```

The [CI and schema drift](ci-and-schema-drift.md) guide shows the CI job and the start-up check together.

## Common pitfalls

- **The database has no schema.** dream_model analyzes each statement against the database. Run your migrations on the database of `DATABASE_URL` before you generate.
- **The module changed after a migration.** Generate the modules after each migration, and commit them with the migration.
- **A parameter is `Option` and you want it required.** A parameter that is stored straight into a nullable column is `Option`. To require it, add a NOT NULL constraint to the column, or use `-- params:` without `?`. See [Hints](hints.md#params).
- **A computed column is `Option`.** Most computed values can be NULL. Use `coalesce(...)`, or promise the value with `-- not null:`. See [Why is this column Option?](why-option.md).
- **PostgreSQL 15.** dream_model refuses PostgreSQL 15 and older.

## Where to go next

- [Hints](hints.md): every hint, with the code it gives
- [Why is this column Option?](why-option.md): each NULL decision and what to do
- [Types](types.md): the Gleam type of each PostgreSQL type
- [Errors](errors.md): every error that a model function returns
- [CI and schema drift](ci-and-schema-drift.md): `--check` and `client.check_schema`
- [Command reference](command-reference.md): every option, setting and message
