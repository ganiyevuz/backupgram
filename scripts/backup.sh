#!/usr/bin/env bash
set -Eeo pipefail

# Prevent overlapping backup runs
LOCK_FILE="/tmp/backup.lock"
exec 200>"${LOCK_FILE}"
if ! flock --nonblock 200; then
  echo "⚠️ Another backup is already running. Skipping this run." >&2
  exit 0
fi

# Define the error handling function
HOOKS_DIR="/hooks"
if [ -d "${HOOKS_DIR}" ]; then
  on_error(){
    run-parts -a "error" "${HOOKS_DIR}"
  }
  trap 'on_error' ERR
fi

source "$(dirname "$0")/env.sh"

# Pre-backup hook
if [ -d "${HOOKS_DIR}" ]; then
  run-parts -a "pre-backup" --exit-on-error "${HOOKS_DIR}"
fi

# Check database connectivity before starting
POSTGRES_CONNECT_TIMEOUT="${POSTGRES_CONNECT_TIMEOUT:-30}"
echo "Checking database connectivity (timeout: ${POSTGRES_CONNECT_TIMEOUT}s)..."
if ! pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -t "${POSTGRES_CONNECT_TIMEOUT}" -q 2>/dev/null; then
  echo "❌ Database is not reachable at ${PGHOST}:${PGPORT}. Aborting backup." >&2
  exit 1
fi
echo "✅ Database is reachable."

# Check available disk space (default minimum: 100MB)
BACKUP_MIN_DISK_SPACE="${BACKUP_MIN_DISK_SPACE:-100}"
AVAILABLE_MB=$(df -m "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${AVAILABLE_MB}" ] && [ "${AVAILABLE_MB}" -lt "${BACKUP_MIN_DISK_SPACE}" ]; then
  echo "❌ Low disk space: ${AVAILABLE_MB}MB available, ${BACKUP_MIN_DISK_SPACE}MB required. Aborting." >&2
  exit 1
fi
echo "✅ Disk space OK (${AVAILABLE_MB}MB available)."

