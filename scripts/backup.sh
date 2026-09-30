#!/usr/bin/env bash
set -Eeo pipefail

# The real directory of this script: /backup.sh and /usr/local/bin/backup are symlinks.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Define the error handling function (HOOKS_DIR is overridden by the tests only)
HOOKS_DIR="${HOOKS_DIR:-/hooks}"
if [ -d "${HOOKS_DIR}" ]; then
  on_error(){
    run-parts -a "error" "${HOOKS_DIR}"
  }
  trap 'on_error' ERR
fi

source "${SCRIPT_DIR}/env.sh"
# shellcheck source=scripts/lib/layout.sh
source "${SCRIPT_DIR}/lib/layout.sh"
# shellcheck source=scripts/lib/dump.sh
source "${SCRIPT_DIR}/lib/dump.sh"
# shellcheck source=scripts/lib/discover.sh
source "${SCRIPT_DIR}/lib/discover.sh"
# shellcheck source=scripts/lib/rls_guard.sh
source "${SCRIPT_DIR}/lib/rls_guard.sh"
# shellcheck source=scripts/lib/metrics.sh
source "${SCRIPT_DIR}/lib/metrics.sh"

# One run at a time, across every container that shares BACKUP_DIR. A second run
# exits 75 (EX_TEMPFAIL) before touching anything: it would otherwise delete the
# running one's .part file.
exec 200>>"${BACKUP_DIR}/.lock"
if ! flock -n 200; then
  echo "⏳ Another backup run holds ${BACKUP_DIR}/.lock. Not started." >&2
  exit 75
fi

# One timestamp per run: every file this run writes carries the run's start time,
# and the weekly/monthly decisions use the same instant.
read -r STAMP RUN_DATE RUN_WEEK RUN_MONTH RUN_WEEKDAY RUN_DAY <<< "$(date '+%Y%m%d-%H%M%S %Y%m%d %G%V %Y%m %u %d')"
BACKUP_START_TIME=$(date +%s)

prepare_backup_dir
prepare_keyfile
detect_dump_format

# Results per database, for the metrics
BACKUP_SUCCESS=0
BACKUP_FAILED=0
FAILED_DBS=""
DISCOVER_SKIPPED=""
declare -A DB_OK=() DB_SECONDS=()

# A run that stops before the databases: record it as failed, exit 1.
abort_run() {
  write_metrics 1 || echo "⚠️ Could not write the metrics." >&2
  exit 1
}

# Pre-backup hook
if [ -d "${HOOKS_DIR}" ]; then
  run-parts -a "pre-backup" --exit-on-error "${HOOKS_DIR}"
fi

# Check database connectivity before starting
POSTGRES_CONNECT_TIMEOUT="${POSTGRES_CONNECT_TIMEOUT:-30}"
echo "Checking database connectivity (timeout: ${POSTGRES_CONNECT_TIMEOUT}s)..."
if ! pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -t "${POSTGRES_CONNECT_TIMEOUT}" -q 2>/dev/null; then
  echo "❌ Database is not reachable at ${PGHOST}:${PGPORT}. Aborting backup." >&2
  abort_run
fi
echo "✅ Database is reachable."

# Auto-discover databases (opt-in). Runs only after connectivity is confirmed.
if [ "${POSTGRES_DB_AUTODISCOVER}" = "TRUE" ]; then
  if [ "${POSTGRES_CLUSTER}" = "TRUE" ]; then
    echo "ℹ️ Auto-discover ignored: cluster mode dumps the whole cluster via pg_dumpall."
  elif ! discover_databases; then
    abort_run
  fi
fi

# Check available disk space (default minimum: 100MB)
BACKUP_MIN_DISK_SPACE="${BACKUP_MIN_DISK_SPACE:-100}"
AVAILABLE_MB=$(df -m "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${AVAILABLE_MB}" ] && [ "${AVAILABLE_MB}" -lt "${BACKUP_MIN_DISK_SPACE}" ]; then
  echo "❌ Low disk space: ${AVAILABLE_MB}MB available, ${BACKUP_MIN_DISK_SPACE}MB required. Aborting." >&2
  abort_run
