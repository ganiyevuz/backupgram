#!/usr/bin/env bash
# Runs tests/scenarios.sh in Docker against PostgreSQL 18 (PG_MAJOR=16 for CI's version).
# Usage: tests/run-local.sh [scenario ...]    (default: all)
#        KEEP=1 tests/run-local.sh …          (leave the containers running afterwards)
set -Eeo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker-compose.yml)
if [ "${KEEP:-0}" != "1" ]; then
  trap '"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true' EXIT
fi
"${COMPOSE[@]}" up -d --build --wait db runner
"${COMPOSE[@]}" exec -T runner bash tests/scenarios.sh "${@:-all}"
