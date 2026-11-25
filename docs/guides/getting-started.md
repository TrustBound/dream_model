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
- Answer a request with the user, or with a 404 when there is no user.
- Stop the app at start-up when the schema changed after the generation.
- Fail CI when a module differs from its `.sql` files.

## Before you start

Add dream_model as a dev dependency. The app also needs `dream` and `dream_postgres`:

```sh
gleam add --dev dream_model
```

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
-- not found: User not found
select id, email, nickname from users where id = $1
```

`returns: one User` says that the statement gives one row, as the type `User`. `not found` gives the text of the 404 when there is no row.

### Create a user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/create.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- unique users_email_key: Email already taken
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
```

`unique users_email_key` turns a violation of that unique constraint into a 409 with the text `Email already taken`.

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

### The generated type <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L20-L23"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// A row of create.sql, find.sql, find_by_email.sql, list.sql and search.sql.
pub type User {
  User(id: Int, email: String, nickname: Option(String))
}
```

`nickname` is `Option(String)`, because the column allows NULL. `email` is `String`, because the column is NOT NULL. The [Why is this column Option?](why-option.md) guide gives each reason.

Each `.sql` file gives one function. Its first argument is the connection, and the other arguments are the parameters of the statement:

### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L80-L88"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from find.sql.
pub fn find(db: client.Connection, id: Int) -> Result(User, Error) {
  "select id, email, nickname from users where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> one_row("user.find", "User not found", [])
}
```

### The function of create.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L34-L50"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from create.sql.
pub fn create(
  db: client.Connection,
  email: String,
  nickname: Option(String),
) -> Result(User, Error) {
  "insert into users (email, nickname) values ($1, $2)
returning id, email, nickname"
  |> client.query
  |> client.parameter(client.text(email))
  |> client.parameter(client.nullable(client.text, nickname))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> one_row("user.create", "User not found", [
    #("users_email_key", "Email already taken"),
  ])
}
```

`create` takes `nickname` as an `Option`, because the statement stores the parameter straight into a column that allows NULL.

## Step 3: Call the model from a controller

Each function returns `Result(row, dream/http/error.Error)`. `error.to_status_code` and `error.message` give the status and the text of the error:

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

For user 1, the answer is 200 with the email. For a missing user, the answer is 404 with `User not found`:

### What the controller answers <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L20-L21"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| user_controller.show: 200 Text("ann@example.com")
| user_controller.show of a missing user: 404 Text("User not found")
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

### The message after a new column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L39"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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
