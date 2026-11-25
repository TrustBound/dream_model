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
- The guides: Getting started, Hints, Why is this column Option?, Types,
  Errors, CI and schema drift, and Command reference.

### Testing
- The full test run on PostgreSQL 16, 17, 18 and 19: 2552 tests, 0
  failed, 100.0% line coverage (2104 of 2104 lines). The run took 5
  minutes 0 seconds of wall time, and the runner reports 7 minutes 11
  seconds of test time. Mode: one `gleam test` with the default
  versions (16 to 19), the suites in parallel and the end-to-end suites
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
