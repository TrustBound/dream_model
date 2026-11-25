# dream_model Makefile

.PHONY: test build format check check-snippets docs clean db-up db-down corpus fuzz mutation-test

# Run the tests with line coverage (fails below 100%). The tests need the
# PostgreSQL servers of docker-compose.yml: start them with `make db-up`.
# DREAM_MODEL_TEST_VERSIONS picks the versions to test, for example
# `DREAM_MODEL_TEST_VERSIONS=16 make test`. The default is 16 17 18 19.
test:
	@gleam test

build:
	@gleam build

format:
	@gleam format src test

# Run everything CI runs: format check, build, tests, docs build and the
# snippet check
check:
	@gleam format --check src test
	@gleam build
	@gleam test
	@gleam docs build
	@gleam run -m dream_snippets

# Fetch sqlc's PostgreSQL end-to-end test queries into build/corpus. The
# corpus test of `make test` needs them.
corpus:
	@sh scripts/fetch-corpus.sh

# The long fuzz run with a new seed. SEED, SCHEMAS and QUERIES change it,
# for example `make fuzz SEED=1234`.
SCHEMAS ?= 100
QUERIES ?= 60
fuzz:
	@gleam run -m fuzz -- $(if $(SEED),--seed $(SEED)) --schemas $(SCHEMAS) --queries $(QUERIES)

# Switch off each NULL rule in turn and make sure that the tests fail.
mutation-test:
	@sh scripts/mutation-test.sh

check-snippets:
	@gleam run -m dream_snippets

docs:
	@gleam docs build

db-up:
	@sh scripts/db-up.sh

db-down:
	@docker compose down -v

clean:
	@gleam clean
	@rm -f erl_crash.dump