# Build exclude-table args if POSTGRES_EXCLUDE_TABLES is set
EXCLUDE_ARGS=""
if [ -n "${POSTGRES_EXCLUDE_TABLES}" ]; then
  for TABLE in ${POSTGRES_EXCLUDE_TABLES//,/ }; do
    EXCLUDE_ARGS="${EXCLUDE_ARGS} --exclude-table=${TABLE}"
  done
  echo "Excluding tables: ${POSTGRES_EXCLUDE_TABLES}"
fi

# Telegram notification control (default: all)
TELEGRAM_NOTIFY_ON="${TELEGRAM_NOTIFY_ON:-all}"

# Initialize directories
mkdir -p "${BACKUP_DIR}/last/" "${BACKUP_DIR}/daily/" "${BACKUP_DIR}/weekly/" "${BACKUP_DIR}/monthly/"

# Telegram file size limit (50MB in bytes) and the bot MTProto ceiling (2GB)
TELEGRAM_MAX_SIZE=52428800
TELEGRAM_MTPROTO_MAX_SIZE=2147483648

# Get human-readable size of a file or directory
get_size() {
  if [ -d "$1" ]; then
    du -sh "$1" 2>/dev/null | cut -f1
  elif [ -f "$1" ]; then
    du -h "$1" 2>/dev/null | cut -f1
  else
    echo "0"
  fi
}

# Get raw byte size (POSIX-compatible, works on Alpine/BusyBox)
get_size_bytes() {
  if [ -d "$1" ]; then
    local kb
    kb=$(du -s "$1" 2>/dev/null | cut -f1)
    echo $((kb * 1024))
  elif [ -f "$1" ]; then
    wc -c < "$1" 2>/dev/null
  else
    echo "0"
  fi
}

# Encrypt a file with GPG if encryption is enabled
encrypt_file() {
  local file="$1"
  if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
    echo "🔒 Encrypting ${file}..." >&2
    gpg --symmetric --batch --yes --passphrase "${BACKUP_ENCRYPTION_KEY}" \
      --cipher-algo AES256 -o "${file}.gpg" "${file}"
    rm -f "${file}"
    echo "${file}.gpg"
  else
    echo "${file}"
  fi
}

# Verify backup integrity using pg_restore
verify_backup() {
  local file="$1"
  local db="$2"

  # Skip verification for cluster dumps (pg_dumpall produces SQL, not archive format)
  if [ "${POSTGRES_CLUSTER}" = "TRUE" ]; then
    return 0
  fi

  # Skip for directory format (pg_restore --list works differently)
  if [ -d "${file}" ]; then
    if pg_restore --list "${file}" > /dev/null 2>&1; then
      echo "✅ Backup verification passed for ${db}."
      return 0
    else
      echo "⚠️ Backup verification failed for ${db}. File may be corrupted." >&2
      return 1
    fi
  fi

  # For gzip files, verify the archive is valid
  # Check magic bytes (1f 8b) to confirm it's actually gzip, not just a .gz extension
  if [[ "${file}" == *.gz ]]; then
    local magic
    magic=$(head -c 2 "${file}" 2>/dev/null | od -A n -t x1 | tr -d ' ')
    if [ "${magic}" = "1f8b" ]; then
      if gzip -t "${file}" 2>/dev/null; then
        echo "✅ Backup integrity check passed for ${db} (valid gzip)."
      else
        echo "⚠️ Backup integrity check failed for ${db}. Gzip file is corrupted." >&2
        return 1
      fi
    else
      echo "✅ Backup created for ${db} (uncompressed, -Z0 mode)."
    fi
    return 0
  fi

  return 0
}

# Send a file to Telegram with size validation
send_to_telegram() {
  local file="$1"
  local db="$2"
  local send_file="${file}"

  # For directory backups, create a tar.gz archive for upload
  if [ -d "${file}" ]; then
    send_file="${file}.tar.gz"
    echo "📦 Archiving directory backup for Telegram upload..."
    tar -czf "${send_file}" -C "$(dirname "${file}")" "$(basename "${file}")"
  fi

  # Check file size
  local file_size
  file_size=$(get_size_bytes "${send_file}")

  # Build caption with optional project name (used by both the curl and MTProto paths)
  local caption="📂 PostgreSQL Backup"
  if [ -n "${PROJECT_NAME}" ]; then
    caption="${caption} [${PROJECT_NAME}]"
  fi
  caption="${caption}: ${db} ($(date +'%Y-%m-%d %H:%M:%S')) [$(get_size "${send_file}")]"

  # Large-file handling: the official Bot API caps uploads at 50MB.
  if [ "${TELEGRAM_API_URL}" = "https://api.telegram.org" ] && [ "${file_size}" -gt "${TELEGRAM_MAX_SIZE}" ]; then
    # Above the bot MTProto ceiling there is nothing we can do — keep it locally.
    if [ "${file_size}" -gt "${TELEGRAM_MTPROTO_MAX_SIZE}" ]; then
      echo "⚠️ Backup $(get_size "${send_file}") exceeds the 2GB MTProto limit. Kept locally." >&2
      if [ -d "${file}" ]; then rm -f "${send_file}"; fi
      return 1
    fi
    # Prefer the vendored MTProto uploader when credentials are configured.
    if [ -n "${TELEGRAM_API_ID}" ] && [ -n "${TELEGRAM_API_HASH}" ] && command -v tg-upload >/dev/null 2>&1; then
      echo "⬆️ Backup exceeds 50MB — uploading via MTProto (up to 2GB)..."
      local tg_args=(--file "${send_file}" --chat "${TELEGRAM_CHAT_ID}" --caption "${caption}")
      if [ -n "${TELEGRAM_THREAD_ID}" ]; then
        tg_args+=(--thread "${TELEGRAM_THREAD_ID}")
      fi
      if tg-upload "${tg_args[@]}"; then
        echo "✅ Backup sent to Telegram (MTProto)."
      else
        echo "⚠️ MTProto upload failed. Backup is still saved locally." >&2
      fi
      if [ -d "${file}" ]; then rm -f "${send_file}"; fi
      return 0
    fi
    # No MTProto creds and not on a self-hosted server — cannot send.
    echo "⚠️ Backup $(get_size "${send_file}") exceeds Telegram 50MB limit." >&2
    echo "💡 Hint: set TELEGRAM_API_ID + TELEGRAM_API_HASH to send via MTProto (up to 2GB), or set TELEGRAM_API_URL to a self-hosted Bot API server." >&2
    if [ -d "${file}" ]; then rm -f "${send_file}"; fi
    return 1
  fi

  # Build curl args with optional thread support
  local curl_args=()
  curl_args+=(-F "chat_id=${TELEGRAM_CHAT_ID}")
  curl_args+=(-F "document=@${send_file}")
  curl_args+=(-F "caption=${caption}")
  if [ -n "${TELEGRAM_THREAD_ID}" ]; then
    curl_args+=(-F "message_thread_id=${TELEGRAM_THREAD_ID}")
  fi

  local response
  response=$(curl -s -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
    "${curl_args[@]}")

  if echo "${response}" | grep -q '"ok":true'; then
    echo "✅ Backup sent to Telegram."
  else
    local error_desc
    error_desc=$(echo "${response}" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    echo "⚠️ Failed to send backup to Telegram: ${error_desc:-unknown error}. Backup is still saved locally." >&2
  fi

  # Clean up temporary tar archive
  if [ -d "${file}" ]; then
    rm -f "${send_file}"
  fi
}

# Send a text message to Telegram
send_telegram_message() {
  local message="$1"
  if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
    local curl_args=()
    curl_args+=(-d "chat_id=${TELEGRAM_CHAT_ID}")
    curl_args+=(-d "text=${message}")
    curl_args+=(-d "parse_mode=Markdown")
    if [ -n "${TELEGRAM_THREAD_ID}" ]; then
      curl_args+=(-d "message_thread_id=${TELEGRAM_THREAD_ID}")
    fi
    curl -s --fail -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      "${curl_args[@]}" > /dev/null 2>&1 || true
  fi
}

# Track backup results
BACKUP_SUCCESS=0
BACKUP_FAILED=0
FAILED_DBS=""
BACKUP_START_TIME=$(date +%s)

# Handle cluster mode: pg_dumpall dumps ALL databases at once
if [ "${POSTGRES_CLUSTER}" = "TRUE" ]; then
  DB="cluster"
  LAST_FILENAME="${DB}-$(date +%Y%m%d-%H%M%S)${BACKUP_SUFFIX}"
  DAILY_FILENAME="${DB}-$(date +%Y%m%d)${BACKUP_SUFFIX}"
  WEEKLY_FILENAME="${DB}-$(date +%G%V)${BACKUP_SUFFIX}"
  MONTHLY_FILENAME="${DB}-$(date +%Y%m)${BACKUP_SUFFIX}"
  FILE="${BACKUP_DIR}/last/${LAST_FILENAME}"
  DFILE="${BACKUP_DIR}/daily/${DAILY_FILENAME}"
  WFILE="${BACKUP_DIR}/weekly/${WEEKLY_FILENAME}"
  MFILE="${BACKUP_DIR}/monthly/${MONTHLY_FILENAME}"

  echo "Creating cluster dump from ${POSTGRES_HOST}..."
  # shellcheck disable=SC2086
  if pg_dumpall ${POSTGRES_EXTRA_OPTS} | gzip > "${FILE}"; then
    POSTGRES_DBS="cluster"
  else
    echo "❌ Error: pg_dumpall failed. Aborting." >&2
    BACKUP_FAILED=1
    FAILED_DBS="cluster"
    POSTGRES_DBS=""
  fi
fi

# Loop through all databases (or single "cluster" entry)
for DB in ${POSTGRES_DBS}; do
  DB_START_TIME=$(date +%s)

  if [ "${POSTGRES_CLUSTER}" != "TRUE" ]; then
    LAST_FILENAME="${DB}-$(date +%Y%m%d-%H%M%S)${BACKUP_SUFFIX}"
    DAILY_FILENAME="${DB}-$(date +%Y%m%d)${BACKUP_SUFFIX}"
    WEEKLY_FILENAME="${DB}-$(date +%G%V)${BACKUP_SUFFIX}"
    MONTHLY_FILENAME="${DB}-$(date +%Y%m)${BACKUP_SUFFIX}"
    FILE="${BACKUP_DIR}/last/${LAST_FILENAME}"
    DFILE="${BACKUP_DIR}/daily/${DAILY_FILENAME}"
    WFILE="${BACKUP_DIR}/weekly/${WEEKLY_FILENAME}"
    MFILE="${BACKUP_DIR}/monthly/${MONTHLY_FILENAME}"

    echo "Creating dump of ${DB} database from ${POSTGRES_HOST}..."

    if [[ "${POSTGRES_EXTRA_OPTS}" == *"-Fd"* ]]; then
      echo "📂 Directory format (-Fd) detected. Removing compression option..."
      PG_DUMP_OPTS=$(echo "${POSTGRES_EXTRA_OPTS}" | sed 's/-Z[0-9]*//g' | xargs)
      # shellcheck disable=SC2086
      if ! pg_dump -d "${DB}" -f "${FILE}" ${PG_DUMP_OPTS} ${EXCLUDE_ARGS}; then
        echo "❌ Error: pg_dump failed for ${DB}. Skipping." >&2
        BACKUP_FAILED=$((BACKUP_FAILED + 1))
        FAILED_DBS="${FAILED_DBS} ${DB}"
        continue
      fi
    else
      # shellcheck disable=SC2086
      if ! pg_dump -d "${DB}" -f "${FILE}" ${POSTGRES_EXTRA_OPTS} ${EXCLUDE_ARGS}; then
        echo "❌ Error: pg_dump failed for ${DB}. Skipping." >&2
        BACKUP_FAILED=$((BACKUP_FAILED + 1))
        FAILED_DBS="${FAILED_DBS} ${DB}"
        continue
      fi
    fi
  fi

  # Check if the backup file or directory exists and is not empty
  if [ -s "${FILE}" ] || [ -d "${FILE}" ]; then
    # Verify backup integrity
    if ! verify_backup "${FILE}" "${DB}"; then
      BACKUP_FAILED=$((BACKUP_FAILED + 1))
      FAILED_DBS="${FAILED_DBS} ${DB}"
      continue
    fi

    # Encrypt backup if enabled
    if [ -n "${BACKUP_ENCRYPTION_KEY}" ] && [ ! -d "${FILE}" ]; then
      FILE=$(encrypt_file "${FILE}")
      LAST_FILENAME="$(basename "${FILE}")"
      # Update rotation filenames with .gpg suffix
      DAILY_FILENAME="${DAILY_FILENAME}.gpg"
      WEEKLY_FILENAME="${WEEKLY_FILENAME}.gpg"
      MONTHLY_FILENAME="${MONTHLY_FILENAME}.gpg"
      DFILE="${BACKUP_DIR}/daily/${DAILY_FILENAME}"
      WFILE="${BACKUP_DIR}/weekly/${WEEKLY_FILENAME}"
      MFILE="${BACKUP_DIR}/monthly/${MONTHLY_FILENAME}"
    fi

    DB_DURATION=$(( $(date +%s) - DB_START_TIME ))
    BACKUP_SIZE=$(get_size "${FILE}")
    echo "✅ Backup created: ${FILE} (${BACKUP_SIZE}, ${DB_DURATION}s)"
    BACKUP_SUCCESS=$((BACKUP_SUCCESS + 1))

    # Rotate into daily/weekly/monthly slots
    if [ -d "${FILE}" ]; then
      cp -r "${FILE}" "${DFILE}"
      cp -r "${FILE}" "${WFILE}"
      cp -r "${FILE}" "${MFILE}"
    else
      ln -f "${FILE}" "${DFILE}"
      ln -f "${FILE}" "${WFILE}"
      ln -f "${FILE}" "${MFILE}"
    fi

    # Update latest symlinks
    if [ "${BACKUP_LATEST_TYPE}" = "symlink" ] || [ "${BACKUP_LATEST_TYPE}" = "hardlink" ]; then
      LATEST_LN_ARG=""
      LATEST_SUFFIX="${BACKUP_SUFFIX}"
      if [ -n "${BACKUP_ENCRYPTION_KEY}" ] && [ ! -d "${FILE}" ]; then
        LATEST_SUFFIX="${BACKUP_SUFFIX}.gpg"
      fi
      if [ "${BACKUP_LATEST_TYPE}" = "symlink" ]; then
        LATEST_LN_ARG="-s"
      fi
      if [ -d "${FILE}" ]; then
        for DIR_TYPE in last daily weekly monthly; do
          rm -rf "${BACKUP_DIR}/${DIR_TYPE}/${DB}-latest${BACKUP_SUFFIX}"
        done
        cp -r "${FILE}" "${BACKUP_DIR}/last/${DB}-latest${BACKUP_SUFFIX}"
        cp -r "${DFILE}" "${BACKUP_DIR}/daily/${DB}-latest${BACKUP_SUFFIX}"
        cp -r "${WFILE}" "${BACKUP_DIR}/weekly/${DB}-latest${BACKUP_SUFFIX}"
        cp -r "${MFILE}" "${BACKUP_DIR}/monthly/${DB}-latest${BACKUP_SUFFIX}"
      else
        # shellcheck disable=SC2086
        ln ${LATEST_LN_ARG} -f "${LAST_FILENAME}" "${BACKUP_DIR}/last/${DB}-latest${LATEST_SUFFIX}"
        # shellcheck disable=SC2086
        ln ${LATEST_LN_ARG} -f "${DAILY_FILENAME}" "${BACKUP_DIR}/daily/${DB}-latest${LATEST_SUFFIX}"
        # shellcheck disable=SC2086
        ln ${LATEST_LN_ARG} -f "${WEEKLY_FILENAME}" "${BACKUP_DIR}/weekly/${DB}-latest${LATEST_SUFFIX}"
        # shellcheck disable=SC2086
        ln ${LATEST_LN_ARG} -f "${MONTHLY_FILENAME}" "${BACKUP_DIR}/monthly/${DB}-latest${LATEST_SUFFIX}"
      fi
    fi

    # Send backup to Telegram (respects TELEGRAM_NOTIFY_ON)
    if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
      if [ "${TELEGRAM_NOTIFY_ON}" = "all" ] || [ "${TELEGRAM_NOTIFY_ON}" = "success" ]; then
        send_to_telegram "${FILE}" "${DB}"
      fi
    fi

    # Clean old files (exclude -latest symlinks)
    CLEANUP_SUFFIX="${BACKUP_SUFFIX}"
    if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
      CLEANUP_SUFFIX="${BACKUP_SUFFIX}.gpg"
    fi
    if [ -n "${KEEP_MINS}" ]; then
      find "${BACKUP_DIR}/last" -maxdepth 1 -mmin "+${KEEP_MINS}" -name "${DB}-*${CLEANUP_SUFFIX}" ! -name "${DB}-latest${CLEANUP_SUFFIX}" -exec rm -rf '{}' +
    fi
    if [ -n "${KEEP_DAYS}" ]; then
      find "${BACKUP_DIR}/daily" -maxdepth 1 -mtime "+${KEEP_DAYS}" -name "${DB}-*${CLEANUP_SUFFIX}" ! -name "${DB}-latest${CLEANUP_SUFFIX}" -exec rm -rf '{}' +
    fi
    if [ -n "${KEEP_WEEKS}" ]; then
      find "${BACKUP_DIR}/weekly" -maxdepth 1 -mtime "+${KEEP_WEEKS}" -name "${DB}-*${CLEANUP_SUFFIX}" ! -name "${DB}-latest${CLEANUP_SUFFIX}" -exec rm -rf '{}' +
    fi
    if [ -n "${KEEP_MONTHS}" ]; then
      find "${BACKUP_DIR}/monthly" -maxdepth 1 -mtime "+${KEEP_MONTHS}" -name "${DB}-*${CLEANUP_SUFFIX}" ! -name "${DB}-latest${CLEANUP_SUFFIX}" -exec rm -rf '{}' +
    fi
  else
    echo "❌ Error: Backup file ${FILE} is empty or missing. Skipping." >&2
    BACKUP_FAILED=$((BACKUP_FAILED + 1))
    FAILED_DBS="${FAILED_DBS} ${DB}"
  fi
done

# Backup summary
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))
echo "────────────────────────────────────────"
echo "Backup completed in ${BACKUP_DURATION}s: ${BACKUP_SUCCESS} succeeded, ${BACKUP_FAILED} failed"
echo "────────────────────────────────────────"

