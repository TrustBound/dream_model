# Getting started with dream_model

This guide writes three SQL files of a user model, generates the module, and checks it in CI. The examples are the files of the end-to-end app in `e2e/model_app`, which the tests generate and run on each PostgreSQL version.

## Write the SQL files

Put the files of a model in one folder under `src`, for example `src/app/models/user`. The comment lines at the top of a file are hints.

### Find one user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- not found: User not found
select id, email, nickname from users where id = $1
```

### Create a user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/create.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- unique users_email_key: Email already taken
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
```

### Count the users <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/count.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
select count(*) as total from users
```

## Generate the modules

Set `DATABASE_URL` to the URL of a database that has your schema. Then run the command in the app folder:

### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model
```

The command writes `src/app/models/user.gleam`, and it prints each module that it wrote. The module holds the record type and one function for each file:

### The generated type of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L20-L23"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// A row of create.sql, find.sql, find_by_email.sql, list.sql and search.sql.
pub type User {
  User(id: Int, email: String, nickname: Option(String))
}
```

### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L74-L82"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

The generated code imports only `dream`, `dream_postgres/client` and the Gleam standard library. Each module also has `schema_fingerprint`. Give the fingerprints to `client.check_schema` when the app starts, so the app stops when the schema changed after the generation.

## Check the modules in CI

The `--check` option writes nothing. It exits with status 1 and lists each module that is missing or that differs from its `.sql` files:

### Check the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/check-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model -- --check
```

## Hints

| Hint | Effect |
| --- | --- |
| `-- returns: one User` | One row, or `NotFound` (404) when there is no row |
| `-- returns: maybe User` | `Option(User)` |
| `-- returns: many User` | `List(User)`. This is the default, with the folder name as the type |
| `-- returns: none` | `Nil`, for a statement with no result columns |
| `-- returns: one` | With no type name and one result column: the value of that column |
| `-- returns: many app/models/user.User` | A type of another model. The module imports it |
| `-- not found: User not found` | The text of the 404. The default is `<Type> not found` |
| `-- unique users_email_key: Email already taken` | A violation of that unique constraint gives `Conflict` (409) with the text |
| `-- not null: total` | The computed column is not `Option`. The decoder checks each row |
| `-- nullable: title` | The column is `Option` |
| `-- params: pattern, nickname?` | The names of the parameters, in order. `?` makes a parameter `Option` |

Without `-- params:`, a parameter gets the name of the column that it is stored into or compared with, for example `id` for `where id = $1`.

Every other database error gives `InternalServerError` with a message that names the function, for example `user.find failed`. The message holds no SQL and no data.

## Settings

Put the settings in the `[tools.dream_model]` table of the `gleam.toml` of your app:

- `database_url_variable`: the environment variable with the database URL. The default is `DATABASE_URL`.
- `models`: a list of model folders, for example `["src/app/models/user"]`. The default is each folder under `src` that holds a `.sql` file.

## Supported types

`int2`, `int4`, `int8` and `oid` give `Int`. `float4`, `float8` and `numeric` give `Float`. `text`, `varchar`, `bpchar`, `name`, `citext`, `json`, `jsonb` and enums give `String`. `bool` gives `Bool`. `bytea` and `uuid` give `BitArray`. `timestamp` and `timestamptz` give `client.Timestamp`, `date` gives `client.Date`, and `time` gives `client.TimeOfDay`. An array gives a `List`, and a domain has the type of its base type. For any other type, cast the column in the SQL, for example `span::text`.

dream_model supports PostgreSQL 16, 17, 18 and 19.
