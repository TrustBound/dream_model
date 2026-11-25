# Changelog

All notable changes to `dream_model` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Unreleased

### Added
- `gleam run -m dream_model` writes one typed Gleam module for each folder
  of `.sql` files under `src`. Each `.sql` file gives one function, and
  each function returns a Dream error: `NotFound` (404), `Conflict` (409)
  or `InternalServerError` (500).
- `gleam run -m dream_model -- --check` writes nothing, and exits with
  status 1 when a module is missing or differs from its `.sql` files.
- The NULL rules: a column or a parameter is `Option` only when it can be
  NULL. dream_model reads the schema and the analyzed query tree of
  PostgreSQL to decide.
- The hints `returns`, `not found`, `unique`, `not null`, `nullable` and
  `params`.
- A unique hint whose name another index or constraint of the database
  also has, in any schema, is refused at generation time. PostgreSQL names
  a violation only by its constraint name.
- An array column or parameter is `List(Option(T))`, because PostgreSQL
  never forbids a NULL element.
- A `timestamp`, `timestamptz` or `date` value of `infinity` or
  `-infinity` gives a 500 that names the function, the column and the
  Gleam type.
- A parameter inside a built-in length coercion, such as the one of a
  `varchar(10)` column, is stored straight: it is `Option` when the column
  accepts NULL.
- `schema_fingerprint` in each module, for `client.check_schema` of
  dream_postgres at start-up.
- The settings `database_url_variable` and `models` in
  `[tools.dream_model]` of `gleam.toml`.
- Support for PostgreSQL 16, 17, 18 and 19.

### Fixed after the review of 1.0.0
- A rule that adds queries, for example `DO ALSO`, makes every parameter
  required.
- A cast of a parameter to a domain, and a parameter of a domain type,
  must accept NULL for the parameter to be `Option`. This also holds
  inside a length coercion.
- A parameter is required when its column is in a partition key, when a
  generated column uses the column, when the statement writes through a
  view `WITH CHECK OPTION`, and when the target or one of its partitions
  or child tables is not a table (a view with an `INSTEAD OF` trigger, a
  foreign table).
- A CHECK with a whole-row reference or with no column counts for every
  column. The trigger rule reads row-level `BEFORE` and `INSTEAD OF`
  triggers, the same bits as the fingerprint of dream_postgres.
- A column of a foreign child table or partition is `Option`.
- Hints come only from the comment block at the top of the file.
- The tables of a module include each view that its statements read, so
  a changed view definition changes the fingerprint. The fingerprint of
  dream_postgres also holds `INSTEAD OF` row triggers, the
  `check_option` of views and the expression of generated columns.
- The generator refuses a type name of the Gleam prelude or of an
  import, two types with one decoder name, and a parameter name of a
  helper or a decoder.
- Generation removes a stale module (its folder holds no `.sql` file),
  and `--check` lists it. The command never overwrites a file without
  the generated header line.
- The URL: the password ends at the last `@`, an `@` after the host and
  unknown query keys are refused, and no message holds the password.
  A cleartext password needs TLS, and SCRAM computes at most 1,000,000
  iterations. A connection that breaks in the middle of a response is
  closed.
- The guides: Getting started, Hints, Why is this column Option?, Types,
  Errors, CI and schema drift, and Command reference.

### Testing
- The full test run on PostgreSQL 16, 17, 18 and 19: 2552 tests, 0
  failed, 100.0% line coverage (2104 of 2104 lines). The run took 4
  minutes 34 seconds of wall time, and the runner reports 6 minutes 38
  seconds of test time. Mode: one `gleam test` with the default
  versions (16 to 19), the test groups in parallel and the end-to-end tests
  one at a time, with the fuzz tests (seeds 101, 202 and 303) and the
  sqlc corpus test. Machine: Apple M1 Max, 10 cores, 64 GB, macOS
  26.5.1, OTP 29, Gleam 1.19.2.
- The fuzzer makes random schemas, data and queries, analyzes each query
  and runs it on each data set: a column typed never NULL must never
  return NULL, and each `Option` parameter must accept NULL. The long
  runs with new seeds analyzed 20,809 queries with 0 failures: seed
  48151 on PostgreSQL 16 (5,196 queries), seed 59273 on 17 (5,210),
  seed 61409 on 18 (5,212) and seed 73627 on 19 (5,191).
- The mutation test switches off or widens one rule at a time in a copy
  of the source, and requires failing tests: 36 mutants, each one
  killed. They cover the NULL rules of columns and parameters, each
  never-NULL construct, the length coercion, the ambiguous unique name
  refusal and array elements as `Option`. The run took 48 minutes 32
  seconds on the same machine.
