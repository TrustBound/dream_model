#!/bin/sh
# Fails when a model module is missing or differs from its .sql files, for
# CI. The end-to-end tests of dream_model run this script.
set -eu

gleam run -m dream_model -- --check
