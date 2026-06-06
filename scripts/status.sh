#!/usr/bin/env bash
set -Eeo pipefail

# Show backup system status
# Usage: status

BACKUP_DIR="${BACKUP_DIR:-/backups}"
STATUS_FILE="/tmp/backup_status"

echo "════════════════════════════════════════"
echo "  Backup System Status"
echo "════════════════════════════════════════"
echo ""

# Configuration
echo "Configuration:"
echo "  Host:       ${POSTGRES_HOST:-not set}"
echo "  Port:       ${POSTGRES_PORT:-5432}"
if [ "${POSTGRES_DB_AUTODISCOVER}" = "TRUE" ]; then
  if [ -n "${POSTGRES_DB_EXCLUDE}" ]; then
    echo "  Databases:  auto-discover (excluding: ${POSTGRES_DB_EXCLUDE})"
  else
    echo "  Databases:  auto-discover"
  fi
else
  echo "  Databases:  ${POSTGRES_DB:-not set}"
fi
echo "  Schedule:   ${SCHEDULE:-@daily}"
echo "  Cluster:    ${POSTGRES_CLUSTER:-FALSE}"
echo "  Project:    ${PROJECT_NAME:-not set}"
if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
  echo "  Encryption: enabled (AES-256)"
else
  echo "  Encryption: disabled"
fi
if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
  if [ "${TELEGRAM_API_URL}" != "https://api.telegram.org" ]; then
    echo "  Telegram:   enabled (notify: ${TELEGRAM_NOTIFY_ON:-all}, custom API: ${TELEGRAM_API_URL})"
  else
    echo "  Telegram:   enabled (notify: ${TELEGRAM_NOTIFY_ON:-all})"
  fi
else
  echo "  Telegram:   disabled"
fi
echo ""

# Retention policy
echo "Retention Policy:"
echo "  Keep last:    ${BACKUP_KEEP_MINS:-1440} minutes"
echo "  Keep daily:   ${BACKUP_KEEP_DAYS:-7} days"
echo "  Keep weekly:  ${BACKUP_KEEP_WEEKS:-4} weeks"
echo "  Keep monthly: ${BACKUP_KEEP_MONTHS:-6} months"
echo ""

# Last backup result
echo "Last Backup:"
if [ -f "${STATUS_FILE}" ]; then
  LAST_STATUS=$(head -1 "${STATUS_FILE}" 2>/dev/null)
  LAST_TIMESTAMP=$(sed -n '2p' "${STATUS_FILE}" 2>/dev/null)
  if [ -n "${LAST_TIMESTAMP}" ]; then
    LAST_DATE=$(date -d "@${LAST_TIMESTAMP}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${LAST_TIMESTAMP}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    NOW=$(date +%s)
    AGE_MINS=$(( (NOW - LAST_TIMESTAMP) / 60 ))
    if [ "${AGE_MINS}" -lt 60 ]; then
      AGE_HUMAN="${AGE_MINS}m ago"
    elif [ "${AGE_MINS}" -lt 1440 ]; then
      AGE_HUMAN="$((AGE_MINS / 60))h ago"
    else
      AGE_HUMAN="$((AGE_MINS / 1440))d ago"
    fi
  fi
  if [ "${LAST_STATUS}" = "OK" ]; then
    echo "  Status:     ✅ OK"
  else
    echo "  Status:     ❌ FAILED"
  fi
  echo "  Time:       ${LAST_DATE:-unknown} (${AGE_HUMAN:-unknown})"
else
  echo "  Status:     No backup has run yet"
fi
echo ""

# Backup counts per slot
echo "Backup Inventory:"
for SLOT in last daily weekly monthly; do
  SLOT_DIR="${BACKUP_DIR}/${SLOT}"
  if [ -d "${SLOT_DIR}" ]; then
    COUNT=$(find "${SLOT_DIR}" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  else
    COUNT=0
  fi
  printf "  %-10s %s files\n" "${SLOT}:" "${COUNT}"
done
echo ""

# Disk usage
echo "Disk Usage:"
if [ -d "${BACKUP_DIR}" ]; then
  USED=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)
  AVAILABLE=$(df -h "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
  echo "  Backups:    ${USED:-unknown}"
  echo "  Available:  ${AVAILABLE:-unknown}"
  echo "  Min space:  ${BACKUP_MIN_DISK_SPACE:-100}MB"
else
  echo "  Backup directory not found: ${BACKUP_DIR}"
fi
echo ""

# Lock status
LOCK_FILE="/tmp/backup.lock"
if flock --nonblock 200 2>/dev/null; then
  echo "Backup Lock:  idle (not running)"
  exec 200>&-
else
  echo "Backup Lock:  🔒 backup in progress"
fi 200>"${LOCK_FILE}"

echo "════════════════════════════════════════"