# Write health status file
STATUS_FILE="/tmp/backup_status"
if [ "${BACKUP_FAILED}" -eq 0 ]; then
  printf "OK\n%s\n" "$(date +%s)" > "${STATUS_FILE}"
else
  printf "FAILED\n%s\n" "$(date +%s)" > "${STATUS_FILE}"
fi

# Telegram summary notifications
if [ "${TELEGRAM_NOTIFY_ON}" != "none" ]; then
  PROJECT_LABEL=""
  if [ -n "${PROJECT_NAME}" ]; then
    PROJECT_LABEL=" [${PROJECT_NAME}]"
  fi

  if [ "${BACKUP_FAILED}" -gt 0 ] && [ "${TELEGRAM_NOTIFY_ON}" != "success" ]; then
    send_telegram_message "❌ *Backup Failed*${PROJECT_LABEL}
Host: \`${POSTGRES_HOST}\`
Failed: \`$(echo "${FAILED_DBS}" | xargs)\`
Time: $(date +'%Y-%m-%d %H:%M:%S')
Duration: ${BACKUP_DURATION}s"
  elif [ "${BACKUP_FAILED}" -eq 0 ] && [ "${TELEGRAM_NOTIFY_ON}" = "all" ]; then
    send_telegram_message "✅ *Backup OK*${PROJECT_LABEL}
Host: \`${POSTGRES_HOST}\`
Databases: ${BACKUP_SUCCESS}
Time: $(date +'%Y-%m-%d %H:%M:%S')
Duration: ${BACKUP_DURATION}s"
  fi
fi

# Post-backup hook
if [ -d "${HOOKS_DIR}" ]; then
  run-parts -a "post-backup" --reverse --exit-on-error "${HOOKS_DIR}"
fi