fi
echo "✅ Disk space OK (${AVAILABLE_MB}MB available)."

# Build exclude-table args if POSTGRES_EXCLUDE_TABLES is set (no pathname expansion)
EXCLUDE_ARGS=""
if [ -n "${POSTGRES_EXCLUDE_TABLES}" ]; then
  set -f
  # shellcheck disable=SC2086
  for TABLE in ${POSTGRES_EXCLUDE_TABLES//,/ }; do
    EXCLUDE_ARGS="${EXCLUDE_ARGS} --exclude-table=${TABLE}"
  done
  set +f
  echo "Excluding tables: ${POSTGRES_EXCLUDE_TABLES}"
fi

# Telegram notification control (default: all)
TELEGRAM_NOTIFY_ON="${TELEGRAM_NOTIFY_ON:-all}"

# Telegram file size limit (50MB in bytes) and the bot MTProto ceiling (2GB)
TELEGRAM_MAX_SIZE=52428800
TELEGRAM_MTPROTO_MAX_SIZE=2147483648

# Send the prepared upload file to Telegram via the MTProto binary (tg-upload).
# Args: <upload_file> <caption> <original_file>. Delivery failure is non-fatal;
# cleans up a directory tar archive afterward.
mtproto_send() {
  local upload_file="$1" cap="$2" orig="$3"
  local tg_args=(--file "${upload_file}" --chat "${TELEGRAM_CHAT_ID}" --caption "${cap}")
  if [ -n "${TELEGRAM_THREAD_ID}" ]; then
    tg_args+=(--thread "${TELEGRAM_THREAD_ID}")
  fi
  if tg-upload "${tg_args[@]}"; then
    echo "✅ Backup sent to Telegram (MTProto)."
  else
    echo "⚠️ MTProto upload failed. Backup is still saved locally." >&2
  fi
  if [ -d "${orig}" ]; then rm -f "${upload_file}"; fi
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

  local method="${TELEGRAM_UPLOAD_METHOD:-smart}"

  # mtproto mode: deliver every file via the MTProto binary, regardless of size.
  if [ "${method}" = "mtproto" ]; then
    if [ "${file_size}" -gt "${TELEGRAM_MTPROTO_MAX_SIZE}" ]; then
      echo "⚠️ Backup $(get_size "${send_file}") exceeds the 2GB MTProto limit. Kept locally." >&2
      if [ -d "${file}" ]; then rm -f "${send_file}"; fi
      return 1
    fi
    echo "⬆️ Uploading via MTProto (TELEGRAM_UPLOAD_METHOD=mtproto)..."
    mtproto_send "${send_file}" "${caption}" "${file}"
    return 0
  fi

  # Official Bot API caps uploads at 50MB. In smart mode an oversize file may be
  # routed to MTProto; in botapi mode it never is.
  if [ "${TELEGRAM_API_URL}" = "https://api.telegram.org" ] && [ "${file_size}" -gt "${TELEGRAM_MAX_SIZE}" ]; then
    if [ "${method}" = "smart" ] \
       && [ "${file_size}" -le "${TELEGRAM_MTPROTO_MAX_SIZE}" ] \
       && [ -n "${TELEGRAM_API_ID}" ] && [ -n "${TELEGRAM_API_HASH}" ] \
       && command -v tg-upload >/dev/null 2>&1; then
      echo "⬆️ Backup exceeds 50MB — uploading via MTProto (up to 2GB)..."
      mtproto_send "${send_file}" "${caption}" "${file}"
      return 0
    fi
    echo "⚠️ Backup $(get_size "${send_file}") exceeds Telegram 50MB limit." >&2
    if [ "${method}" = "smart" ]; then
      echo "💡 Hint: set TELEGRAM_API_ID + TELEGRAM_API_HASH to send via MTProto (up to 2GB), or set TELEGRAM_API_URL to a self-hosted Bot API server." >&2
    fi
    if [ -d "${file}" ]; then rm -f "${send_file}"; fi
    return 1
  fi

  # Fan out to every configured chat. Upload to the first chat, then reuse the
  # returned file_id for the rest (no re-upload). Falls back to re-uploading if
  # the first send fails to yield a file_id.
  local chat_ids
  read -ra chat_ids <<< "${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID}}"
  local single_chat="false"
  if [ "${#chat_ids[@]}" -le 1 ]; then single_chat="true"; fi

  local file_id=""
  local sent=0
  local chat_id
  for chat_id in "${chat_ids[@]}"; do
    local curl_args=()
    curl_args+=(-F "chat_id=${chat_id}")
    if [ -n "${file_id}" ]; then
      curl_args+=(-F "document=${file_id}")
    else
      curl_args+=(-F "document=@${send_file}")
    fi
    curl_args+=(-F "caption=${caption}")
    if [ "${single_chat}" = "true" ] && [ -n "${TELEGRAM_THREAD_ID}" ]; then
      curl_args+=(-F "message_thread_id=${TELEGRAM_THREAD_ID}")
    fi

    local response
    response=$(curl -s -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
      "${curl_args[@]}")

    if echo "${response}" | grep -q '"ok":true'; then
      sent=$((sent + 1))
      echo "✅ Backup sent to Telegram chat ${chat_id}."
      if [ -z "${file_id}" ]; then
        file_id=$(echo "${response}" | grep -o '"file_id":"[^"]*"' | head -1 | cut -d'"' -f4)
      fi
      # Embed the restore id in the message caption so it can be retrieved later
      # with `restore --from-telegram`. Non-fatal: the backup is already sent.
      local message_id
      message_id=$(echo "${response}" | grep -o '"message_id":[0-9]*' | head -1 | cut -d':' -f2)
      if [ -n "${message_id}" ]; then
        curl -s -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/editMessageCaption" \
          -F "chat_id=${chat_id}" \
          -F "message_id=${message_id}" \
          -F "caption=${caption}"$'\n'"🔖 Restore ID: ${message_id}" \
          > /dev/null 2>&1 || echo "⚠️ Could not embed restore id for chat ${chat_id}." >&2
      fi
    else
      local error_desc
      error_desc=$(echo "${response}" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
      echo "⚠️ Failed to send backup to Telegram chat ${chat_id}: ${error_desc:-unknown error}." >&2
    fi
  done

  if [ "${sent}" -eq 0 ]; then
    echo "⚠️ Backup not delivered to any chat. It is still saved locally." >&2
  fi

  # Clean up temporary tar archive
  if [ -d "${file}" ]; then
    rm -f "${send_file}"
  fi
}

# Send a text message to Telegram
send_telegram_message() {
  local message="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
    return 0
  fi
  local chat_ids
  read -ra chat_ids <<< "${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID}}"
  local single_chat="false"
  if [ "${#chat_ids[@]}" -le 1 ]; then single_chat="true"; fi
  local chat_id
  for chat_id in "${chat_ids[@]}"; do
    local curl_args=()
    curl_args+=(-d "chat_id=${chat_id}")
    curl_args+=(-d "text=${message}")
    curl_args+=(-d "parse_mode=Markdown")
    if [ "${single_chat}" = "true" ] && [ -n "${TELEGRAM_THREAD_ID}" ]; then
      curl_args+=(-d "message_thread_id=${TELEGRAM_THREAD_ID}")
    fi
    curl -s --fail -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      "${curl_args[@]}" > /dev/null 2>&1 || true
  done
}

# One database (or the cluster): dump to last/.<name>.part, accept it only if the
# dump succeeded, is big enough and reads back in full, then rename it into place
# and link it into the other folders. Any failure keeps the previous dump.
backup_database() {
  local db="$1" name part file
  name="$(final_name "${db}")"
  part="${BACKUP_DIR}/last/.${name}.part"
  file="${BACKUP_DIR}/last/${name}"

  if [ "${BACKUP_RLS_GUARD}" = "TRUE" ] && [ "${DUMP_FORMAT}" != "cluster" ]; then
    rls_guard_check "${db}" || return 1
  fi

  echo "Creating dump of ${db} from ${POSTGRES_HOST}..."
  if ! dump_to_part "${db}" "${part}"; then
    echo "❌ ${db}: dump failed. Previous dump kept." >&2
    rm -rf "${part}"
    return 1
  fi
  if ! check_part_size "${db}" "${part}"; then
    rm -rf "${part}"
    return 1
  fi
  if ! verify_part "${part}"; then
    echo "❌ ${db}: verification failed. Previous dump kept." >&2
    rm -rf "${part}"
    return 1
  fi
  if ! mv "${part}" "${file}"; then
    echo "❌ ${db}: could not move the dump into last/. Previous dump kept." >&2
    rm -rf "${part}"
    return 1
  fi
  if ! link_into_slots "${db}" "${file}"; then
    echo "❌ ${db}: could not link the dump into daily/weekly/monthly." >&2
    return 1
  fi
  echo "✅ Backup created: ${file} ($(get_size "${file}"), $(get_size_bytes "${file}") bytes, $(( $(date +%s) - DB_START_TIME ))s)"

  # Send backup to Telegram (respects TELEGRAM_NOTIFY_ON); delivery never fails the backup
  if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
    if [ "${TELEGRAM_NOTIFY_ON}" = "all" ] || [ "${TELEGRAM_NOTIFY_ON}" = "success" ]; then
      send_to_telegram "${file}" "${db}" || true
    fi
  fi
}

if [ "${POSTGRES_CLUSTER}" = "TRUE" ]; then
  POSTGRES_DBS="cluster"
fi

set -f
# shellcheck disable=SC2206
DBS=(${POSTGRES_DBS})
set +f
for DB in "${DBS[@]}"; do
  DB_START_TIME=$(date +%s)
  if backup_database "${DB}"; then
    BACKUP_SUCCESS=$((BACKUP_SUCCESS + 1))
    DB_OK["${DB}"]=1
  else
    BACKUP_FAILED=$((BACKUP_FAILED + 1))
    FAILED_DBS="${FAILED_DBS} ${DB}"
    DB_OK["${DB}"]=0
  fi
  DB_SECONDS["${DB}"]=$(( $(date +%s) - DB_START_TIME ))
done

# Dropped databases leave last/ (snapshot layout; needs a successful server listing)
prune_dropped_databases "$(final_suffix)"

# Retention, once, over every file (see apply_retention) — skipped when nothing was
# backed up, so a run failing for every database never erodes the last good copies.
if [ "${BACKUP_SUCCESS}" -gt 0 ]; then
  apply_retention "$(final_suffix)"
else
  echo "⚠️ No database was backed up this run; retention skipped." >&2
fi

# Metrics (never fail the backup)
RUN_RC=0
if [ "${BACKUP_FAILED}" -gt 0 ]; then
  RUN_RC=1
fi
write_metrics "${RUN_RC}" || echo "⚠️ Could not write the metrics." >&2

# Backup summary
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))
echo "────────────────────────────────────────"
echo "Backup completed in ${BACKUP_DURATION}s: ${BACKUP_SUCCESS} succeeded, ${BACKUP_FAILED} failed, $(wc -w <<< "${DISCOVER_SKIPPED}" | tr -d ' ') skipped"
if [ "${BACKUP_FAILED}" -gt 0 ]; then
  echo "❌ Failed: $(echo "${FAILED_DBS}" | xargs)" >&2
fi
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

# 0: every database dumped. 1: at least one failed (the others still ran).
if [ "${BACKUP_FAILED}" -gt 0 ]; then
  exit 1
fi
