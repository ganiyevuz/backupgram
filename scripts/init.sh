#!/usr/bin/env bash
set -Eeo pipefail

# Uploader mode: only the off-site sync, on S3_SCHEDULE. No database settings, no key:
# the backup folder may be mounted read-only.
if [ "${BACKUPGRAM_MODE}" = "s3-sync" ]; then
  if ! /scripts/s3-env.sh; then
    echo "Error: Validation failed, aborting." >&2
    exit 1
  fi
  echo "Starting the off-site uploader (schedule: ${S3_SCHEDULE:-*/15 * * * *}, health check port: ${HEALTHCHECK_PORT})."
  # go-cron never passes docker stop's TERM to its job; tini -g sends it to the whole
  # process group, so a running s3-sync stops cleanly (it aborts its upload and records a
  # failed sync). -s: a subreaper, for when tini is not PID 1 (compose init: true).
  exec tini -s -g -- /usr/local/bin/go-cron -s "${S3_SCHEDULE:-*/15 * * * *}" -p "${HEALTHCHECK_PORT}" -- /scripts/s3-sync.sh
fi

# Prevalidate configuration (don't source)
if [ "${VALIDATE_ON_START}" = "TRUE" ]; then
  echo "Running pre-validation script..."
  if ! /env.sh; then
    echo "Error: Validation failed, aborting." >&2
    exit 1
  fi
fi

# Initial background backup
EXTRA_ARGS=""
if [ "${BACKUP_ON_START}" = "TRUE" ]; then
  EXTRA_ARGS="-i"
fi

# When the REST API or the metrics endpoint is enabled, backupgram-api becomes PID 1
# and supervises go-cron itself (schedule + healthcheck unchanged). Otherwise, exec
# go-cron directly.
if [ "${REST_API_ENABLE}" = "TRUE" ] || [ "${METRICS_ENABLE}" = "TRUE" ]; then
  echo "Starting backupgram-api (port: ${REST_API_PORT}; REST API: ${REST_API_ENABLE:-FALSE}, metrics: ${METRICS_ENABLE:-FALSE}); it will supervise go-cron (schedule: $SCHEDULE)."
  if ! exec /usr/local/bin/backupgram-api; then
    echo "Error: backupgram-api failed to start." >&2
    exit 1
  fi
else
  echo "Starting cron job with schedule: $SCHEDULE and health check port: $HEALTHCHECK_PORT"
  if ! exec /usr/local/bin/go-cron -s "$SCHEDULE" -p "$HEALTHCHECK_PORT" $EXTRA_ARGS -- /backup.sh; then
    echo "Error: go-cron job failed to start." >&2
    exit 1
  fi
fi
