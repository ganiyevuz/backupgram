#!/usr/bin/env bash
set -Eeo pipefail

# Usage: restore.sh <backup_file> [target_database]
# Examples:
#   restore.sh /backups/last/mydb-20260416-143000.sql.gz
#   restore.sh /backups/last/mydb-20260416-143000.sql.gz.gpg
#   restore.sh /backups/last/mydb-20260416-143000.sql.gz mydb_restored
#   restore.sh /backups/daily/mydb-latest.sql.gz

source "$(dirname "$0")/env.sh"

BACKUP_DIR="${BACKUP_DIR:-/backups}"

# Temp files and the passphrase file, removed on exit.
TEMP_FILES=""
KEYFILE=""
TG_TMPDIR=""
cleanup() {
  local tmp
  for tmp in ${TEMP_FILES}; do
    rm -rf "${tmp}"
  done
  if [ -n "${KEYFILE}" ]; then
    rm -f "${KEYFILE}"
  fi
  if [ -n "${TG_TMPDIR}" ]; then
    rm -rf "${TG_TMPDIR}"
  fi
  return 0
}
trap cleanup EXIT

# --- Restore directly from Telegram by message id ---
# Usage: restore --from-telegram <message_id> [--chat <chat_id>] [target_db]
if [ "$1" = "--from-telegram" ]; then
  TG_MESSAGE_ID="$2"

  if [ -z "${TG_MESSAGE_ID}" ]; then
    echo "❌ Usage: restore --from-telegram <message_id> [--chat <chat_id>] [target_db]" >&2
    exit 1
  fi

  shift 2
  TG_CHAT=""
  if [ "$1" = "--chat" ]; then
    TG_CHAT="$2"
    shift 2
  fi
  TARGET_DB="$1"
  if [ -z "${TELEGRAM_API_ID}" ] || [ -z "${TELEGRAM_API_HASH}" ] || [ -z "${TELEGRAM_BOT_TOKEN}" ]; then
    echo "❌ Restore from Telegram requires TELEGRAM_API_ID, TELEGRAM_API_HASH, and TELEGRAM_BOT_TOKEN." >&2
    exit 1
  fi
  if ! command -v tg-upload >/dev/null 2>&1; then
    echo "❌ tg-upload binary not found; cannot download from Telegram." >&2
    exit 1
  fi

  # Default to the first configured chat (message ids are per-chat).
  if [ -z "${TG_CHAT}" ]; then
    read -ra _rft_chats <<< "${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID}}"
    TG_CHAT="${_rft_chats[0]}"
  fi
  if [ -z "${TG_CHAT}" ]; then
    echo "❌ No chat id available; set TELEGRAM_CHAT_ID or pass --chat." >&2
    exit 1
  fi

  TG_TMPDIR=$(mktemp -d)
  echo "⬇️ Downloading backup from Telegram (message ${TG_MESSAGE_ID}, chat ${TG_CHAT})..."
  # Capture inside the `if` condition: under `set -e` a bare `VAR=$(failing-cmd)`
  # assignment would abort before our friendly check runs; `if` conditions are exempt.
  if ! DOWNLOADED=$(tg-upload download --chat "${TG_CHAT}" --message "${TG_MESSAGE_ID}" --out "${TG_TMPDIR}"); then
    echo "❌ Failed to download backup from Telegram." >&2
    exit 1
  fi
  if [ -z "${DOWNLOADED}" ] || [ ! -f "${DOWNLOADED}" ]; then
    echo "❌ Downloaded file not found." >&2
    exit 1
  fi
  echo "✅ Downloaded: $(basename "${DOWNLOADED}")"

  # Hand off to the normal restore flow by setting the positional args and
  # letting the existing logic below run against the downloaded file.
  set -- "${DOWNLOADED}" "${TARGET_DB}"
fi

BACKUP_FILE="$1"
TARGET_DB="$2"

