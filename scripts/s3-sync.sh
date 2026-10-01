#!/usr/bin/env bash
set -Eeo pipefail

# The uploader mode's job (BACKUPGRAM_MODE=s3-sync), run by go-cron on S3_SCHEDULE: one
# off-site sync of BACKUP_DIR (a read-only mount is fine) and its metrics. Needs no
# database setting and no encryption key. Exits 1 when the sync failed.

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
BACKUP_DIR="${BACKUP_DIR:-/backups}"

# shellcheck source=scripts/s3-env.sh
source "${SCRIPT_DIR}/s3-env.sh"
# shellcheck source=scripts/lib/metrics.sh
source "${SCRIPT_DIR}/lib/metrics.sh"
# shellcheck source=scripts/lib/s3.sh
source "${SCRIPT_DIR}/lib/s3.sh"

if ! s3_enabled; then
  echo "❌ The off-site uploader needs S3_BUCKET and its credentials." >&2
  exit 1
fi

# One sync at a time in this container (go-cron may start the next one early).
exec 201>"${S3_STATUS_FILE}.lock"
if ! flock -n 201; then
  echo "⏳ Another off-site sync is running. Not started."
  exit 0
fi

RC=0
s3_sync || RC=1
write_offsite_metrics || echo "⚠️ Could not write the off-site metrics." >&2
exit "${RC}"
