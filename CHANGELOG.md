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
- The full test run on PostgreSQL 16, 17, 18 and 19: 2536 tests, 0
  failed, 100.0% line coverage (2104 of 2104 lines). The run took 81
  seconds of wall time, and the runner reports 1 minute 35 seconds of
  test time. Machine: Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP
  29, Gleam 1.19.2.