# Interactive backup picker when no file specified
if [ -z "${BACKUP_FILE}" ]; then
  echo "────────────────────────────────────────"
  echo "  Available Backups"
  echo "────────────────────────────────────────"

  # Collect all backup files into a numbered list
  BACKUPS=()
  INDEX=0
  for SLOT in last daily weekly monthly; do
    SLOT_DIR="${BACKUP_DIR}/${SLOT}"
    [ ! -d "${SLOT_DIR}" ] && continue
    while IFS= read -r FILEPATH; do
      [ -z "${FILEPATH}" ] && continue
      INDEX=$((INDEX + 1))
      BACKUPS+=("${FILEPATH}")
      FILENAME=$(basename "${FILEPATH}")
      if [ -d "${FILEPATH}" ]; then
        SIZE=$(du -sh "${FILEPATH}" 2>/dev/null | cut -f1)
      else
        SIZE=$(du -h "${FILEPATH}" 2>/dev/null | cut -f1)
      fi
      MOD_DATE=$(date -r "${FILEPATH}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
      printf "  [%2d] %-6s  %s  %s/%s\n" "${INDEX}" "${SIZE}" "${MOD_DATE}" "${SLOT}" "${FILENAME}"
    done < <(find "${SLOT_DIR}" -maxdepth 1 -mindepth 1 ! -name '.*' \( -type f -o -type d \) 2>/dev/null | sort -r)
  done

  if [ "${INDEX}" -eq 0 ]; then
    echo "  No backups found in ${BACKUP_DIR}"
    exit 1
  fi

  echo "────────────────────────────────────────"
  echo ""
  read -r -p "Select backup number [1-${INDEX}]: " SELECTION

  # Validate selection
  if ! [[ "${SELECTION}" =~ ^[0-9]+$ ]] || [ "${SELECTION}" -lt 1 ] || [ "${SELECTION}" -gt "${INDEX}" ]; then
    echo "❌ Invalid selection." >&2
    exit 1
  fi

  BACKUP_FILE="${BACKUPS[$((SELECTION - 1))]}"
  echo ""
  echo "Selected: ${BACKUP_FILE}"
  echo ""

  # Ask for optional target DB override
  read -r -p "Target database (leave empty to auto-detect): " TARGET_DB_INPUT
  if [ -n "${TARGET_DB_INPUT}" ]; then
    TARGET_DB="${TARGET_DB_INPUT}"
  fi
fi

if [ ! -e "${BACKUP_FILE}" ]; then
  echo "❌ Backup file not found: ${BACKUP_FILE}" >&2
  exit 1
fi

# Extract database name from filename if target not specified
if [ -z "${TARGET_DB}" ]; then
  BASENAME=$(basename "${BACKUP_FILE}")
  # Strip the trailing suffixes (.gpg, .gz, .tar, .sql, .dump) and the date pattern
  TARGET_DB=$(echo "${BASENAME}" | sed -E 's/(\.(gpg|gz|tar|sql|dump))+$//; s/-(latest|[0-9]{8}(-[0-9]{6})?|[0-9]{6}|[0-9]{4}[0-9]{2})$//')
  if [ -z "${TARGET_DB}" ] || [ "${TARGET_DB}" = "cluster" ]; then
    echo "❌ Cannot determine target database from filename. Please specify it as the second argument." >&2
    exit 1
  fi
fi

echo "────────────────────────────────────────"
echo "Restore Details:"
echo "  Source: ${BACKUP_FILE}"
echo "  Target: ${TARGET_DB}@${PGHOST}:${PGPORT}"
echo "────────────────────────────────────────"

# Ask for confirmation — interactive (TTY) only. Non-interactive callers (the
# REST API, CI) have already confirmed and have no TTY to prompt on, so a blocking
# read would abort the restore under `set -e`.
if [ -t 0 ]; then
  echo ""
  echo "⚠️  This will restore data into database '${TARGET_DB}'."
  echo "    Existing data may be overwritten."
  echo ""
  read -r -p "Continue? [y/N] " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Restore cancelled."
    exit 0
  fi
fi

RESTORE_FILE="${BACKUP_FILE}"

# A decryption failure: the wrong key or a damaged file. Nothing was restored.
unreadable_backup() {
  echo "❌ Could not read the backup (wrong BACKUP_ENCRYPTION_KEY or a damaged file)." >&2
  exit 1
}

# Step 1: GPG-encrypted backups are decrypted with a passphrase file, never a
# command-line key. Custom-format and SQL dumps stream straight into the restore
# (no clear copy on disk); only a tar-archived directory dump needs a temp file.
STREAM_DECRYPT="FALSE"
if [[ "${RESTORE_FILE}" == *.gpg ]]; then
  if [ -z "${BACKUP_ENCRYPTION_KEY}" ]; then
    echo "❌ File is GPG-encrypted but BACKUP_ENCRYPTION_KEY is not set." >&2
    exit 1
  fi
  KEYFILE="$(mktemp)"
  printf '%s' "${BACKUP_ENCRYPTION_KEY}" > "${KEYFILE}"
  if [[ "${RESTORE_FILE%.gpg}" == *.tar.gz ]]; then
    echo "🔓 Decrypting backup..."
    DECRYPTED_FILE="/tmp/$(basename "${RESTORE_FILE%.gpg}")"
    # Registered before gpg runs, so a failed or partial decrypt leaves no clear text behind.
    TEMP_FILES="${TEMP_FILES} ${DECRYPTED_FILE}"
    if ! gpg --batch --yes --quiet --no-symkey-cache --decrypt --passphrase-file "${KEYFILE}" \
      -o "${DECRYPTED_FILE}" "${RESTORE_FILE}"; then
      unreadable_backup
    fi
    RESTORE_FILE="${DECRYPTED_FILE}"
  else
    echo "🔓 Decrypting backup into the restore stream..."
    STREAM_DECRYPT="TRUE"
  fi
fi

# The backup's bytes on stdout: decrypted on the fly when encrypted.
backup_stream() {
  if [ "${STREAM_DECRYPT}" = "TRUE" ]; then
    gpg --batch --quiet --no-symkey-cache --decrypt --passphrase-file "${KEYFILE}" "${RESTORE_FILE}"
  else
    cat "${RESTORE_FILE}"
  fi
}
# After a failed `backup_stream | …` pipeline, called as
#   stream_failure "$?" "${PIPESTATUS[0]}"
# (both expanded in the same command, before either is reset). A failing gpg, the
# first stage, means the backup could not be read: exit 1 with a clear message.
# Any other failure is returned for the caller to treat as fatal or as a warning.
stream_failure() {
  if [ "${STREAM_DECRYPT}" = "TRUE" ] && [ "$2" -ne 0 ]; then
    unreadable_backup
  fi
  return "$1"
}
# Without .gpg, the name tells the format.
RESTORE_NAME="${RESTORE_FILE%.gpg}"

# Step 2: Handle directory format (possibly tar.gz archived)
if [[ "${RESTORE_FILE}" == *.tar.gz ]] && [ -f "${RESTORE_FILE}" ]; then
  echo "📦 Extracting tar.gz archive..."
  EXTRACT_DIR="/tmp/restore_$(date +%s)"
  mkdir -p "${EXTRACT_DIR}"
  tar -xzf "${RESTORE_FILE}" -C "${EXTRACT_DIR}"
  RESTORE_FILE="${EXTRACT_DIR}/$(ls "${EXTRACT_DIR}" | head -1)"
  TEMP_FILES="${TEMP_FILES} ${EXTRACT_DIR}"
fi

# Ensure the target database exists for per-database restores — plain pg_dump
# output contains no CREATE DATABASE. Cluster dumps (pg_dumpall) restore into
# 'postgres' and create their own databases, so they are skipped here.
if ! echo "${BACKUP_FILE}" | grep -q "cluster"; then
  # Escape single quotes so the name is an inert SQL string literal (no injection),
  # and pass it to createdb after `--` so a name starting with '-' can't be a flag.
  TARGET_DB_SQL=${TARGET_DB//\'/\'\'}
  if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DB_SQL}'" | grep -q 1; then
    echo "📦 Target database '${TARGET_DB}' does not exist — creating it..."
    createdb -- "${TARGET_DB}"
  fi
fi

# Step 3: Restore based on format
echo "🔄 Restoring ${TARGET_DB}..."
RESTORE_START=$(date +%s)

if [ -d "${RESTORE_FILE}" ]; then
  # Directory format backup
  echo "📂 Detected directory format backup."
  if ! pg_restore -d "${TARGET_DB}" --clean --if-exists "${RESTORE_FILE}" 2>&1; then
    echo "⚠️ pg_restore completed with warnings (this is often normal for --clean on first restore)."
  fi
elif [[ "${RESTORE_NAME}" == *.sql.gz ]]; then
  # Compressed SQL dump — could be pg_dumpall (cluster) or pg_dump
  echo "📄 Detected compressed SQL dump."
  if echo "${BACKUP_FILE}" | grep -q "cluster"; then
    echo "🌐 Cluster dump detected. Restoring all databases..."
    backup_stream | gunzip -c | psql -d postgres \
      || stream_failure "$?" "${PIPESTATUS[0]}" || exit $?
  else
    backup_stream | gunzip -c | psql -d "${TARGET_DB}" \
      || stream_failure "$?" "${PIPESTATUS[0]}" || exit $?
  fi
elif [[ "${RESTORE_NAME}" == *.sql ]]; then
  # Plain SQL dump
  echo "📄 Detected plain SQL dump."
  backup_stream | psql -d "${TARGET_DB}" \
    || stream_failure "$?" "${PIPESTATUS[0]}" || exit $?
elif [ "${STREAM_DECRYPT}" = "TRUE" ]; then
  # Encrypted archive (custom format): decrypt straight into pg_restore
  echo "📦 Attempting pg_restore (archive format)..."
  backup_stream | pg_restore -d "${TARGET_DB}" --clean --if-exists 2>&1 \
    || stream_failure "$?" "${PIPESTATUS[0]}" \
    || echo "⚠️ pg_restore completed with warnings."
else
  # Try pg_restore (custom/archive format)
  echo "📦 Attempting pg_restore (archive format)..."
  if ! pg_restore -d "${TARGET_DB}" --clean --if-exists "${RESTORE_FILE}" 2>&1; then
    echo "⚠️ pg_restore completed with warnings."
  fi
fi

RESTORE_DURATION=$(( $(date +%s) - RESTORE_START ))

echo "────────────────────────────────────────"
echo "✅ Restore completed in ${RESTORE_DURATION}s: ${TARGET_DB}@${PGHOST}"
echo "────────────────────────────────────────"
