#!/bin/sh
# Gets the packages of the end-to-end app in e2e/model_app. CI runs this
# script before the tests and before the mutation test.
#
# The end-to-end tests copy the app to build/e2e/<version>/model_app and
# build it there, with the packages in build/e2e/model_app/build/packages. The app
# has dream_model as a dev dependency, and the tests always run the
# dream_model of this checkout, not a release on Hex. So this script:
#
# 1. copies gleam.toml and manifest.toml of the app to build/e2e/model_app;
# 2. copies src and gleam.toml of this checkout to the dream_model package
#    of the app, and lists it in packages.toml with the version of the
#    manifest, so that Gleam does not download dream_model;
# 3. runs `gleam deps download` in build/e2e/model_app. Gleam downloads
#    only the packages that packages.toml does not list with the version
#    of the manifest, so with a restored cache it makes no Hex request.
#
# Until dream_postgres 2.1.0 and Dream 3.0.0 are on Hex, use
# scripts/stand-ins.sh on a local machine instead (see CONTRIBUTING.md).
#
# Usage: sh scripts/e2e-packages.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/e2e/model_app"
packages="$app/build/packages"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/gleam.toml" | head -n 1)"

mkdir -p "$app" "$packages"
cp "$root/e2e/model_app/gleam.toml" "$root/e2e/model_app/manifest.toml" "$app/"

rm -rf "$packages/dream_model"
mkdir -p "$packages/dream_model"
cp -R "$root/src" "$root/gleam.toml" "$packages/dream_model/"

# List dream_model in packages.toml, in place of an earlier line for it.
file="$packages/packages.toml"
[ -f "$file" ] || printf '[packages]\n' > "$file"
awk -v version="$version" '
  $1 == "dream_model" && $2 == "=" { next }
  { print }
  $0 == "[packages]" { printf "dream_model = \"%s\"\n", version }
' "$file" > "$file.next"
mv "$file.next" "$file"

cd "$app"
gleam deps download
echo "The packages of the end-to-end app are in $packages"
