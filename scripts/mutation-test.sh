#!/bin/sh
# Proves that the tests have teeth: for each NULL rule, and for the
# generator rules on unique hints and array elements, it switches that one
# rule off (or widens it) in a copy of the repository and requires the
# tests to fail.
#
# The script copies the repository to a temporary folder once. For each
# mutant it restores the original source, applies the mutant's change to
# one file (an exact text replacement), and runs `gleam test` on the
# PostgreSQL version that the rule is about. A mutant that the tests do not
# kill survives. The script prints a table of rule, version and failing
# test counts, and exits with status 1 when a mutant survives or when a
# mutant's text is no longer in the source.
#
# The tests need the PostgreSQL servers (`make db-up`), the sqlc corpus
# (`sh scripts/fetch-corpus.sh`) and the packages of the end-to-end app
# (`sh scripts/stand-ins.sh`). The copy uses its own attack database,
# dream_model_attack_mutation, but the same model, end-to-end, fuzz and
# corpus databases as the repository: do not run `gleam test` in the
# repository at the same time. The temporary folder is removed on exit.
#
# Each mutant names the test files that kill it. The script records the
# result of each mutant in scripts/mutation-results.tsv, with the commit it
# ran on and a SHA-256 hash of the files it depends on: the source file
# that it changes and its test files. A later run skips a mutant whose
# recorded result is "killed" and whose hash still matches. --all runs
# every mutant. The nightly workflow uses --all. Commit the results file
# after a run. Its columns, divided by tabs: the mutant, the version, the
# hash, the commit (with "+changes" when src or test had uncommitted
# changes), the result, the number of failed tests, and a note.
#
# Usage: sh scripts/mutation-test.sh [--all] [pattern]
#   With a pattern, only the mutants whose name contains it run.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
run_all=false
if [ "${1:-}" = "--all" ]; then
  run_all=true
  shift
fi
filter="${1:-}"
results="$root/scripts/mutation-results.tsv"
commit=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- src test)" ]; then
  commit="$commit+changes"
fi
touch "$results"
rules="src/dream_model/nullability/rules.gleam"
generator_query="src/dream_model/generator/query.gleam"
gleam_type="src/dream_model/generator/gleam_type.gleam"
catalog="src/dream_model/postgres/catalog.gleam"
hint="src/dream_model/nullability/hint.gleam"
model="src/dream_model/generator/model.gleam"
command="src/dream_model/command.gleam"
wire="src/dream_model/postgres/wire.gleam"
scram="src/dream_model/postgres/scram.gleam"
# The test files that kill the mutants of the NULL rules.
rule_tests="test/dream_model/nullability/attack_test.gleam test/fixtures/attack_database.gleam test/fixtures/harness.gleam test/dream_model/nullability/rules_test.gleam test/dream_model/command_test.gleam"

if [ ! -d build/corpus ]; then
  echo "build/corpus does not exist: run sh scripts/fetch-corpus.sh first"
  exit 1
fi
if [ ! -f build/e2e/model_app/build/packages/packages.toml ]; then
  echo "the end-to-end app has no packages: run sh scripts/stand-ins.sh first"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

copy="$work/repository"
mkdir -p "$copy/build"
for item in gleam.toml manifest.toml src test scripts docs e2e; do
  cp -R "$item" "$copy/$item"
done
cp -R build/packages "$copy/build/packages"
cp -R build/corpus "$copy/build/corpus"
mkdir -p "$copy/build/e2e/model_app"
cp -R build/e2e/model_app/build "$copy/build/e2e/model_app/build"
mkdir -p "$work/original"
cp -R src "$work/original/src"

# The copy has its own attack database, so that it never drops the one of
# a test run in the repository.
sed 's/"dream_model_attack"/"dream_model_attack_mutation"/' \
  test/fixtures/attack_database.gleam > "$copy/test/fixtures/attack_database.gleam"

# Replaces the first exact occurrence of SEARCH with REPLACE in a file.
# Exits with status 3 when SEARCH is not in the file.
replace_text() {
  SEARCH="$2" REPLACE="$3" perl -e '
    my $file = shift;
    open(my $in, "<", $file) or die "cannot read $file";
    local $/;
    my $text = <$in>;
    close($in);
    my $at = index($text, $ENV{SEARCH});
    exit 3 if $at < 0;
    substr($text, $at, length($ENV{SEARCH})) = $ENV{REPLACE};
    open(my $out, ">", $file) or die "cannot write $file";
    print $out $text;
    close($out);
  ' "$1"
}

