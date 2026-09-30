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

# A passphrase with spaces, quotes, $ and a backslash must round-trip.
# shellcheck disable=SC2016  # the single quotes are the point: nothing may expand
TRICKY_KEY='p@ss w0rd $HOME "q" '\''s'\'' \n end'

scenario_encrypted_custom() {
  fresh_backup_dir
  local file keyfile
  POSTGRES_EXTRA_OPTS="-Fc" BACKUP_SUFFIX=".dump" BACKUP_ENCRYPTION_KEY="${TRICKY_KEY}" run_backup
  expect_rc 0 "encrypted custom format"
  file="$(only_file "${BACKUP_DIR}/last" 'database-[0-9]*.dump.gpg')"
  [ -z "$(find "${BACKUP_DIR}" -name '*.dump' -print -quit)" ] || fail "a clear-text .dump exists"
  expect_no_out "${TRICKY_KEY}"
  keyfile="$(mktemp)"
  printf '%s' "${TRICKY_KEY}" > "${keyfile}"
  # `cat` drains what `pg_restore --list` leaves unread: a dump larger than the pipe buffer
  # would otherwise make gpg die of SIGPIPE, which pipefail turns into a failure.
  gpg --batch --quiet --no-symkey-cache --decrypt --passphrase-file "${keyfile}" "${file}" | { pg_restore --list >/dev/null && cat >/dev/null; } \
    || fail "the dump does not decrypt with the key into a readable archive"
  rm -f "${keyfile}"
}

scenario_min_bytes_keeps_previous() {
  fresh_backup_dir
  local first before
  run_backup
  expect_rc 0 "first run"
  first="$(only_file "${BACKUP_DIR}/last" 'database-[0-9]*.sql.gz')"
  before="$(inode "${first}")"
  sleep 1
  BACKUP_MIN_BYTES=999999999 run_backup
  expect_rc 1 "dump below BACKUP_MIN_BYTES"
  expect_out "below BACKUP_MIN_BYTES=999999999. Previous dump kept."
  expect_count "${BACKUP_DIR}/last" '.*.part' 0
  [ "$(inode "${first}")" = "${before}" ] || fail "the previous dump was replaced"
  expect_count "${BACKUP_DIR}/last" 'database-[0-9]*.sql.gz' 1
}

scenario_stale_part_removed() {
  fresh_backup_dir
  mkdir -p "${BACKUP_DIR}/last/.database-20200101-000000.dump.part"
  touch "${BACKUP_DIR}/last/.database-20200101-000000.sql.gz.part"
  run_backup
  expect_rc 0 "run after a killed one"
  expect_count "${BACKUP_DIR}/last" '.*.part' 0
}

# A pg_dump that "succeeds" with garbage must never replace a good dump.
scenario_verify_rejects_garbage() {
  fresh_backup_dir
  local fake
  fake="$(mktemp -d)"
  # Honours -f like the real pg_dump, so the garbage lands where the pipeline expects the dump.
  cat > "${fake}/pg_dump" <<'SH'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-f" ] && out="$2"
  shift
done
if [ -n "${out}" ]; then echo "this is not an archive" > "${out}"; else echo "this is not an archive"; fi
SH
  chmod +x "${fake}/pg_dump"
  PATH="${fake}:${PATH}" POSTGRES_EXTRA_OPTS="-Fc" BACKUP_SUFFIX=".dump" run_backup
  expect_rc 1 "custom format, garbage"
  expect_out "database: verification failed. Previous dump kept."
  PATH="${fake}:${PATH}" POSTGRES_EXTRA_OPTS="-Z1" run_backup
  expect_rc 1 "gzip plain, garbage"
  PATH="${fake}:${PATH}" POSTGRES_EXTRA_OPTS="-Fc" BACKUP_SUFFIX=".dump" BACKUP_ENCRYPTION_KEY="k" run_backup
  expect_rc 1 "encrypted custom format, garbage"
  expect_count "${BACKUP_DIR}/last" 'database-*' 0
  expect_count "${BACKUP_DIR}/last" '.*.part' 0
  rm -rf "${fake}"
}

# A run where every database fails must not prune: the old copies are the last good ones.
scenario_retention_skipped_when_nothing_succeeded() {
  fresh_backup_dir
  mkdir -p "${BACKUP_DIR}/daily"
  touch -d '30 days ago' "${BACKUP_DIR}/daily/database-20200101.sql.gz"
  POSTGRES_DB="no_such_db" run_backup
  expect_rc 1 "every database failed"
  expect_out "No database was backed up this run; retention skipped."
  [ -e "${BACKUP_DIR}/daily/database-20200101.sql.gz" ] || fail "retention pruned while nothing was backed up"
}

scenario_formats_still_work() {
  local opts
  for opts in "-Z0" "-Z1" "-Z0 -Fd" "-Fc" "-Ft"; do
    fresh_backup_dir
    POSTGRES_EXTRA_OPTS="${opts}" BACKUP_ENCRYPTION_KEY="k" run_backup
    expect_rc 0 "format '${opts}' (encrypted when not a directory)"
    expect_count "${BACKUP_DIR}/daily" 'database-[0-9]*' 1
  done
  fresh_backup_dir
  POSTGRES_CLUSTER="TRUE" POSTGRES_EXTRA_OPTS="" BACKUP_ENCRYPTION_KEY="k" run_backup
  expect_rc 0 "encrypted cluster dump"
  only_file "${BACKUP_DIR}/last" 'cluster-[0-9]*.sql.gz.gpg' >/dev/null
}

