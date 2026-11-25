#!/bin/sh
# Proves that the tests have teeth: for each NULL rule, and for the
# generator rules on unique hints and array elements, it switches that one
# rule off (or widens it) in a copy of the repository and requires the
# tests to fail.
#
# Each mutant is an exact text replacement in one source file, the
# PostgreSQL versions that it runs on, and the test files that kill it.
#
# How a mutant runs:
#
# 1. A worker applies the change to its own copy of the repository and
#    compiles the copy once. The versions of the mutant use that build.
# 2. On each version, the test modules of the mutant run first
#    (DREAM_MODEL_TEST_MODULES), with no coverage. When they kill the
#    mutant, the mutant is killed. dream_test cannot stop a run at its
#    first failure, so the short list of modules is what keeps a run short.
# 3. When the mutant's own modules pass, every test runs on that version.
#    When that kills the mutant, its list of test files is too narrow: the
#    script prints a warning with the test modules that killed it. Add them
#    to the mutant.
# 4. The worker puts the original file back before its next mutant.
#
# --jobs N runs N workers at the same time (default 3). Each worker has its
# own copy, made once, and its own databases on the shared servers: the
# prefix "<MUTATION_DATABASE_PREFIX>w<N>_" goes before the name of each
# database that its tests create (DREAM_MODEL_TEST_DATABASE_PREFIX). The
# default of MUTATION_DATABASE_PREFIX is "mutation_". The script refuses to
# start when two workers could make a database with the same name. Before
# the first mutant, a run of every test without a mutant must pass. At the
# end, and when the script is stopped, it stops the workers, drops the
# databases of each worker and removes the copies.
#
# The tests need the PostgreSQL servers (`make db-up`), psql, the sqlc
# corpus (`sh scripts/fetch-corpus.sh`) and the packages of the end-to-end
# app (`sh scripts/stand-ins.sh`).
#
# The results are in scripts/mutation-results.tsv, with the commit that a
# mutant ran on and a SHA-256 hash of what it depends on: the text of the
# function (or constant or type) that the change is in, and the test files
# of the mutant. A change elsewhere in the source file does not change the
# hash. A later run skips a mutant whose recorded result is "killed" and
# whose hash still matches. --all runs every mutant. The nightly workflow
# uses --all. Commit the results file after a run. Its columns, divided by
# tabs: the mutant, the version, the hash, the commit (with "+changes" when
# src or test had uncommitted changes), the result, the number of failed
# tests, and a note: "own modules" when the mutant's own test modules
# killed it, or "all tests" when only the run of every test did.
#
# A run that fails with "No space left on device" is recorded as "error",
# never as "killed".
#
# --own-modules-only runs only the test modules of each mutant, also for
# the baseline, and never every test. Use it when the servers are short of
# disk: a mutant that its own modules do not kill is then recorded as
# "survived" with the note "own modules only".
#
# Usage: sh scripts/mutation-test.sh [--all] [--own-modules-only] [--jobs N] [pattern]
#   With a pattern, only the mutants whose name contains it run.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
run_all=false
own_only=false
jobs=3
filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) run_all=true ;;
    --own-modules-only) own_only=true ;;
    --jobs)
      jobs="${2:-}"
      shift
      ;;
    --jobs=*) jobs="${1#--jobs=}" ;;
    *) filter="$1" ;;
  esac
  shift
done
case "$jobs" in
  '' | *[!0-9]* | 0)
    echo "--jobs needs a number of workers, 1 or more"
    exit 1
    ;;
esac
prefix_base="${MUTATION_DATABASE_PREFIX:-mutation_}"
case "$prefix_base" in
  '' | *[!a-z0-9_]*)
    echo "MUTATION_DATABASE_PREFIX must be lowercase letters, digits and _, and not empty"
    exit 1
    ;;
esac
results="$root/scripts/mutation-results.tsv"
commit=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain -- src test)" ]; then
  commit="$commit+changes"
fi
touch "$results"
all_versions="16 17 18 19"
rules="src/dream_model/nullability/rules.gleam"
generator_query="src/dream_model/generator/query.gleam"
gleam_type="src/dream_model/generator/gleam_type.gleam"
catalog="src/dream_model/postgres/catalog.gleam"
hint="src/dream_model/nullability/hint.gleam"
query_hint="src/dream_model/generator/query_hint.gleam"
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
if ! command -v psql > /dev/null; then
  echo "psql is not installed: the script drops the databases of its workers with it"
  exit 1
