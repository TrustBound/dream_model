# CI and schema drift

A generated module is correct for the schema and the `.sql` files that dream_model read. Two things can make it wrong later: a `.sql` file changes, or a migration changes a table. This guide catches the first in CI with `--check`, and the second when the app starts, with `client.check_schema`.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Step 1: Check the modules in CI](#step-1-check-the-modules-in-ci)
- [Step 2: Check the schema at start-up](#step-2-check-the-schema-at-start-up)
- [What the fingerprint covers](#what-the-fingerprint-covers)
- [Use the production major version](#use-the-production-major-version)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

- A CI step that fails when a module is missing or differs from its `.sql` files.
- A start-up check that stops the app when a table changed after the generation.

## Step 1: Check the modules in CI

`--check` analyzes the `.sql` files and writes nothing. It compares each module that it would write with the module on disk.

### Check the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/check-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model -- --check
```

When every module matches, it prints `every model module matches its .sql files (3 modules)` and exits with status 0. Otherwise it prints one line for each module, `missing <path>` or `differs <path>`, then `` Run `gleam run -m dream_model` to write the modules again. ``, and exits with status 1. For example:

- `differs src/app/models/post.gleam`

The CI job needs a database with the schema of the app:

1. Start PostgreSQL of the major version that production uses, as a service of the CI job.
2. Run your migrations on it.
3. Set `DATABASE_URL` (or the variable that `database_url_variable` names) to its URL.
4. Run `gleam run -m dream_model -- --check`.

## Step 2: Check the schema at start-up

Each module holds `schema_fingerprint`: its module name, the tables that its functions read and write, and the fingerprint hash of those tables when dream_model generated it.

### The fingerprint of the user module <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L13-L18"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub const schema_fingerprint =
  client.SchemaFingerprint(
    module: "app/models/user",
    tables: ["public.users"],
    hash: "41437081a0c965016a4ec7e8d4f16e650be16bea5d22317d552c0e782c7e6988",
  )
```

Give the fingerprints of every module to `client.check_schema` right after the pool starts:

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

`check_schema` reads the fingerprint of the tables of each module from the database, and compares it with the hash in the module. When a migration changed a table after the generation, the result is an error. `client.format_schema_check_error` gives a message with one line for each module that changed:

### The first line after a new column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L52"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| startup.check_models after a new column: Error("The database schema changed after dream_model generated these modules. Regenerate them with dream_model:")
```

Each line after the first one names a module, its tables, the expected fingerprint and the found fingerprint. Stop the app with the message. Then generate the modules again, and deploy them with the migration.

## What the fingerprint covers

The fingerprint is the SHA-256 hash of the catalog facts that the NULL rules of dream_model read, for the tables, their child tables and their partitions:

- The kind of the relation, row-level security, a BEFORE row trigger, an INSTEAD OF row trigger, the `check_option` of a view, the partition key and the partition bound
- The parents of the table
- Each column: its name, its position, its type, NOT NULL, a default, its identity and generated kind, and the expression of a generated column
- Each constraint: its kind, its name, if it is validated, and its definition
- Each policy, and each domain and enum type that a column uses

The tables of a module are each table and view that its statements read or write, with the tables that each view reads, and each child table and partition. `client.schema_fingerprint_sql` of dream_postgres is the full list of facts. The fingerprint does not change when only OIDs change. It changes when the order of the columns changes, because the generated decoders read the columns by position. A table that does not exist gives a fingerprint too, so a dropped table also stops the app.

A change that does not change the generated code can still change the fingerprint, for example a new CHECK constraint. The start-up check then stops the app, and a new generation writes a new hash.

## Use the production major version

The fingerprint of one schema is different on PostgreSQL 16, on 17, and on 18 and newer. PostgreSQL 17 and newer keep the NOT NULL of a domain as a constraint, and PostgreSQL 18 and newer keep the NOT NULL of a column as a constraint. So a module that you generate on PostgreSQL 17 does not match a PostgreSQL 18 database, also when the schema is the same. Also, `--check` on PostgreSQL 18 fails for modules that you generated on PostgreSQL 16. This is by design: generate and check on the major version that production uses.

- Generate the modules against the major version that production uses.
- Run `--check` in CI against that major version. `--check` compares the whole module, with the hash.
- When you upgrade production to a new major version, generate the modules again on the new version, and deploy them with the upgrade.

## Common pitfalls

- **CI uses another major version.** `--check` then reports `differs` for each module, because the hash differs. Use the production major version in CI.
- **The migration ran after the generation.** Run the migrations first, then generate.
- **A module is not in the start-up check.** Give the fingerprint of every generated module to `check_schema`.

## Where to go next

- [Command reference](command-reference.md): every option, setting, exit status and message
- [Getting started](getting-started.md): the whole flow from the first `.sql` file
