#!/usr/bin/env bash
# Healthcheck that verifies both go-cron and backup status
# Exit 0 = healthy, Exit 1 = unhealthy

STATUS_FILE="/tmp/backup_status"
HEALTHCHECK_PORT="${HEALTHCHECK_PORT:-8080}"
# Honor runtime overrides (e.g. BACKUP_MAX_AGE_HOURS) written by the REST API.
_API_OVERRIDES="${BACKUP_DIR:-/backups}/.api-overrides.env"
# shellcheck disable=SC1090
[ -f "${_API_OVERRIDES}" ] && . "${_API_OVERRIDES}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-48}"

# Check 1: go-cron is alive, and its last run did not fail. go-cron answers 200 when
# the last run exited 0 (or none ran yet), and 503 otherwise, with the exit status
# in its JSON body: {"Running": {…}, "Last": {"Exit_status": 75, …}, …}.
# 75 is a run locked out by another one (a manual or REST run): not a failure.
if ! RESPONSE="$(curl -s -w '\n%{http_code}' "http://localhost:${HEALTHCHECK_PORT}/" 2>/dev/null)"; then
  echo "UNHEALTHY: go-cron is not responding"
  exit 1
fi
HTTP_CODE="${RESPONSE##*$'\n'}"
case "${HTTP_CODE}" in
  200) ;;
  503)
    # "Last" follows "Running", whose entries carry an Exit_status of their own; the
    # body is indented JSON, so it is flattened first (BusyBox tr/sed).
    LAST_EXIT="$(printf '%s' "${RESPONSE%$'\n'*}" | tr -d ' \t\r\n' \
      | sed -n 's/.*"Last":{"Exit_status":\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')"
    if [ -z "${LAST_EXIT}" ]; then
      echo "UNHEALTHY: go-cron reports a failed run (exit status unreadable)"
      exit 1
    fi
    if [ "${LAST_EXIT}" != "75" ]; then
      echo "UNHEALTHY: last backup run exited ${LAST_EXIT}"
      exit 1
    fi
    ;;
  *)
    echo "UNHEALTHY: go-cron answered HTTP ${HTTP_CODE}"
    exit 1
    ;;
esac

# Check 2: backup status file exists (skip if no backup has run yet)
if [ ! -f "${STATUS_FILE}" ]; then
  # No backup has run yet — healthy (cron hasn't fired)
  exit 0
fi

# Check 3: last backup succeeded
LAST_STATUS=$(head -1 "${STATUS_FILE}" 2>/dev/null)
if [ "${LAST_STATUS}" != "OK" ]; then
  echo "UNHEALTHY: last backup failed (status: ${LAST_STATUS})"
  exit 1
fi

# Check 4: backup isn't stale
LAST_TIMESTAMP=$(sed -n '2p' "${STATUS_FILE}" 2>/dev/null)
if [ -n "${LAST_TIMESTAMP}" ]; then
  NOW=$(date +%s)
  AGE_HOURS=$(( (NOW - LAST_TIMESTAMP) / 3600 ))
  if [ "${AGE_HOURS}" -ge "${BACKUP_MAX_AGE_HOURS}" ]; then
    echo "UNHEALTHY: last successful backup was ${AGE_HOURS}h ago (max: ${BACKUP_MAX_AGE_HOURS}h)"
    exit 1
  fi
fi

exit 0
