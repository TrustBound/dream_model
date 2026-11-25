#!/bin/sh
# Fetches sqlc's PostgreSQL end-to-end test queries into build/corpus. The
# corpus test of `gleam test` reads them, and fails when they are missing.
#
# The fetch is shallow and sparse: one pinned commit, and only the
# directory of the end-to-end test data. The files are not part of this
# repository, and build/ is not committed.
#
# Usage: sh scripts/fetch-corpus.sh
set -eu

repository="https://github.com/sqlc-dev/sqlc.git"
# The commit that the proof of concept used (3ad8b20).
commit="3ad8b20fb02b5bea81591b673da0758b8685d951"
directory="internal/endtoend/testdata"
target="build/corpus"

if [ -f "$target/COMMIT" ] && [ "$(cat "$target/COMMIT")" = "$commit" ]; then
  echo "The sqlc corpus at $commit is already in $target"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

git -C "$work" init -q
git -C "$work" remote add origin "$repository"
git -C "$work" config core.sparseCheckout true
git -C "$work" sparse-checkout set --no-cone "/$directory/"
git -C "$work" fetch -q --depth 1 --filter=blob:none origin "$commit"
git -C "$work" checkout -q FETCH_HEAD

rm -rf "$target"
mkdir -p "$(dirname "$target")"
mv "$work/$directory" "$target"
echo "$commit" > "$target/COMMIT"
echo "Fetched the sqlc corpus at $commit into $target"
