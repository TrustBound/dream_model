#!/bin/sh
# Starts the PostgreSQL servers of docker-compose.yml and waits until each
# accepts connections. "make db-up" runs this script, and CI runs it before
# the tests. With version numbers as arguments, it starts only those
# servers, for example: sh scripts/db-up.sh 16 15
set -eu

versions="${*:-15 16 17 18 19}"
for version in $versions; do
  docker compose up -d --wait "postgres-$version"
  echo "PostgreSQL $version accepts connections at postgresql://dream:dream@localhost:54$version/dream_test"
done