fi

# The prefix of the databases of each worker. No prefix may be the start of
# another one, or two workers could make a database with the same name.
worker_prefixes=""
worker=1
while [ "$worker" -le "$jobs" ]; do
  worker_prefixes="$worker_prefixes ${prefix_base}w${worker}_"
  worker=$((worker + 1))
done
for one in $worker_prefixes; do
  for other in $worker_prefixes; do
    if [ "$one" != "$other" ]; then
      case "$other" in
        "$one"*)
          echo "The workers would share databases: $one is the start of $other"
          exit 1
          ;;
      esac
    fi
  done
done

work=$(mktemp -d)
worker_pids=""

# Stops a process and every process that it started.
stop_tree() {
  for child in $(pgrep -P "$1" 2> /dev/null || true); do
    stop_tree "$child"
  done
  kill "$1" 2> /dev/null || true
}

# Drops the databases of each worker on each server that answers.
drop_worker_databases() {
  for prefix in $worker_prefixes; do
    drop_databases "$prefix"
  done
}

# Drops the databases whose name starts with a prefix on each server that
# answers.
drop_databases() {
  for version in $all_versions; do
    names=$(PGPASSWORD=dream psql -h localhost -p "$((5400 + version))" -U dream \
      -d dream_test -Atc "select datname from pg_database where left(datname, ${#1}) = '$1'" \
      2> /dev/null || true)
    for name in $names; do
      PGPASSWORD=dream psql -h localhost -p "$((5400 + version))" -U dream -d dream_test \
        -qc "drop database if exists \"$name\" with (force)" > /dev/null 2>&1 || true
    done
  done
}

clean_up() {
  trap - EXIT INT TERM
  for pid in $worker_pids; do
    stop_tree "$pid"
  done
  wait 2> /dev/null || true
  drop_worker_databases
  rm -rf "$work"
}
trap clean_up EXIT
trap 'exit 130' INT TERM

mkdir -p "$work/original" "$work/mutants" "$work/claims" "$work/rows"
cp -R src "$work/original/src"

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

# Prints the top-level item (function, constant or type) of a file that
# holds the first occurrence of SEARCH: from its first line to the line
# before the next top-level item, without the doc comments and attributes
# of that next item. Exits with status 3 when SEARCH is not in the file.
item_text() {
  SEARCH="$2" perl -e '
    my $file = shift;
    open(my $in, "<", $file) or die "cannot read $file";
    local $/;
    my $text = <$in>;
    close($in);
    my $at = index($text, $ENV{SEARCH});
    exit 3 if $at < 0;
    my ($start, $end) = (0, length($text));
    while ($text =~ /^(?:pub )?(?:fn|const|type) /mg) {
      my $line = $-[0];
      if ($line <= $at) { $start = $line } else { $end = $line; last }
    }
    my $item = substr($text, $start, $end - $start);
    $item =~ s/(?:\n(?:\/\/\/[^\n]*|\@[^\n]*|[ \t]*))*\z/\n/;
    print $item;
  ' "$1"
}

# Prints the hash of what a mutant depends on: the item of the source file
# that the change is in, and the test files.
dependency_hash() {
  hash_file="$1"
  hash_search="$2"
  shift 2
  {
    printf '%s\n' "$hash_file"
    item_text "$hash_file" "$hash_search" || true
    cat "$@"
  } | shasum -a 256 | cut -c1-16
}

# Prints the recorded row of a mutant on a version, or nothing.
recorded() {
  awk -F '\t' -v name="$1" -v version="$2" '$1 == name && $2 == version' "$results"
}

# Runs a command while holding the lock of the results file.
with_lock() {
  until mkdir "$work/lock" 2> /dev/null; do
    sleep 0.1
  done
  set +e
  "$@"
  status=$?
  set -e
  rmdir "$work/lock"
  return $status
}

# Replaces the recorded row of a mutant on a version.
write_row() {
  awk -F '\t' -v name="$1" -v version="$2" '!($1 == name && $2 == version)' "$results" > "$work/results.new"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$work/results.new"
  sort "$work/results.new" > "$results"
}

