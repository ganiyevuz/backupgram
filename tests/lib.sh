# shellcheck shell=bash
# Helpers for tests/scenarios.sh. Sourced, never executed.
# Environment: the CI job's POSTGRES_* / BACKUP_* variables, with a superuser login.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SH="${REPO_DIR}/scripts/backup.sh"
# shellcheck disable=SC2034  # used by tests/scenarios.sh
RESTORE_SH="${REPO_DIR}/scripts/restore.sh"

# The superuser, kept aside before a scenario switches POSTGRES_USER to a service login.
SU_USER="${SU_USER:-${POSTGRES_USER}}"
SU_PASSWORD="${SU_PASSWORD:-${POSTGRES_PASSWORD}}"
export SU_USER SU_PASSWORD
# Test-only password of every svc_* login the Pharmakon fixture creates.
SVC_PASSWORD="svc_pw"

# Scenarios test the backup pipeline, not Telegram: never send anything.
export TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID="" TELEGRAM_NOTIFY_ON="none"

fail() {
  echo "❌ FAIL: $*" >&2
  exit 1
}

fresh_backup_dir() {
  rm -rf "${BACKUP_DIR:?}"
  mkdir -p "${BACKUP_DIR}"
}

# Runs backup.sh with the current environment. Output goes to RUN_OUT (and is
# echoed, indented), the exit code to RUN_RC. Never aborts the caller.
run_backup() {
  set +e
  RUN_OUT="$(bash "${BACKUP_SH}" 2>&1)"
  RUN_RC=$?
  set -e
  printf '%s\n' "${RUN_OUT}" | sed 's/^/    │ /'
}

# Runs the uploader's job without any database setting or key, as the uploader container does.
# Output to RUN_OUT (echoed, indented), exit code to RUN_RC.
run_uploader() {
  set +e
  RUN_OUT="$(env -u POSTGRES_HOST -u POSTGRES_USER -u POSTGRES_PASSWORD -u POSTGRES_DB \
    -u BACKUP_ENCRYPTION_KEY BACKUPGRAM_MODE=s3-sync bash "${REPO_DIR}/scripts/s3-sync.sh" 2>&1)"
  RUN_RC=$?
  set -e
  printf '%s\n' "${RUN_OUT}" | sed 's/^/    │ /'
}

# Like run_backup, with the clock starting at $1 (it keeps running).
run_backup_at() {
  set +e
  RUN_OUT="$(faketime -f "@$1" bash "${BACKUP_SH}" 2>&1)"
  RUN_RC=$?
  set -e
  printf '%s\n' "${RUN_OUT}" | sed 's/^/    │ /'
}

expect_rc() {
  [ "${RUN_RC}" = "$1" ] || fail "$2: exit code ${RUN_RC}, expected $1"
}

expect_out() {
  grep -qF -- "$1" <<< "${RUN_OUT}" || fail "output lacks: $1"
}

expect_no_out() {
  if grep -qF -- "$1" <<< "${RUN_OUT}"; then
    fail "output unexpectedly contains: $1"
  fi
}

# expect_count DIR GLOB N — exactly N entries of DIR match GLOB (dot files included only if GLOB starts with a dot).
# A DIR that does not exist counts as 0 entries.
expect_count() {
  local n=0
  if [ -d "$1" ]; then
    n="$({ find "$1" -maxdepth 1 -mindepth 1 -name "$2" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  fi
  [ "${n}" = "$3" ] || fail "$1/$2: ${n} entries, expected $3"
}

# only_file DIR GLOB — prints the one entry of DIR matching GLOB, or fails.
only_file() {
  expect_count "$1" "$2" 1
  find "$1" -maxdepth 1 -mindepth 1 -name "$2"
}

psql_su() {
  PGPASSWORD="${SU_PASSWORD}" psql -X -q -v ON_ERROR_STOP=1 \
    -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${SU_USER}" "$@"
}

inode() {
  stat -c %i "$1"
}

load_pharmakon_fixture() {
  bash "${REPO_DIR}/tests/pharmakon/fixture.sh"
}

# The backup settings of spec §12, as the svc_backup login.
pharmakon_env() {
  export POSTGRES_USER="svc_backup" POSTGRES_PASSWORD="${SVC_PASSWORD}"
  export POSTGRES_DB="" POSTGRES_DB_AUTODISCOVER="TRUE" POSTGRES_DB_INCLUDE="control,pharmacy_*"
  export POSTGRES_EXTRA_OPTS="-Fc --enable-row-security --lock-wait-timeout=60s --exclude-schema=br*_before_*"
  export BACKUP_SUFFIX=".dump" BACKUP_LATEST_TYPE="none" BACKUP_LAYOUT="snapshot"
  export BACKUP_RLS_GUARD="TRUE" BACKUP_MIN_BYTES="1024" BACKUP_ENCRYPTION_KEY="pharmakon test key"
}

# The S3 test server (RustFS): the CI service on 127.0.0.1:9000, the harness's `s3` service.
TEST_S3_ENDPOINT="${TEST_S3_ENDPOINT:-http://127.0.0.1:9000}"
TEST_S3_ACCESS_KEY="testkey"
TEST_S3_SECRET_KEY="testsecret123"

# Exports the S3_* settings for a fresh, empty bucket on the test server (prefix "test").
# Retries for 30 s: the server may still be starting.
s3_env() {
  local bucket i
  bucket="t$(date +%s%N)"
  for i in $(seq 1 30); do
    if curl -sf -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
      --user "${TEST_S3_ACCESS_KEY}:${TEST_S3_SECRET_KEY}" "${TEST_S3_ENDPOINT}/${bucket}" >/dev/null; then
      break
    fi
    [ "${i}" != "30" ] || fail "could not create bucket ${bucket} on ${TEST_S3_ENDPOINT}"
    sleep 1
  done
  export S3_BUCKET="${bucket}" S3_ENDPOINT="${TEST_S3_ENDPOINT}" S3_REGION="us-east-1" \
    S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
    S3_FORCE_PATH_STYLE="TRUE" S3_PREFIX="test"
}

# The bucket's keys, one per line, sorted (empty when there are none).
s3_keys() {
  s3-sync ls | cut -f1 | sort
}