# Runs the tests of the copy on one version. Prints the counts:
# "failed fuzz corpus", or "none" when the run printed no summary (the
# build failed).
run_tests() {
  log="$work/test.log"
  set +e
  (cd "$copy" && DREAM_MODEL_TEST_VERSIONS="$1" gleam test) > "$log" 2>&1
  set -e
  summary=$(grep -E '^Summary: ' "$log" | tail -n 1)
  if [ -z "$summary" ]; then
    echo "none"
    return
  fi
  failed=$(echo "$summary" | sed -E 's/.* ([0-9]+) failed.*/\1/')
  failures=$(sed -n '/^Failures:/,/^Summary:/p' "$log")
  fuzz=$(echo "$failures" | grep -c '✗ seed ' || true)
  corpus=$(echo "$failures" | grep -c '✗ finds no wrong never-NULL' || true)
  echo "$failed $fuzz $corpus"
}

# Runs the baseline once, before the first mutant that runs: the tests
# must pass without a mutant.
baseline_done=false
run_baseline() {
  if [ "$baseline_done" = true ]; then
    return
  fi
  echo "Baseline: the tests must pass without a mutant (PostgreSQL 16 17 18)"
  baseline=$(run_tests "16 17 18")
  if [ "$baseline" != "0 0 0" ]; then
    echo "The tests fail without a mutant ($baseline). Log:"
    tail -n 60 "$work/test.log"
    exit 1
  fi
  baseline_done=true
}

# Prints the SHA-256 hash of the files that a mutant depends on.
dependency_hash() {
  # shellcheck disable=SC2086
  cat "$@" | shasum -a 256 | cut -c1-16
}

# Prints the recorded row of a mutant on a version, or nothing.
recorded() {
  awk -F '\t' -v name="$1" -v version="$2" '$1 == name && $2 == version' "$results"
}

# Replaces the recorded row of a mutant on a version.
record() {
  awk -F '\t' -v name="$1" -v version="$2" '!($1 == name && $2 == version)' "$results" > "$work/results"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$work/results"
  sort "$work/results" > "$results"
}

table="$work/table"
printf '%-44s %-8s %-8s %-6s %-7s %s\n' "rule" "version" "failing" "fuzz" "corpus" "result" > "$table"
survivors=0
broken=0
skipped=0
ran=0

