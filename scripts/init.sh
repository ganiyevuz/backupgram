#!/usr/bin/env bash
set -Eeo pipefail

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

# When the REST API is enabled, backupgram-api becomes PID 1 and supervises go-cron
# itself (schedule + healthcheck unchanged). Otherwise, exec go-cron directly.
if [ "${REST_API_ENABLE}" = "TRUE" ]; then
  echo "Starting REST API (port: ${REST_API_PORT}); it will supervise go-cron (schedule: $SCHEDULE)."
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
