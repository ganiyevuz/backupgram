#!/usr/bin/env bash
# End-to-end scenarios for the backup scripts against a live PostgreSQL server.
# Usage: tests/scenarios.sh <scenario>... | all
# Environment: POSTGRES_HOST/PORT/USER/PASSWORD (a superuser), BACKUP_DIR, and the
# other variables the CI job sets. Each scenario runs in its own subshell.
set -Eeo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

scenario_baseline() {
  fresh_backup_dir
  run_backup
  expect_rc 0 "plain dump"
  only_file "${BACKUP_DIR}/last" 'database-[0-9]*.sql.gz' >/dev/null
}

scenario_pharmakon_fixture() {
  load_pharmakon_fixture
  local got
  got="$(psql_su -d postgres -tAc "SELECT pg_has_role('svc_backup', 'pg_read_all_data', 'USAGE'), rolbypassrls, rolconnlimit, rolsuper FROM pg_roles WHERE rolname = 'svc_backup'")"
  [ "${got}" = "t|f|5|f" ] || fail "svc_backup attributes: ${got}"
  got="$(psql_su -d postgres -tAc "SELECT string_agg(datname || '=' || has_database_privilege('svc_backup', datname, 'CONNECT'), ' ' ORDER BY datname) FROM pg_database WHERE datname IN ('control', 'pharmacy_alpha', 'pharmacy_beta', 'pharmacy_broken', 'analytics')")"
  [ "${got}" = "analytics=false control=true pharmacy_alpha=true pharmacy_beta=true pharmacy_broken=false" ] || fail "CONNECT: ${got}"
  got="$(psql_su -d pharmacy_alpha -tAc "SELECT string_agg(nspname, ' ' ORDER BY nspname) FROM pg_namespace WHERE nspname !~ '^(pg_|information_schema)'")"
  [ "${got}" = "br01 br01_before_20260930141503 br02 branch_template public reporting" ] || fail "alpha schemas: ${got}"
  got="$(psql_su -d pharmacy_alpha -tAc "SELECT count(*) FILTER (WHERE policyname = 'backup_reads_all'), count(*) FILTER (WHERE policyname = 'warehouse_reads_none' AND permissive = 'RESTRICTIVE') FROM pg_policies")"
  [ "${got}" = "2|2" ] || fail "alpha policies: ${got}"
  got="$(psql_su -d pharmacy_alpha -tAc "SELECT count(*) FROM pg_views WHERE schemaname = 'reporting' AND definition LIKE '%before%'")"
  [ "${got}" = "0" ] || fail "a reporting view still reads the set-aside copy"
  got="$(psql_su -d pharmacy_alpha -tAc "SELECT tableowner FROM pg_tables WHERE schemaname = 'br01' AND tablename = 'otdel'")"
  [ "${got}" = "svc_control_api" ] || fail "br01.otdel owner: ${got}"
  got="$(psql_su -d pharmacy_beta -tAc "SELECT count(*) FROM pg_namespace WHERE nspname ~ '^br[0-9]{2,3}\$'")"
  [ "${got}" = "3" ] || fail "beta branch schemas: ${got}"
}

scenario_lock_busy() {
  fresh_backup_dir
  mkdir -p "${BACKUP_DIR}/last"
  # The "running" run's in-flight file: a locked-out run must not touch it.
  touch "${BACKUP_DIR}/last/.database-20260101-000000.sql.gz.part"
  exec 9>>"${BACKUP_DIR}/.lock"
  flock -n 9 || fail "could not take the lock for the test"
  run_backup
  exec 9>&-
  expect_rc 75 "second run while the lock is held"
  expect_out "Another backup run holds ${BACKUP_DIR}/.lock. Not started."
  [ -e "${BACKUP_DIR}/last/.database-20260101-000000.sql.gz.part" ] || fail "the locked-out run deleted the running run's .part"
  expect_count "${BACKUP_DIR}/last" 'database-*' 0
}

scenario_failed_db_exits_1() {
  fresh_backup_dir
  POSTGRES_DB="database,no_such_db" run_backup
  expect_rc 1 "one of two databases missing"
  only_file "${BACKUP_DIR}/last" 'database-[0-9]*.sql.gz' >/dev/null
  expect_out "no_such_db"
}

scenario_period_layout_retention() {
  fresh_backup_dir
  mkdir -p "${BACKUP_DIR}/daily" "${BACKUP_DIR}/weekly"
  # A dropped database's old copies, its -latest link and a dot file: only the copies may go.
  touch -d '30 days ago' "${BACKUP_DIR}/daily/gone-20200101.sql.gz" "${BACKUP_DIR}/daily/.keep.sql.gz"
  ln -s gone-20200101.sql.gz "${BACKUP_DIR}/daily/gone-latest.sql.gz"
  touch -d '400 days ago' "${BACKUP_DIR}/weekly/gone-202001.sql.gz"
  BACKUP_LATEST_TYPE="hardlink" run_backup
  expect_rc 0 "period layout"
  local last day
  last="$(only_file "${BACKUP_DIR}/last" 'database-[0-9]*.sql.gz')"
  day="$(basename "${last}" | sed -E 's/^database-([0-9]{8})-.*/\1/')"
  [ "$(inode "${BACKUP_DIR}/daily/database-${day}.sql.gz")" = "$(inode "${last}")" ] || fail "daily copy is not a hard link of last/"
  [ "$(inode "${BACKUP_DIR}/weekly/database-$(date -d "${day}" +%G%V).sql.gz")" = "$(inode "${last}")" ] || fail "weekly copy"
  [ "$(inode "${BACKUP_DIR}/monthly/database-${day:0:6}.sql.gz")" = "$(inode "${last}")" ] || fail "monthly copy"
  [ "$(inode "${BACKUP_DIR}/last/database-latest.sql.gz")" = "$(inode "${last}")" ] || fail "hardlink -latest does not point at the new dump"
  [ ! -e "${BACKUP_DIR}/daily/gone-20200101.sql.gz" ] || fail "a dropped database's old daily copy was not pruned"
  [ ! -e "${BACKUP_DIR}/weekly/gone-202001.sql.gz" ] || fail "a dropped database's old weekly copy was not pruned"
  [ -e "${BACKUP_DIR}/daily/.keep.sql.gz" ] || fail "retention deleted a dot file"
  [ -L "${BACKUP_DIR}/daily/gone-latest.sql.gz" ] || fail "retention deleted a -latest link"
}

main() {
  local names=("$@") name
  if [ "${#names[@]}" -eq 0 ] || [ "${names[0]}" = "all" ]; then
    mapfile -t names < <(compgen -A function scenario_ | sed 's/^scenario_//')
  fi
  for name in "${names[@]}"; do
    declare -F "scenario_${name}" >/dev/null || fail "unknown scenario: ${name}"
    echo "════ ${name}"
    ( "scenario_${name}" )
    echo "✅ PASS: ${name}"
  done
}

main "$@"