table="$work/table"
warnings="$work/warnings"
touch "$table" "$warnings"

# Adds a line to the table, the results file and the row counts.
record() {
  # name version hash result failed fuzz corpus seconds note
  printf '%-44s %-8s %-8s %-6s %-7s %-8s %s\n' "$1" "$2" "$5" "$6" "$7" "$8" "$(echo "$4" | tr 'a-z' 'A-Z')" >> "$table"
  with_lock write_row "$1" "$2" "$3" "$commit" "$4" "$5" "$9"
  echo "$4" > "$work/rows/$(printf '%s-%s' "$1" "$2" | shasum | cut -c1-12)"
}

# Defines one mutant: name, versions, file, text, replacement, and the
# test files that kill it. Mutants run after all are defined.
mutant_count=0
mutant() {
  if [ -n "$filter" ] && ! echo "$1" | grep -q -- "$filter"; then
    return
  fi
  mutant_count=$((mutant_count + 1))
  definition="$work/mutants/$(printf '%03d' "$mutant_count")"
  mkdir "$definition"
  printf '%s' "$1" > "$definition/name"
  printf '%s' "$2" > "$definition/versions"
  printf '%s' "$3" > "$definition/file"
  printf '%s' "$4" > "$definition/search"
  printf '%s' "$5" > "$definition/replacement"
  printf '%s' "$6" > "$definition/tests"
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

mutant "parameter: target or partition is not a table" "16" "$rules" \
  '"r" | "p" -> Ok(Nil)
    kind -> Error(reason.RelationNotTable(kind))' \
  '_ -> Ok(Nil)' \
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

# --- Model errors as data ------------------------------------------------------

mutant "model error: no row is NotFound" "16" "$model" \
  '[] -> Error(client.NotFound)' \
  '[] -> Ok(panic)' \
  "test/dream_model/generator/model_test.gleam"

mutant "model error: a hinted unique violation is Conflict" "16" "$model" \
  'Ok(constraint), _, _ -> client.Conflict(constraint)' \
  'Ok(constraint), _, _ -> client.QueryFailed(constraint, query_error)' \
  "test/dream_model/generator/model_test.gleam"

mutant "model error: QueryFailed keeps the cause" "16" "$model" \
  'client.QueryFailed(query_name <> \" failed\", query_error)' \
  'client.QueryFailed(query_name <> \" failed\", client.more_than_one_row(0))' \
  "test/dream_model/generator/model_test.gleam"

mutant "model error: unique hints reach the helper" "16" "$model" \
  '"[" <> string.join(list.map(found.unique, string_literal), ", ") <> "]"' \
  '"[]"' \
  "test/dream_model/e2e_test.gleam e2e/model_app/src/app/models/user.gleam e2e/model_app/src/app/models/sample.gleam"

mutant "model error hints: refuse the old not found hint" "16" "$query_hint" \
  '    "not found" ->' \
  '    "not found (off)" ->' \
  "test/dream_model/generator/query_hint_test.gleam"

mutant "model error hints: refuse the old unique hint" "16" "$query_hint" \
  '    "unique " <> constraint ->' \
  '    "unique (off) " <> constraint ->' \
  "test/dream_model/generator/query_hint_test.gleam"

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


# --- Numeric text and the not null elements hint ----------------------------

mutant "numeric: numeric_as_text left off" "16" "$model" \
  'True -> ["  |> client.numeric_as_text"]' \
  'True -> []' \
  "test/dream_model/generator/model_test.gleam test/dream_model/e2e_test.gleam"

mutant "numeric: Float decoder" "16" "$gleam_type" \
  'NumericType -> "client.numeric_text_decoder()"' \
  'NumericType -> "client.numeric_decoder()"' \
  "test/dream_model/generator/gleam_type_test.gleam"

mutant "numeric: Float value function" "16" "$gleam_type" \
  'NumericType -> "client.numeric_text"' \
  'NumericType -> "client.float"' \
  "test/dream_model/generator/gleam_type_test.gleam"

mutant "numeric: numeric[] parameter allowed" "16" "$generator_query" \
  'case gleam_type.has_numeric(element) {' \
  'case False {' \
  "test/dream_model/generator/query_test.gleam"

mutant "not null elements: hint ignored" "16" "$query_hint" \
  '"not null elements" -> Ok(add_element_names(hints, line))' \
  '"not null elements" -> Ok(hints)' \
  "test/dream_model/generator/query_hint_test.gleam test/dream_model/generator/query_test.gleam"

mutant "not null elements: no check of each element" "16" "$model" \
  '      "client.promised_elements_not_null("
      <> gleam_type.decoder_text(element, column_literal)
      <> ", "
      <> string_literal(file)
      <> ", "
      <> column_literal
      <> ")"' \
  '"decode.list(" <> gleam_type.decoder_text(element, column_literal) <> ")"' \
  "test/dream_model/generator/model_test.gleam test/dream_model/e2e_test.gleam"

mutant "not null elements: any column type" "16" "$generator_query" \
  'Ok(TypedColumn(gleam_type: gleam_type.ListType(_), ..)) -> Ok(Nil)' \
  'Ok(_) -> Ok(Nil)' \
  "test/dream_model/generator/query_test.gleam"

# --- Running ----------------------------------------------------------------

# Finds the versions of each mutant that must run, and records the mutants
# whose text is not in the source.
skipped=0
broken=0
job_versions=""
for definition in "$work"/mutants/*; do
  [ -d "$definition" ] || continue
  name=$(cat "$definition/name")
  file=$(cat "$definition/file")
  search=$(cat "$definition/search")
  # shellcheck disable=SC2046
  hash=$(dependency_hash "$file" "$search" $(cat "$definition/tests"))
  printf '%s' "$hash" > "$definition/hash"
  if ! item_text "$file" "$search" > /dev/null; then
    for version in $(cat "$definition/versions"); do
      record "$name" "$version" "$hash" "text not found" "-" "-" "-" "-" ""
      broken=$((broken + 1))
    done
    continue
  fi
  run_versions=""
  for version in $(cat "$definition/versions"); do
    row=$(recorded "$name" "$version")
    if [ "$run_all" = false ] && [ -n "$row" ] \
      && [ "$(echo "$row" | cut -f3)" = "$hash" ] \
      && [ "$(echo "$row" | cut -f5)" = "killed" ]; then
      skipped=$((skipped + 1))
    else
      run_versions="$run_versions $version"
      case " $job_versions " in
        *" $version "*) ;;
        *) job_versions="$job_versions $version" ;;
      esac
    fi
  done
  if [ -n "$run_versions" ]; then
    printf '%s' "$run_versions" > "$definition/run"
  fi
done

# Makes the copy of a worker.
make_copy() {
  copy="$1"
  mkdir -p "$copy/build/e2e/model_app"
  for item in gleam.toml manifest.toml src test scripts docs e2e; do
    cp -R "$root/$item" "$copy/$item"
  done
  for item in packages dev corpus; do
    cp -R "$root/build/$item" "$copy/build/$item"
  done
  cp -R "$root/build/e2e/model_app/build" "$copy/build/e2e/model_app/build"
}

# Runs `gleam test` in a copy and prints the counts of the run: "failed
# fuzz corpus modules...", or "none" when no group finished (the run
# failed). Arguments: copy, database prefix, versions, log, and the test
# modules ("" for every test).
run_tests() {
  set +e
  (
    cd "$1" \
      && env DREAM_MODEL_TEST_DATABASE_PREFIX="$2" DREAM_MODEL_TEST_VERSIONS="$3" \
        DREAM_MODEL_TEST_COVERAGE=off ${5:+"DREAM_MODEL_TEST_MODULES=$5"} \
        gleam test
  ) > "$4" 2>&1
  set -e
  finished=$(grep -E '^Finished: ' "$4" || true)
  if [ -z "$finished" ]; then
    echo "none"
    return
  fi
  failed=$(echo "$finished" | sed -E 's/.* ([0-9]+) failed, .*/\1/' | awk '{ total += $1 } END { print total }')
  modules=$(echo "$finished" | sed -E 's/.*failed modules: \[(.*)\]$/\1/' | tr ' ' '\n' | sort -u | tr '\n' ' ')
  fuzz=$(grep -c '✗ seed ' "$4" || true)
  corpus=$(grep -c '✗ finds no wrong never-NULL' "$4" || true)
  echo "$failed $fuzz $corpus $modules"
}