# Defines and runs one mutant: name, versions, file, text, replacement,
# and the test files that kill it.
mutant() {
  name="$1"
  versions="$2"
  file="$3"
  search="$4"
  replacement="$5"
  tests="$6"
  if [ -n "$filter" ] && ! echo "$name" | grep -q -- "$filter"; then
    return
  fi
  # shellcheck disable=SC2086
  hash=$(dependency_hash "$file" $tests)
  for version in $versions; do
    row=$(recorded "$name" "$version")
    if [ "$run_all" = false ] && [ -n "$row" ] \
      && [ "$(echo "$row" | cut -f3)" = "$hash" ] \
      && [ "$(echo "$row" | cut -f5)" = "killed" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    run_baseline
    ran=$((ran + 1))
    rm -rf "$copy/src"
    cp -R "$work/original/src" "$copy/src"
    if ! replace_text "$copy/$file" "$search" "$replacement"; then
      printf '%-44s %-8s %-8s %-6s %-7s %s\n' "$name" "$version" "-" "-" "-" "TEXT NOT FOUND" >> "$table"
      record "$name" "$version" "$hash" "$commit" "text not found" "-" ""
      broken=$((broken + 1))
      continue
    fi
    echo "Mutant: $name on PostgreSQL $version"
    counts=$(run_tests "$version")
    if [ "$counts" = "none" ]; then
      printf '%-44s %-8s %-8s %-6s %-7s %s\n' "$name" "$version" "-" "-" "-" "RUN FAILED" >> "$table"
      record "$name" "$version" "$hash" "$commit" "run failed" "-" ""
      tail -n 30 "$work/test.log"
      broken=$((broken + 1))
      continue
    fi
    # shellcheck disable=SC2086
    set -- $counts
    if [ "$1" -gt 0 ]; then
      result="killed"
    else
      result="SURVIVED"
      survivors=$((survivors + 1))
    fi
    printf '%-44s %-8s %-8s %-6s %-7s %s\n' "$name" "$version" "$1" "$2" "$3" "$result" >> "$table"
    record "$name" "$version" "$hash" "$commit" "$(echo "$result" | tr 'A-Z' 'a-z')" "$1" ""
  done
}

# --- Result columns ---------------------------------------------------------

mutant "outer-join nulling (varnullingrels)" "16" "$rules" \
  'node.integers(node.get_field(variable, "varnullingrels")) != []' \
  'False' \
  "$rule_tests"

mutant "computed value assumed not null" "16" "$rules" \
  'Traced(False, Computed, reason.ComputedValue(string.lowercase(name)))' \
  'Traced(True, Computed, reason.ComputedValue(string.lowercase(name)))' \
  "$rule_tests"

mutant "RETURNING old/new row missing" "18" "$rules" \
  'when: is_missing_returning_row(variable, owner),' \
  'when: False,' \
  "$rule_tests"

mutant "MERGE source without match" "17" "$rules" \
  'when: is_merge_source_without_match(variable, owner, levels_up),' \
  'when: False,' \
  "$rule_tests"

mutant "grouping sets empty a column" "16 17" "$rules" \
  'when: has_grouping_sets(owner),' \
  'when: False,' \
  "$rule_tests"

# --- Never-NULL computed values: each construct widened, then off ----------

mutant "never-NULL constant: only non-NULL ones" "16" "$rules" \
  'node.text(node.get_field(expression, "constisnull")) == "false"' \
  'True' \
  "$rule_tests"

mutant "never-NULL constant: off" "16" "$rules" \
  'node.text(node.get_field(expression, "constisnull")) == "false",
        reason.NonNullConstant,' \
  'False,
        reason.NonNullConstant,' \
  "$rule_tests"

mutant "never-NULL count: only count" "16" "$rules" \
  'is_function(catalog, node.get_field(expression, "aggfnoid"), "count")' \
  'True' \
  "$rule_tests"

mutant "never-NULL count: only pg_catalog count" "16" "$rules" \
  'function.schema == "pg_catalog" && function.name == name' \
  'function.name == name' \
  "$rule_tests"

mutant "never-NULL count: off" "16" "$rules" \
  'is_function(catalog, node.get_field(expression, "aggfnoid"), "count"),' \
  'False,' \
  "$rule_tests"

mutant "never-NULL EXISTS: only EXISTS sublinks" "16" "$rules" \
  'node.text(node.get_field(expression, "subLinkType")) == "0"' \
  'True' \
  "$rule_tests"

mutant "never-NULL EXISTS: off" "16" "$rules" \
  'node.text(node.get_field(expression, "subLinkType")) == "0",' \
  'False,' \
  "$rule_tests"

mutant "never-NULL IS [NOT] NULL: off" "16" "$rules" \
  '"NULLTEST" -> Ok(reason.NullTest)' \
  '"NULLTEST" -> Error(Nil)' \
  "$rule_tests"

mutant "never-NULL IS DISTINCT FROM: built-in only" "16" "$rules" \
  'is_built_in(catalog, node.get_field(expression, "opfuncid"))' \
  'True' \
  "$rule_tests"

mutant "never-NULL IS DISTINCT FROM: off" "16" "$rules" \
  'is_built_in(catalog, node.get_field(expression, "opfuncid")),' \
  'False,' \
  "$rule_tests"

mutant "never-NULL coalesce: last argument not NULL" "16" "$rules" \
  'last_argument_not_null(expression, stack, catalog)' \
  'True' \
  "$rule_tests"

mutant "never-NULL coalesce: off" "16" "$rules" \
  'last_argument_not_null(expression, stack, catalog),' \
  'False,' \
  "$rule_tests"

mutant "grouping-expression hazard" "16" "$rules" \
  'case is_grouping_expression(query, expression) {' \
  'case False {' \
  "$rule_tests"

# Before PostgreSQL 18 a child table cannot drop an inherited NOT NULL, so
# only NOT NULL ... NO INHERIT (18 and newer) makes a child column nullable.
mutant "inheritance child tables" "18" "$rules" \
  'True -> [oid, ..relation.descendants]' \
  'True -> [oid]' \
  "$rule_tests"

mutant "NOT VALID NOT NULL" "18" "$rules" \
  'list.contains(relation.not_valid_not_null, name),' \
  'False,' \
  "$rule_tests"

# --- Parameters -------------------------------------------------------------

mutant "parameter store: column NOT NULL" "16" "$rules" \
  'when: attribute.not_null,
    return: Error(reason.ColumnIsNotNull),' \
  'when: False,
    return: Error(reason.ColumnIsNotNull),' \
  "$rule_tests"

mutant "parameter store: length coercion is pass-through" "16" "$rules" \
  'is_cast && is_coercion_function && has_constant_modifiers' \
  'False' \
  "$rule_tests"

mutant "parameter store: any function is pass-through" "16" "$rules" \
  'is_cast && is_coercion_function && has_constant_modifiers' \
  'node.node_name(expression) == "FUNCEXPR"' \
  "$rule_tests"

mutant "parameter store: used outside the store" "16" "$rules" \
  '_, False -> ParameterRule(False, reason.AlsoUsedOutsideStore)' \
  '_, False -> ParameterRule(True, reason.StoredIntoNullableColumn)' \
  "$rule_tests"

mutant "parameter: BEFORE trigger" "16" "$rules" \
  'when: list.any(family, fn(member) { member.has_before_trigger }),' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: row-level security" "16" "$rules" \
  'when: list.any(family, fn(member) { member.has_row_security }),' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: CHECK constraint" "16" "$rules" \
  'when: names_column(relation.check_columns, store.column),' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: partition NOT NULL" "16" "$rules" \
  'when: attribute.not_null,
    return: Error(reason.PartitionNotNull),' \
  'when: False,
    return: Error(reason.PartitionNotNull),' \
  "$rule_tests"

mutant "parameter: partition CHECK" "16" "$rules" \
  'when: names_column(member.check_columns, attribute.number),' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: domain NOT NULL" "16" "$rules" \
  'use <- bool.guard(when: domain.not_null, return: Error(reason.DomainNotNull))' \
  'use <- bool.guard(when: False, return: Error(reason.DomainNotNull))' \
  "$rule_tests"

mutant "parameter: domain CHECK" "16" "$rules" \
  'refuse_when(domain.has_check, reason.DomainCheck)' \
  'refuse_when(False, reason.DomainCheck)' \
  "$rule_tests"

# --- The review of 1.0.0 -----------------------------------------------------

mutant "parameter: a rule adds queries" "16" "$rules" \
  'when: queries > 1,' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: casts to a domain" "16" "$rules" \
  'use Nil <- result.try(check_cast_domains(catalog, store))' \
  'use Nil <- result.try(Ok(Nil))' \
  "$rule_tests"

mutant "parameter: target is not a table" "16" "$rules" \
  'use Nil <- result.try(check_table_kind(relation))' \
  'use Nil <- result.try(Ok(Nil))' \
  "$rule_tests"

mutant "parameter: partition is not a table" "16" "$rules" \
  'use Nil <- result.try(check_table_kind(member))' \
  'use Nil <- result.try(Ok(Nil))' \
  "$rule_tests"

mutant "parameter: partition key" "16" "$rules" \
  'when: names_column(member.partition_key_columns, attribute.number),' \
  'when: False,' \
  "$rule_tests"

mutant "parameter: generated column" "16" "$rules" \
  'list.contains(member.generated_sources, attribute.number),' \
  'False,' \
  "$rule_tests"

mutant "parameter: view WITH CHECK OPTION" "16" "$rules" \
  'refuse_when(has_check_option, reason.ViewCheckOption)' \
  'refuse_when(False, reason.ViewCheckOption)' \
  "$rule_tests"

mutant "parameter: whole-row CHECK" "16" "$rules" \
  '|| list.contains(columns, 0)' \
  '|| False' \
  "$rule_tests"

mutant "foreign child table" "16" "$rules" \
  'Ok(#(relation, _)) if relation.kind != "r" && relation.kind != "p" ->' \
  'Ok(#(relation, _)) if False ->' \
  "$rule_tests"

mutant "fingerprint: views that a query reads" "16" "$rules" \
  '"RANGETBLENTRY", "1" if relation > 0 ->' \
  '"RANGETBLENTRY", "1" if False ->' \
  "$rule_tests"

mutant "trigger: INSTEAD OF row bit" "16" "$catalog" \
  'or (t.tgtype & 65) = 65' \
  '' \
  "test/dream_model/postgres/catalog_test.gleam test/fixtures/attack_database.gleam"

mutant "trigger: statement-level BEFORE" "16" "$catalog" \
  '(t.tgtype & 3) = 3' \
  '(t.tgtype & 2) = 2' \
  "test/dream_model/postgres/catalog_test.gleam test/fixtures/attack_database.gleam"

mutant "hints: only the comment block at the top" "16" "$hint" \
  '"--" <> _ -> True
      _ -> False' \
  '"--" <> _ -> True
      _ -> True' \
  "test/dream_model/nullability/hint_test.gleam $rule_tests"

# --- Generator --------------------------------------------------------------

mutant "names: reserved type names" "16" "$model" \
  'case record.alias, list.contains(reserved_type_names, record.name) {' \
  'case record.alias, False {' \
  "test/dream_model/generator/model_test.gleam"

mutant "names: one decoder for two types" "16" "$model" \
  '|> list.find(fn(earlier) { record_decoder_name(earlier) == decoder })' \
  '|> list.find(fn(_) { False })' \
  "test/dream_model/generator/model_test.gleam"

mutant "names: parameter of a helper" "16" "$generator_query" \
  'list.contains(reserved_argument_names, argument_name)' \
  'list.contains(["db", "client", "decode"], argument_name)' \
  "test/dream_model/generator/query_test.gleam"

mutant "names: parameter of a decoder" "16" "$generator_query" \
  '|| string.ends_with(argument_name, decoder_suffix)' \
  '|| False' \
  "test/dream_model/generator/query_test.gleam"

mutant "--check: stale modules" "16" "$command" \
  'use stale <- result.try(find_stale_modules(directory))' \
  'use stale <- result.try(Ok([]))' \
  "test/dream_model/command_test.gleam"

mutant "write: a file without the header" "16" "$command" \
  'use Nil <- result.try(refuse_foreign_files(directory, modules))' \
  'use Nil <- result.try(Ok(Nil))' \
  "test/dream_model/command_test.gleam"

mutant "URL: an @ after the host" "16" "$wire" \
  'use Nil <- result.try(case string.contains(after_authority, "@") {' \
  'use Nil <- result.try(case False {' \
  "test/dream_model/postgres/wire_test.gleam test/fixtures/fake_server.gleam test/dream_model_test_ffi.erl"

mutant "URL: unknown query keys" "16" "$wire" \
  '|> list.filter(fn(key) { !list.contains(query_keys, key) })' \
  '|> list.filter(fn(_) { False })' \
  "test/dream_model/postgres/wire_test.gleam test/fixtures/fake_server.gleam test/dream_model_test_ffi.erl"

mutant "wire: close after a broken response" "16" "$wire" \
  'result.map_error(exchanged, close_after_failure(connection.socket, _))' \
  'exchanged' \
  "test/dream_model/postgres/wire_test.gleam test/fixtures/fake_server.gleam test/dream_model_test_ffi.erl"

mutant "wire: cleartext needs TLS" "16" "$wire" \
  'NoTls -> Error(CleartextWithoutTls)' \
  'NoTls -> Ok(Nil)' \
  "test/dream_model/postgres/wire_test.gleam test/fixtures/fake_server.gleam test/dream_model_test_ffi.erl"

mutant "SCRAM: the iteration cap" "16" "$scram" \
  'case iterations > 0, iterations > maximum_iterations {' \
  'case iterations > 0, False {' \
  "test/dream_model/postgres/scram_test.gleam"

mutant "unique hint: refuse an ambiguous name" "16" "$generator_query" \
  'case descriptions_of(rows, "other") {' \
  'case descriptions_of(rows, "none") {' \
  "test/dream_model/generator/query_test.gleam"

mutant "array elements: Option type" "16" "$gleam_type" \
  'ListType(element) -> "List(Option(" <> type_text(element) <> "))"' \
  'ListType(element) -> "List(" <> type_text(element) <> ")"' \
  "test/dream_model/generator/gleam_type_test.gleam"

mutant "array elements: optional decoder" "16" "$gleam_type" \
  '"decode.list(decode.optional("' \
  '"decode.list(("' \
  "test/dream_model/generator/gleam_type_test.gleam"

mutant "array elements: nullable value function" "16" "$gleam_type" \
  '"client.nullable(" <> encoder_text(element) <> ", _)"' \
  'encoder_text(element)' \
  "test/dream_model/generator/gleam_type_test.gleam"

echo
cat "$table"
echo
echo "failing: failed tests; fuzz: failed fuzz seeds; corpus: failed corpus runs"
echo "$ran mutant runs, $skipped skipped (a killed result with the same hash is in scripts/mutation-results.tsv)"
if [ "$survivors" -gt 0 ] || [ "$broken" -gt 0 ]; then
  echo "$survivors mutants survived, $broken mutants did not apply, build or run"
  exit 1
fi
echo "Every mutant was killed"
