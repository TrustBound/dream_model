# dream_model 1.0.0 Release Notes

**Release Date:** Unreleased

This is the first release of dream_model. It writes the model modules of a Dream app from PostgreSQL `.sql` files. You write one `.sql` file for each query. dream_model analyzes each statement against your database and writes one typed Gleam module for each model folder. Each function returns a Dream error, so a controller gives the result straight to the client.

## Key Highlights

- **One `.sql` file, one typed function**: a record type for the rows, and the parameters as arguments
- **`Option` only where a value can be NULL**: dream_model reads the schema and the analyzed query tree of PostgreSQL
- **Dream errors**: `NotFound` (404), `Conflict` (409) and `InternalServerError` (500), with clear texts
- **`--check` in CI and a schema fingerprint at start-up**: catch a changed `.sql` file and a changed table

## What's New

### Models from SQL files

Put the `.sql` files of a model in one folder under `src`. The comment lines at the top are hints.

#### Find one user <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- not found: User not found
select id, email, nickname from users where id = $1
```

`gleam run -m dream_model` writes `src/app/models/user.gleam`:

#### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L80-L88"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### The NULL rules

A result column is `Option` unless a rule proves that it is never NULL: a NOT NULL table column that no outer join or grouping set can empty, `count(...)`, `coalesce(...)` with a last argument that is never NULL, `EXISTS`, `IS NULL`, `IS DISTINCT FROM` and constants. A parameter is `Option` only when the statement stores it straight into a column that accepts NULL in every case: no NOT NULL, domain rule, CHECK, partition rule, partition key, generated column that uses it, BEFORE trigger, row-level security or view `WITH CHECK OPTION`, and a target whose partitions and child tables are all tables. A cast of the parameter to a domain must accept NULL too. A rule that adds queries, such as `DO ALSO`, makes every parameter required. A built-in length coercion around the parameter, such as the one of a `varchar(10)` column, keeps the store straight. A column of a foreign child table is `Option`.

### Hints

`returns`, `not found`, `unique`, `not null`, `nullable` and `params`, in the comment block at the top of a file. A type name or a parameter name that the generated module uses itself is refused with the file and the line. A `unique` hint is refused at generation time when another index or constraint of the database has the same name, because PostgreSQL names a violation only by its constraint name.

### Arrays and infinity

An array is `List(Option(T))`, because PostgreSQL never forbids a NULL element. A `timestamp`, `timestamptz` or `date` value of `infinity` gives a 500 with a message that names the function, the column and the Gleam type:

#### The message of an infinite timestamp <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/expected_output.txt#L34"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
| sample.get of an infinite timestamp: 500 sample.get: the column happened_at holds infinity, which the Gleam type Timestamp cannot hold
```

### CI and schema drift

`--check` exits with status 1 when a module is missing, differs from its `.sql` files, or is stale because its folder holds no `.sql` file. Generation removes a stale module and never overwrites a file without the generated header line. Generate and check on the major version of PostgreSQL that production uses: the fingerprint differs between 16, 17, and 18 and newer. Each module holds `schema_fingerprint`. Give the fingerprints to `client.check_schema` of dream_postgres when the app starts:

#### Compare the models with the database <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/startup.gleam#L10-L18"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

## Testing

- The full test run on PostgreSQL 16, 17, 18 and 19: 2552 tests, 0 failed, 100.0% line coverage (2104 of 2104 lines). The run took 4 minutes 34 seconds of wall time, and the runner reports 6 minutes 38 seconds of test time (Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2)
- The long fuzz runs analyzed 20,809 random queries on PostgreSQL 16 to 19 with 0 failures, and the mutation test killed each of its 36 mutants
- The attack tests analyze each statement and then run it on several data sets: a column typed never NULL must never return NULL, and each `Option` parameter must accept NULL
- The end-to-end tests generate the models of `e2e/model_app` on each version, compare them with the checked-in modules, run them against the database, and compare the output

## Upgrading

This is the first release. Add it as a dev dependency:

### The dev dependency of the end-to-end app <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L13-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
[dev-dependencies]
dream_model = ">= 1.0.0 and < 2.0.0"
```

`gleam add --dev dream_model` writes this line.

### Migration Guide

No migration is necessary. The app needs `dream` 3.0.0 or newer and `dream_postgres` 2.1.0 or newer.

## Documentation

- [dream_model](https://hexdocs.pm/dream_model) - v1.0.0
- [README](https://github.com/TrustBound/dream_model/blob/main/README.md)
- [Getting started](https://github.com/TrustBound/dream_model/blob/main/docs/guides/getting-started.md)
- [Changelog](https://github.com/TrustBound/dream_model/blob/main/CHANGELOG.md)

## Community

- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_model/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_model/blob/main/CONTRIBUTING.md)
