#!/bin/sh
# Puts local copies of the packages that are not on Hex yet into the build
# folders, so that the build and the tests run with no Hex request.
#
# dream_model needs dream_postgres 2.1.0, which needs dream_postgres_client
# 1.1.0, dream_postgres_driver 1.1.0 (the exact text of numeric) and
# dream_errors 1.0.0. The generated modules of the end-to-end app import
# dream_errors too. The
# end-to-end app in e2e/model_app also needs Dream 3.0.0 and dream_model
# 1.0.0. manifest.toml and e2e/model_app/manifest.toml already name these
# versions, with a checksum of zeros. Gleam does not
# download a package that build/packages/packages.toml lists with the
# version of the manifest, so this script copies each package and lists it.
#
# Remove this script when these packages are on Hex. Then run
# `gleam deps update dream_postgres dream_postgres_client
# dream_postgres_driver dream_errors` here and in e2e/model_app to write the
# real checksums into the manifests.
#
# The sources (each one can be changed with an environment variable):
#   DREAM_POSTGRES_SOURCE  a dream_postgres checkout at version 2.1.0,
#                          after `gleam build` there (its build/packages
#                          gives dream_postgres_client 1.1.0,
#                          dream_postgres_driver 1.1.0, dream_errors 1.0.0
#                          and the other
#                          packages of dream_postgres)
#   DREAM_SOURCE           a git clone of Dream
#   DREAM_COMMIT           the Dream commit of version 3.0.0
#   DREAM_PACKAGES         a build/packages folder with the Hex packages of
#                          Dream 3.0.0, for example from `gleam build` in a
#                          Dream checkout
#
# Usage: sh scripts/stand-ins.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dream_postgres_source="${DREAM_POSTGRES_SOURCE:-$root/../dream_postgres-model}"
dream_source="${DREAM_SOURCE:-$root/../dream-u770}"
dream_commit="${DREAM_COMMIT:-516c919}"
dream_packages="${DREAM_PACKAGES:-$dream_source/build/packages}"

dream_postgres_packages="dream_postgres_client dream_postgres_driver dream_errors backoff opentelemetry_api pg_types exception"
dream_dependency_packages="dream_http_server dream_socket_server gleam_http gleam_yielder marceau gramps gleam_crypto hpack_erl logging"

# copy_package <from folder> <to packages folder> <name>
# Also removes the compiled package of the build folder: Gleam does not
# compile a package again when only its source changed.
copy_package() {
  rm -rf "$2/$3"
  mkdir -p "$2"
  cp -R "$1" "$2/$3"
  rm -rf "$2/$3/build"
  for mode in dev prod lsp; do
    rm -rf "$(dirname "$2")/$mode/erlang/$3"
  done
}

# list_package <packages folder> <name> <version>
list_package() {
  file="$1/packages.toml"
  [ -f "$file" ] || printf '[packages]\n' > "$file"
  awk -v name="$2" -v version="$3" '
    $1 == name && $2 == "=" { next }
    { print }
    $0 == "[packages]" { printf "%s = \"%s\"\n", name, version }
  ' "$file" > "$file.next"
  mv "$file.next" "$file"
}

# version_of <package folder>
version_of() {
  sed -n 's/^version = "\(.*\)"/\1/p' "$1/gleam.toml" | head -n 1
}

# copy_dream_postgres <to packages folder>
copy_dream_postgres() {
  target="$1/dream_postgres"
  rm -rf "$target"
  mkdir -p "$target"
  cp -R "$dream_postgres_source/src" "$dream_postgres_source/gleam.toml" \
    "$dream_postgres_source/LICENSE.md" "$dream_postgres_source/README.md" \
    "$target/"
  list_package "$1" dream_postgres "$(version_of "$target")"
  for name in $dream_postgres_packages; do
    from="$dream_postgres_source/build/packages/$name"
    copy_package "$from" "$1" "$name"
    list_package "$1" "$name" "$(version_of_hex "$dream_postgres_source" "$name")"
  done
}

# version_of_hex <project folder> <name>: the version in the manifest
version_of_hex() {
  sed -n "s/.*{ name = \"$2\", version = \"\([^\"]*\)\".*/\1/p" "$1/manifest.toml" | head -n 1
}

# copy_dream <to packages folder>
copy_dream() {
  target="$1/dream"
  rm -rf "$target"
  mkdir -p "$target"
  git -C "$dream_source" archive "$dream_commit" src gleam.toml LICENSE.md README.md \
    | tar -x -C "$target"
  list_package "$1" dream "$(version_of "$target")"
  for name in $dream_dependency_packages; do
    copy_package "$dream_packages/$name" "$1" "$name"
    list_package "$1" "$name" "$(version_of_hex "$root/e2e/model_app" "$name")"
  done
}

# The build of dream_model.
copy_dream_postgres "$root/build/packages"
echo "Copied dream_postgres and its packages into build/packages"

# The end-to-end app. The tests copy it, with the build folder of
# build/e2e/model_app, to build/e2e/<version>/model_app and build it there,
# so its packages go into build/e2e/model_app/build.
e2e_packages="$root/build/e2e/model_app/build/packages"
for name in gleam_stdlib gleam_erlang gleam_otp gleam_json gleam_time simplifile filepath tom; do
  copy_package "$root/build/packages/$name" "$e2e_packages" "$name"
  list_package "$e2e_packages" "$name" "$(version_of_hex "$root/e2e/model_app" "$name")"
done
copy_dream_postgres "$e2e_packages"
copy_dream "$e2e_packages"
# dream_model itself: the end-to-end tests copy its src again before each
# run, so the app runs the code under test.
rm -rf "$e2e_packages/dream_model"
mkdir -p "$e2e_packages/dream_model"
cp -R "$root/src" "$root/gleam.toml" "$e2e_packages/dream_model/"
list_package "$e2e_packages" dream_model "$(version_of "$e2e_packages/dream_model")"
echo "Copied dream, dream_postgres, dream_model and their packages into build/e2e/model_app/build/packages"

# The tests copy build/e2e/model_app/build into a copy of the app for each
# version (build/e2e/<version>/model_app). Remove those copies, so that the
# next run copies the new packages.
find "$root/build/e2e" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -exec rm -rf {} +
