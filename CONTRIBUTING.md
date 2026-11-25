# Contributing to dream_model

## Set up the packages that are not on Hex yet

dream_model needs dream_postgres 2.1.0, with dream_postgres_client 1.1.0 and dream_postgres_driver 1.1.0, which read and write a `numeric` as exact text. The end-to-end app in `e2e/model_app` also needs Dream 3.0.0 and dream_model itself. Until dream_postgres 2.1.0 and Dream 3.0.0 are on Hex, the build uses local copies of these packages, and CI fails at `gleam deps download`.

1. Clone dream_postgres and check out the branch with version 2.1.0. Run `gleam build` there, so that its `build/packages` holds dream_postgres_client 1.1.0, dream_postgres_driver 1.1.0 and the other packages of dream_postgres.
2. Clone Dream, and run `gleam build` in a checkout of the Dream 3.0.0 commit, so that its `build/packages` holds the Hex packages of Dream.
3. Run `sh scripts/stand-ins.sh` in this repository. Set `DREAM_POSTGRES_SOURCE`, `DREAM_SOURCE`, `DREAM_COMMIT` and `DREAM_PACKAGES` when the clones are not next to this repository. The script lists each variable.

The script copies each package into `build/packages` and into `build/e2e/model_app/build/packages`, and lists it in `packages.toml`. Gleam then makes no Hex request for these packages. `manifest.toml` and `e2e/model_app/manifest.toml` hold the entries of the unpublished packages, with a checksum of zeros.

CI runs `sh scripts/e2e-packages.sh` for the end-to-end app. It puts the dream_model of the checkout into the packages of the app and downloads the other packages from Hex, so it works when dream_postgres 2.1.0 and Dream 3.0.0 are on Hex.

When these packages are on Hex, remove `scripts/stand-ins.sh` and this section, and run `gleam deps update dream_postgres dream_postgres_client dream_postgres_driver` here and `gleam deps update dream dream_postgres dream_postgres_client dream_postgres_driver dream_model` in `e2e/model_app`, to write the real checksums.

## Run the tests

1. Start the PostgreSQL servers with `make db-up`.
2. Run `gleam test`. `DREAM_MODEL_TEST_VERSIONS="16 18"` picks the versions. The line coverage must be 100% when the tests run on every version.

The tests that are the same on every version are one group, and each version is one group. The groups run at the same time, because each version has its own server and databases. The suites of one group run one after the other. Each group writes its own report, and the coverage is measured over all groups together. With arguments after `--`, for example `gleam test -- --only ...`, the groups run one after the other in one run.

Other environment variables of the tests:

- `DREAM_MODEL_TEST_DATABASE_PREFIX=w1_` puts a prefix before the name of each database that the tests create. Two test runs with different prefixes can use the same servers at the same time.
- `DREAM_MODEL_TEST_MODULES="attack_test rules_test"` runs only the suites of these test modules, with no coverage.
- `DREAM_MODEL_TEST_COVERAGE=off` measures no coverage.

The end-to-end tests copy `e2e/model_app` to `build/e2e/<version>/model_app`, generate its models on each version, compare them with the modules in `e2e/model_app/src/app/models` (without the fingerprint hash, which is different on each version), run the generated code against the database, and compare its output with `e2e/model_app/expected_output.txt`.

When a change to the generator changes the generated code on purpose, copy the new modules from `build/e2e/16/model_app/src/app/models` to `e2e/model_app/src/app/models` after a run on PostgreSQL 16.

## Run the mutation test

`sh scripts/mutation-test.sh` (or `make mutation-test`) proves that the tests fail when a rule is switched off. Each mutant in the script changes one exact text in one source file, and names its PostgreSQL versions and the test files that kill it.

1. A worker applies the change to its own copy of the repository and compiles it once for all versions of the mutant.
2. The test modules of the mutant run first. When they pass, every test runs. When only the run of every test kills the mutant, the script prints a warning with the test modules that killed it: add them to the mutant.
3. `--jobs N` runs N workers at the same time (default 3). Each worker uses its own database names (the prefix `mutation_w<N>_`) and drops its databases at the end.

The results are in `scripts/mutation-results.tsv`. A run skips a mutant whose result is "killed" and whose hash still matches. The hash covers the function (or constant) that the change is in and the test files of the mutant, so a change to another function of the same file does not run the mutant again. `--all` runs every mutant, as the nightly workflow does. Commit the results file after a run.

## Write the docs

Every code block in the README, the guides, the doc comments, the changelog and the release notes is a copy of a tested file. `gleam run -m dream_snippets` checks each block against its file.

1. Put the code in a file that a test runs. A `gleam` or `sql` block of a guide is a file in `test/snippets`, or a file of the end-to-end app in `e2e/model_app`. A `text` block is a part of `e2e/model_app/expected_output.txt`. A `sh` block is a line of a script that a test or CI runs.
2. Put a heading directly above the block. End the heading with the "Tested snippet" badge, which links to the file at the release tag, for example `https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/types/finite_rows.sql`. Add `#L4-L9` to the link for a part of a file.
3. Give each fence a language.

The SQL files of the guides are in `test/snippets/why_option` and `test/snippets/types`. `test/dream_model/docs_test.gleam` analyzes each one on each PostgreSQL version and compares the result with what the guide says. When you add a file, add its case to that test.

## Before a commit

Run `make check`: the format check, the build, the tests, the docs build and the snippet check.

A commit message has the form `fix(generator): <name>` or `docs: <name>`, a blank line, and then the sections `Why This Change Was Made`, `What Was Changed` and `Note to Future Engineer`.