scenario_pharmakon_discovery() {
  load_pharmakon_fixture
  fresh_backup_dir
  local list db
  export POSTGRES_USER="svc_backup" POSTGRES_PASSWORD="${SVC_PASSWORD}" POSTGRES_DB=""
  export POSTGRES_DB_AUTODISCOVER="TRUE" POSTGRES_DB_INCLUDE="control,pharmacy_*"
  export POSTGRES_EXTRA_OPTS="-Fc --enable-row-security --lock-wait-timeout=60s --exclude-schema=br*_before_*"
  export BACKUP_SUFFIX=".dump"
  run_backup
  expect_rc 0 "Pharmakon discovery as svc_backup"
  expect_out "⏭️ pharmacy_broken skipped: no CONNECT privilege"
  expect_no_out "analytics"
  expect_out "Auto-discovered 3 database(s): control pharmacy_alpha pharmacy_beta"
  expect_out "3 succeeded, 0 failed, 1 skipped"
  for db in control pharmacy_alpha pharmacy_beta; do
    only_file "${BACKUP_DIR}/last" "${db}-[0-9]*.dump" >/dev/null
  done
  expect_count "${BACKUP_DIR}/last" 'pharmacy_broken-*' 0
  # Every branch schema is in the dump; the restore set-aside copy is not.
  list="$(mktemp)"
  pg_restore --list "$(only_file "${BACKUP_DIR}/last" 'pharmacy_alpha-[0-9]*.dump')" > "${list}"
  grep -q ' SCHEMA - br01 ' "${list}" || fail "br01 missing from pharmacy_alpha's dump"
  grep -q ' SCHEMA - br02 ' "${list}" || fail "br02 missing from pharmacy_alpha's dump"
  grep -q 'TABLE DATA public riayati_transaction ' "${list}" || fail "Riayati rows missing (row-level security)"
  if grep -q 'br01_before_' "${list}"; then fail "the set-aside copy was dumped"; fi
  pg_restore --list "$(only_file "${BACKUP_DIR}/last" 'pharmacy_beta-[0-9]*.dump')" > "${list}"
  grep -q ' SCHEMA - br100 ' "${list}" || fail "the three-digit branch br100 is missing"
  rm -f "${list}"
  # POSTGRES_DB_EXCLUDE still applies on top of the include globs.
  sleep 1
  POSTGRES_DB_EXCLUDE="pharmacy_beta" run_backup
  expect_rc 0 "include + exclude"
  expect_out "Auto-discovered 2 database(s): control pharmacy_alpha"
}

scenario_pharmakon_rls_guard() {
  load_pharmakon_fixture
  fresh_backup_dir
  pharmakon_env
  export BACKUP_LAYOUT="period"
  local beta
  run_backup
  expect_rc 0 "every RLS table has backup_reads_all"
  beta="$(only_file "${BACKUP_DIR}/last" 'pharmacy_beta-[0-9]*.dump.gpg')"
  # A table with row-level security and no full-read policy for svc_backup.
  psql_su -d pharmacy_beta -c "SET ROLE svc_control_api" \
    -c "CREATE TABLE public.riayati_gap (id text PRIMARY KEY, branch_no smallint NOT NULL)" \
    -c "ALTER TABLE public.riayati_gap ENABLE ROW LEVEL SECURITY"
  sleep 1
  BACKUP_RLS_GUARD="FALSE" run_backup
  expect_rc 0 "without the guard the short dump goes unnoticed"
  sleep 1
  run_backup
  expect_rc 1 "an RLS table without backup_reads_all"
  expect_out "❌ pharmacy_beta: row-level security without a full-read policy for svc_backup: public.riayati_gap. Previous dump kept."
  expect_out "Backup created: ${BACKUP_DIR}/last/pharmacy_alpha-"
  expect_count "${BACKUP_DIR}/last" 'pharmacy_beta-[0-9]*.dump.gpg' 2
  # Give it the policy; then a restrictive policy that reaches svc_backup through PUBLIC.
  psql_su -d pharmacy_beta -c "SET ROLE svc_control_api" \
    -c "CREATE POLICY backup_reads_all ON public.riayati_gap FOR SELECT TO svc_backup USING (true)"
  psql_su -d pharmacy_alpha -c "SET ROLE svc_control_api" \
    -c "CREATE POLICY cut ON public.riayati_transaction AS RESTRICTIVE FOR SELECT TO PUBLIC USING (branch_no > 0)"
  sleep 1
  run_backup
  expect_rc 1 "a restrictive policy reaching svc_backup"
  expect_out "❌ pharmacy_alpha: a restrictive policy limits svc_backup's reads: public.riayati_transaction. Previous dump kept."
  expect_no_out "❌ pharmacy_beta"
  [ -e "${beta}" ] || fail "pharmacy_beta's first dump disappeared"
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
