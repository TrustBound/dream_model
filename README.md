<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>Typed PostgreSQL models for Gleam, written from your SQL files</b>

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

## What is Dream Model?

Dream Model writes the database layer of any Gleam app from your SQL. You write one `.sql` file for each query, and it checks each statement against your PostgreSQL database and writes one typed Gleam module with a function for each file. A column is an `Option` only when PostgreSQL can return NULL for it, and every failure comes back as a Dream Errors value your app can match on. It runs at development time, so your app does not run it.

## Features

### From SQL to typed code

One `.sql` file gives one typed function. [Read more](https://github.com/TrustBound/dream_model/blob/main/docs/guides/getting-started.md).

| Feature                         | What you get                                                                                         |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| 📄 **One file, one function**   | A typed Gleam function and a record type for its rows, written from the `.sql` file                  |
| 🎯 **Option only where needed** | The generator reads the schema and the query tree of PostgreSQL to find the columns that can be NULL |
| 🧬 **Exact types**              | Each PostgreSQL type has a Gleam type, with exact numbers and arrays                                 |

### Hints in SQL comments

Say what the query returns, in the file that holds it. [Read more](https://github.com/TrustBound/dream_model/blob/main/docs/guides/hints.md).

| Feature                        | What you get                                                                     |
| ------------------------------ | -------------------------------------------------------------------------------- |
| 🪧 **Row count and type name** | `-- returns: one User`, `maybe`, `many` or `none`                                |
| 🔒 **Unique constraints**      | `-- unique:` names the constraints that give a `Conflict`                        |
| 🤝 **Promises about NULL**     | `-- not null:` and `-- nullable:` settle the columns the generator cannot decide |
| 🏷️ **Parameter names**         | `-- params:` names the arguments of the function                                 |

### Errors as data

Every failure is a `dream_errors.Error`, with the original database error as its cause. [Read more](https://github.com/TrustBound/dream_model/blob/main/docs/guides/errors.md).

| Feature                          | What you get                                                                            |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| 🔍 **NotFound and Conflict**     | No row gives `NotFound`, and a violation of a hinted unique constraint gives `Conflict` |
| ⏳ **Timeout and Unavailable**   | A timeout and a lost connection each have their own error                               |
| 🧾 **Everything else is Failed** | Any other failure keeps the original database error as its cause                        |

### Safe against change

The generated code and the schema stay in step. [Read more](https://github.com/TrustBound/dream_model/blob/main/docs/guides/ci-and-schema-drift.md).

| Feature                   | What you get                                                           |
| ------------------------- | ---------------------------------------------------------------------- |
| ✅ **`--check` for CI**   | Fails when a module differs from its `.sql` files                      |
| 🧷 **Schema fingerprint** | The app stops at start-up when the schema changed after the generation |
| 🐘 **Tested on 16 to 19** | PostgreSQL 16, 17, 18 and 19                                           |

## A Quick Example

Put the `.sql` file of a query in a folder with the name of the model, here `src/app/models/user`. The comment line at the top is a hint.

### Find one user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/docs/guides/getting-started.md#find-one-user-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

```sql
-- returns: one User
select id, email, nickname from users where id = $1
```

**Run this:** `gleam run -m dream_model` with `DATABASE_URL` set to a database with your schema → `src/app/models/user.gleam`, with a `User` record type and `find(db, id) -> Result(User, Error(QueryError))`.

## Installation

```sh
gleam add --dev dream_model
gleam add dream_postgres dream_errors
```

The generated modules import `dream_postgres` and `dream_errors`, so the app needs both as dependencies.

## Guides

- [Getting started](https://github.com/TrustBound/dream_model/blob/main/docs/guides/getting-started.md): write the `.sql` files of a model, generate its module, call it from your app and check the schema at start-up
- [Hints](https://github.com/TrustBound/dream_model/blob/main/docs/guides/hints.md): every hint, with a real example and the code that it gives
- [Why is this column Option?](https://github.com/TrustBound/dream_model/blob/main/docs/guides/why-option.md): each reason the generator gives, with an example query and what to do
- [Types](https://github.com/TrustBound/dream_model/blob/main/docs/guides/types.md): the Gleam type of each PostgreSQL type, exact numbers, arrays, infinity and the types that need a cast
- [Errors](https://github.com/TrustBound/dream_model/blob/main/docs/guides/errors.md): the error and the exact data of each failure
- [CI and schema drift](https://github.com/TrustBound/dream_model/blob/main/docs/guides/ci-and-schema-drift.md): `--check` in CI and `client.check_schema` at start-up
- [Command reference](https://github.com/TrustBound/dream_model/blob/main/docs/guides/command-reference.md): every option, setting, exit status and message
- [API reference](https://hexdocs.pm/dream_model): every module and function on HexDocs

## Requirements

- Gleam 1.19.2 or newer, with the `gleam` program on the `PATH` to format the modules.
- Erlang/OTP 28 (the version CI uses).
- PostgreSQL 16, 17, 18 or 19. Dream Model refuses PostgreSQL 15 and older.
- `dream_postgres` 2.1.0 or newer and `dream_errors` 1.0.0 or newer in the app, because the generated modules use them.

## About Dream

[Dream](https://github.com/TrustBound/dream) is a collection of Gleam packages for building production web applications. Each package implements its standards completely, shares the same naming and style as the others, and is fully tested. TrustBound builds Dream for its own production systems and shares it in the hope that it helps yours.

Dream Model works on its own. You don't need the rest of Dream to use it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache 2.0](LICENSE)
