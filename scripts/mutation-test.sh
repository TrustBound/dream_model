#!/bin/sh
# Proves that the tests have teeth: for each NULL rule, it switches that
# one rule off in a copy of the repository and requires the tests to fail.
#
# The script copies the repository to a temporary folder once. For each
# mutant it restores the original source, applies the mutant's change to
# one file (an exact text replacement), and runs `gleam test` on the
# PostgreSQL version that the rule is about. A mutant that the tests do not
# kill survives. The script prints a table of rule, version and failing
# test counts, and exits with status 1 when a mutant survives or when a
# mutant's text is no longer in the source.
#
# The tests need the PostgreSQL servers (`make db-up`) and the sqlc corpus
# (`sh scripts/fetch-corpus.sh`). The copy uses its own attack database,
# dream_model_attack_mutation. The temporary folder is removed on exit.
#
# Usage: sh scripts/mutation-test.sh [pattern]
#   With a pattern, only the mutants whose name contains it run.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
filter="${1:-}"
rules="src/dream_model/nullability/rules.gleam"

if [ ! -d build/corpus ]; then
  echo "build/corpus does not exist: run sh scripts/fetch-corpus.sh first"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

copy="$work/repository"
mkdir -p "$copy/build"
for item in gleam.toml manifest.toml src test; do
  cp -R "$item" "$copy/$item"
done
cp -R build/packages "$copy/build/packages"
cp -R build/corpus "$copy/build/corpus"
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

echo "Baseline: the tests must pass without a mutant (PostgreSQL 16 17 18)"
baseline=$(run_tests "16 17 18")
if [ "$baseline" != "0 0 0" ]; then
  echo "The tests fail without a mutant ($baseline). Log:"
  tail -n 60 "$work/test.log"
  exit 1
fi

table="$work/table"
printf '%-44s %-8s %-8s %-6s %-7s %s\n' "rule" "version" "failing" "fuzz" "corpus" "result" > "$table"
survivors=0
broken=0

# Defines and runs one mutant: name, versions, file, text, replacement.
mutant() {
  name="$1"
  versions="$2"
  file="$3"
  search="$4"
  replacement="$5"
  if [ -n "$filter" ] && ! echo "$name" | grep -q -- "$filter"; then
    return
  fi
  for version in $versions; do
    rm -rf "$copy/src"
    cp -R "$work/original/src" "$copy/src"
    if ! replace_text "$copy/$file" "$search" "$replacement"; then
      printf '%-44s %-8s %-8s %-6s %-7s %s\n' "$name" "$version" "-" "-" "-" "TEXT NOT FOUND" >> "$table"
      broken=$((broken + 1))
      continue
    fi
    echo "Mutant: $name on PostgreSQL $version"
    counts=$(run_tests "$version")
    if [ "$counts" = "none" ]; then
      printf '%-44s %-8s %-8s %-6s %-7s %s\n' "$name" "$version" "-" "-" "-" "RUN FAILED" >> "$table"
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
  done
}

# --- Result columns ---------------------------------------------------------

mutant "outer-join nulling (varnullingrels)" "16" "$rules" \
  'node.integers(node.get_field(variable, "varnullingrels")) != []' \
  'False'

mutant "computed value assumed not null" "16" "$rules" \
  'Traced(False, Computed, reason.ComputedValue(string.lowercase(name)))' \
  'Traced(True, Computed, reason.ComputedValue(string.lowercase(name)))'

mutant "RETURNING old/new row missing" "18" "$rules" \
  'when: is_missing_returning_row(variable, owner),' \
  'when: False,'

mutant "MERGE source without match" "17" "$rules" \
  'when: is_merge_source_without_match(variable, owner, levels_up),' \
  'when: False,'

mutant "grouping sets empty a column" "16 17" "$rules" \
  'when: has_grouping_sets(owner),' \
  'when: False,'

mutant "D2 constant: only non-NULL constants" "16" "$rules" \
  'node.text(node.get_field(expression, "constisnull")) == "false"' \
  'True'

mutant "D2 count: only count" "16" "$rules" \
  'is_function(catalog, node.get_field(expression, "aggfnoid"), "count")' \
  'True'

mutant "D2 count: only pg_catalog count" "16" "$rules" \
  'function.schema == "pg_catalog" && function.name == name' \
  'function.name == name'

mutant "D2 EXISTS: only EXISTS sublinks" "16" "$rules" \
  'node.text(node.get_field(expression, "subLinkType")) == "0"' \
  'True'

mutant "D2 IS [NOT] NULL: never NULL" "16" "$rules" \
  '"NULLTEST" -> Ok(reason.NullTest)' \
  '"NULLTEST" -> Error(Nil)'

mutant "D2 IS DISTINCT FROM: built-in operator" "16" "$rules" \
  'is_built_in(catalog, node.get_field(expression, "opfuncid"))' \
  'True'

mutant "D2 coalesce: last argument not NULL" "16" "$rules" \
  'last_argument_not_null(expression, stack, catalog)' \
  'True'

mutant "grouping-expression hazard" "16" "$rules" \
  'case is_grouping_expression(query, expression) {' \
  'case False {'

mutant "inheritance child tables" "16" "$rules" \
  'True -> [oid, ..relation.descendants]' \
  'True -> [oid]'

mutant "NOT VALID NOT NULL" "18" "$rules" \
  'list.contains(relation.not_valid_not_null, name),' \
  'False,'

# --- Parameters -------------------------------------------------------------

mutant "parameter store: column NOT NULL" "16" "$rules" \
  'when: attribute.not_null,
    return: Error(reason.ColumnIsNotNull),' \
  'when: False,
    return: Error(reason.ColumnIsNotNull),'

mutant "parameter store: used outside the store" "16" "$rules" \
  '_, False -> ParameterRule(False, reason.AlsoUsedOutsideStore)' \
  '_, False -> ParameterRule(True, reason.StoredIntoNullableColumn)'

mutant "parameter: BEFORE trigger" "16" "$rules" \
  'when: list.any(family, fn(member) { member.has_before_trigger }),' \
  'when: False,'

mutant "parameter: row-level security" "16" "$rules" \
  'when: list.any(family, fn(member) { member.has_row_security }),' \
  'when: False,'

mutant "parameter: CHECK constraint" "16" "$rules" \
  'when: list.contains(relation.check_columns, column),' \
  'when: False,'

mutant "parameter: partition NOT NULL" "16" "$rules" \
  'when: attribute.not_null,
    return: Error(reason.PartitionNotNull),' \
  'when: False,
    return: Error(reason.PartitionNotNull),'

mutant "parameter: partition CHECK" "16" "$rules" \
  'list.contains(member.check_columns, attribute.number),' \
  'False,'

mutant "parameter: domain NOT NULL" "16" "$rules" \
  'use <- bool.guard(when: domain.not_null, return: Error(reason.DomainNotNull))' \
  'use <- bool.guard(when: False, return: Error(reason.DomainNotNull))'

mutant "parameter: domain CHECK" "16" "$rules" \
  'refuse_when(domain.has_check, reason.DomainCheck)' \
  'refuse_when(False, reason.DomainCheck)'

echo
cat "$table"
echo
echo "failing: failed tests; fuzz: failed fuzz seeds; corpus: failed corpus runs"
if [ "$survivors" -gt 0 ] || [ "$broken" -gt 0 ]; then
  echo "$survivors mutants survived, $broken mutants did not apply, build or run"
  exit 1
fi
echo "Every mutant was killed"