# Prints the test modules of a list of test files: the files in
# test/dream_model.
test_modules() {
  for test_file in "$@"; do
    case "$test_file" in
      test/dream_model/*.gleam) basename "$test_file" .gleam ;;
    esac
  done | tr '\n' ' '
}

# Marks a source file of a copy as changed: Gleam can reuse a stale
# compiled module when a file is put back with an older modification time,
# so this sets the time to now and removes the compiled cache of the module.
fresh_source() {
  touch "$1/$2"
  module=$(echo "${2#src/}" | sed -e 's/\.gleam$//' -e 's#/#@#g')
  rm -f "$1/build/dev/erlang/dream_model/_gleam_artefacts/dream_model@$module.cache" \
    "$1/build/dev/erlang/dream_model/_gleam_artefacts/dream_model@$module.cache_meta"
}

# Puts the original of a source file back into a copy.
restore_source() {
  cp "$work/original/$2" "$1/$2"
  fresh_source "$1" "$2"
}

# Runs one mutant in the copy of a worker.
run_mutant() {
  definition="$1"
  copy="$2"
  prefix="$3"
  name=$(cat "$definition/name")
  file=$(cat "$definition/file")
  hash=$(cat "$definition/hash")
  # shellcheck disable=SC2046
  modules=$(test_modules $(cat "$definition/tests"))
  log="$definition/test.log"
  restore_source "$copy" "$file"
  replace_text "$copy/$file" "$(cat "$definition/search")" "$(cat "$definition/replacement")"
  fresh_source "$copy" "$file"
  started=$(date +%s)
  echo "Mutant: $name on PostgreSQL$(cat "$definition/run")"
  # One build for every version of the mutant.
  if ! (cd "$copy" && gleam build) > "$definition/build.log" 2>&1; then
    for version in $(cat "$definition/run"); do
      record "$name" "$version" "$hash" "run failed" "-" "-" "-" "-" "the mutant does not compile"
    done
    tail -n 20 "$definition/build.log"
    restore_source "$copy" "$file"
    return
  fi
  for version in $(cat "$definition/run"); do
    note="own modules"
    counts=$(run_tests "$copy" "$prefix" "$version" "$log" "$modules")
    if [ "$counts" != "none" ] && [ "$(echo "$counts" | cut -d' ' -f1)" -eq 0 ] \
      && [ "$own_only" = false ] && ! grep -q 'No space left on device' "$log"; then
      note="all tests"
      counts=$(run_tests "$copy" "$prefix" "$version" "$log" "")
    fi
    seconds=$(($(date +%s) - started))
    if grep -q 'No space left on device' "$log"; then
      record "$name" "$version" "$hash" "error" "-" "-" "-" "$seconds" "no space left on device"
      started=$(date +%s)
      continue
    fi
    if [ "$counts" = "none" ]; then
      record "$name" "$version" "$hash" "run failed" "-" "-" "-" "$seconds" ""
      tail -n 30 "$log"
      continue
    fi
    # shellcheck disable=SC2086
    set -- $counts
    if [ "$1" -gt 0 ]; then
      result="killed"
      if [ "$note" = "all tests" ]; then
        shift 3
        echo "WARNING: \"$name\" on $version survived its own test modules ($modules) but these killed it: $*. Add them to the mutant." >> "$warnings"
        set -- $counts
      fi
    else
      result="survived"
      if [ "$note" = "own modules" ]; then
        note="own modules only"
      else
        note=""
      fi
    fi
    record "$name" "$version" "$hash" "$result" "$1" "$2" "$3" "$seconds" "$note"
    started=$(date +%s)
  done
  restore_source "$copy" "$file"
  drop_databases "$prefix"
}

# Checks that a worker sees each change of its copy: a known mutant must
# be killed, and the tests must pass again after the file is put back.
check_worker() {
  copy="$work/worker$1"
  prefix="${prefix_base}w$1_"
  check_search='case iterations > 0, iterations > maximum_iterations {'
  replace_text "$copy/$scram" "$check_search" 'case iterations > 0, False {'
  fresh_source "$copy" "$scram"
  mutated=$(run_tests "$copy" "$prefix" 16 "$work/check$1.log" scram_test)
  restore_source "$copy" "$scram"
  restored=$(run_tests "$copy" "$prefix" 16 "$work/check$1.log" scram_test)
  case "$mutated" in
    none | "0 "*)
      echo "Worker $1: the check mutant was not killed ($mutated)"
      return 1
      ;;
  esac
  case "$restored" in
    "0 "*) ;;
    *)
      echo "Worker $1: the tests fail after the check mutant was put back ($restored)"
      return 1
      ;;
  esac
}

# A worker: takes the next mutant that no other worker took, until none
# is left.
run_worker() {
  copy="$work/worker$1"
  prefix="${prefix_base}w$1_"
  if ! check_worker "$1"; then
    return 1
  fi
  for definition in "$work"/mutants/*; do
    [ -f "$definition/run" ] || continue
    mkdir "$work/claims/$(basename "$definition")" 2> /dev/null || continue
    run_mutant "$definition" "$copy" "$prefix"
  done
}

printf '%-44s %-8s %-8s %-6s %-7s %-8s %s\n' "rule" "version" "failing" "fuzz" "corpus" "seconds" "result" > "$table.head"
if [ -n "$job_versions" ]; then
  echo "Making the copies of $jobs workers"
  worker=1
  while [ "$worker" -le "$jobs" ]; do
    make_copy "$work/worker$worker"
    worker=$((worker + 1))
  done
  # The baseline: every test must pass without a mutant.
  echo "Baseline: every test must pass without a mutant (PostgreSQL$job_versions)"
  baseline_modules=""
  if [ "$own_only" = true ]; then
    for definition in "$work"/mutants/*; do
      if [ -f "$definition/run" ]; then
        # shellcheck disable=SC2046
        baseline_modules="$baseline_modules $(test_modules $(cat "$definition/tests"))"
      fi
    done
    baseline_modules=$(echo "$baseline_modules" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo "Baseline modules:$baseline_modules"
  fi
  baseline=$(run_tests "$work/worker1" "${prefix_base}w1_" "${job_versions# }" "$work/baseline.log" "$baseline_modules")
  drop_databases "${prefix_base}w1_"
  case "$baseline" in
    "0 0 0"*) ;;
    *)
      echo "The tests fail without a mutant ($baseline). Log:"
      tail -n 60 "$work/baseline.log"
      exit 1
      ;;
  esac
  worker=1
  while [ "$worker" -le "$jobs" ]; do
    run_worker "$worker" &
    worker_pids="$worker_pids $!"
    worker=$((worker + 1))
  done
  for pid in $worker_pids; do
    wait "$pid" || echo "A worker stopped with an error"
  done
  worker_pids=""
fi

ran=0
survivors=0
errors=0
for row in "$work"/rows/*; do
  [ -f "$row" ] || continue
  case "$(cat "$row")" in
    killed) ran=$((ran + 1)) ;;
    survived)
      ran=$((ran + 1))
      survivors=$((survivors + 1))
      ;;
    "text not found") ;;
    error)
      ran=$((ran + 1))
      errors=$((errors + 1))
      ;;
    *)
      ran=$((ran + 1))
      broken=$((broken + 1))
      ;;
  esac
done

for definition in "$work"/mutants/*; do
  if [ -f "$definition/run" ] && [ ! -d "$work/claims/$(basename "$definition")" ]; then
    echo "No worker ran the mutant \"$(cat "$definition/name")\""
    broken=$((broken + 1))
  fi
done

echo
cat "$table.head"
sort "$table"
echo
echo "failing: failed tests; fuzz: failed fuzz seeds; corpus: failed corpus runs"
echo "$ran mutant runs, $skipped skipped (a killed result with the same hash is in scripts/mutation-results.tsv)"
if [ -s "$warnings" ]; then
  echo
  cat "$warnings"
fi
if [ "$survivors" -gt 0 ] || [ "$broken" -gt 0 ] || [ "$errors" -gt 0 ]; then
  echo "$survivors mutants survived, $broken mutants did not apply, build or run, $errors runs had no disk space"
  exit 1
fi
echo "Every mutant was killed"
