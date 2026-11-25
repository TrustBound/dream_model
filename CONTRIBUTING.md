# Contributing to dream_model

## Set up the packages that are not on Hex yet

dream_model needs dream_postgres 2.1.0. The end-to-end app in `e2e/model_app` also needs Dream 3.0.0 and dream_model itself. Until dream_postgres 2.1.0 and Dream 3.0.0 are on Hex, the build uses local copies of these packages, and CI fails at `gleam deps download`.

1. Clone dream_postgres and check out the branch with version 2.1.0. Run `gleam build` there, so that its `build/packages` holds its Hex packages.
2. Clone Dream, and run `gleam build` in a checkout of the Dream 3.0.0 commit, so that its `build/packages` holds the Hex packages of Dream.
3. Run `sh scripts/stand-ins.sh` in this repository. Set `DREAM_POSTGRES_SOURCE`, `DREAM_SOURCE`, `DREAM_COMMIT` and `DREAM_PACKAGES` when the clones are not next to this repository. The script lists each variable.

The script copies each package into `build/packages` and into `build/e2e/model_app/build/packages`, and lists it in `packages.toml`. Gleam then makes no Hex request for these packages. `manifest.toml` and `e2e/model_app/manifest.toml` hold the entries of the unpublished packages, with a checksum of zeros.

When both packages are on Hex, remove `scripts/stand-ins.sh` and this section, and run `gleam deps update dream_postgres` here and `gleam deps update dream dream_postgres dream_model` in `e2e/model_app`, to write the real checksums.

## Run the tests

1. Start the PostgreSQL servers with `make db-up`.
2. Run `gleam test`. `DREAM_MODEL_TEST_VERSIONS="16 18"` picks the versions. The line coverage must be 100% when the tests run on every version.

The end-to-end tests copy `e2e/model_app` to `build/e2e/model_app`, generate its models on each version, compare them with the modules in `e2e/model_app/src/app/models` (without the fingerprint hash, which is different on each version), run the generated code against the database, and compare its output with `e2e/model_app/expected_output.txt`.

When a change to the generator changes the generated code on purpose, copy the new modules from `build/e2e/model_app/src/app/models` to `e2e/model_app/src/app/models` after a run on PostgreSQL 16.

## Before a commit

Run `make check`: the format check, the build, the tests, the docs build and the snippet check.
