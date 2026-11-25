#!/bin/sh
# Writes src/app/models/*.gleam from the .sql files. The end-to-end tests of
# dream_model run this script. MODEL_APP_DATABASE_URL names the database.
set -eu

gleam run -m dream_model
