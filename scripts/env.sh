#!/usr/bin/env bash

# Off-site retention defaults to the container's own BACKUP_KEEP_*, taken before the REST
# API overrides below: those may change BACKUP_KEEP_* but never an S3_* setting.
# s3-env.sh validates and exports them.
S3_KEEP_DAYS="${S3_KEEP_DAYS:-${BACKUP_KEEP_DAYS:-7}}"
S3_KEEP_WEEKS="${S3_KEEP_WEEKS:-${BACKUP_KEEP_WEEKS:-4}}"
S3_KEEP_MONTHS="${S3_KEEP_MONTHS:-${BACKUP_KEEP_MONTHS:-6}}"

# Apply runtime config overrides written by the REST API (if present). These are
# 'export KEY=...' lines, so sourcing makes them visible to backup.sh, restore.sh,
# and the run-parts hooks. Values are single-quote-escaped by the API.
_API_OVERRIDES="${BACKUP_DIR:-/backups}/.api-overrides.env"
if [ -f "${_API_OVERRIDES}" ]; then
  # shellcheck disable=SC1090
  . "${_API_OVERRIDES}"
fi

# Pre-validate the environment
if [ "${POSTGRES_DB_AUTODISCOVER}" != "TRUE" ] && [ -z "${POSTGRES_DB}" ] && [ -z "${POSTGRES_DB_FILE}" ]; then
  echo "❌ You need to set POSTGRES_DB or POSTGRES_DB_FILE (or enable POSTGRES_DB_AUTODISCOVER)."
  exit 1
fi

if [ -z "${POSTGRES_HOST}" ]; then
  if [ -n "${POSTGRES_PORT_5432_TCP_ADDR}" ]; then
    POSTGRES_HOST="${POSTGRES_PORT_5432_TCP_ADDR}"
    POSTGRES_PORT="${POSTGRES_PORT_5432_TCP_PORT}"
  else
    echo "❌ You need to set the POSTGRES_HOST environment variable."
    exit 1
  fi
fi

if [ -z "${POSTGRES_USER}" ] && [ -z "${POSTGRES_USER_FILE}" ]; then
  echo "❌ You need to set the POSTGRES_USER or POSTGRES_USER_FILE environment variable."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD}" ] && [ -z "${POSTGRES_PASSWORD_FILE}" ] && [ -z "${POSTGRES_PASSFILE_STORE}" ]; then
  echo "❌ You need to set the POSTGRES_PASSWORD, POSTGRES_PASSWORD_FILE, or POSTGRES_PASSFILE_STORE environment variable."
  exit 1
fi

# REST API must never be exposed without a token.
if [ "${REST_API_ENABLE}" = "TRUE" ] && [ -z "${REST_API_TOKEN}" ] && [ -z "${REST_API_TOKEN_FILE}" ]; then
  echo "❌ REST_API_ENABLE=TRUE requires REST_API_TOKEN or REST_API_TOKEN_FILE." >&2
  exit 1
fi

# Process vars
if [ "${POSTGRES_DB_AUTODISCOVER}" = "TRUE" ]; then
  # Auto-discover mode: the DB list is resolved at backup time, after
  # connectivity is confirmed (see backup.sh). env.sh stays connection-free so
  # standalone VALIDATE_ON_START works even when the server is unreachable.
  if [ -n "${POSTGRES_DB}" ] || [ -n "${POSTGRES_DB_FILE}" ]; then
    echo "ℹ️ POSTGRES_DB / POSTGRES_DB_FILE ignored: auto-discover is on (databases are discovered at backup time)."
  fi
  # shellcheck disable=SC2034
  POSTGRES_DBS=""
elif [ -z "${POSTGRES_DB_FILE}" ]; then
  POSTGRES_DBS="${POSTGRES_DB//,/ }"
elif [ -r "${POSTGRES_DB_FILE}" ]; then
  # shellcheck disable=SC2034
  POSTGRES_DBS="$(cat "${POSTGRES_DB_FILE}")"
else
  echo "❌ Missing POSTGRES_DB_FILE file."
  exit 1
fi

# POSTGRES_DB_EXCLUDE has no effect unless auto-discover is on; warn rather than fail.
if [ -n "${POSTGRES_DB_EXCLUDE}" ] && [ "${POSTGRES_DB_AUTODISCOVER}" != "TRUE" ]; then
  echo "ℹ️ POSTGRES_DB_EXCLUDE ignored (auto-discover is off)."
fi

# POSTGRES_DB_INCLUDE likewise only filters auto-discovered names.
if [ -n "${POSTGRES_DB_INCLUDE}" ] && [ "${POSTGRES_DB_AUTODISCOVER}" != "TRUE" ]; then
  echo "ℹ️ POSTGRES_DB_INCLUDE ignored (auto-discover is off)."
fi

if [ -z "${POSTGRES_USER_FILE}" ]; then
  export PGUSER="${POSTGRES_USER}"
elif [ -r "${POSTGRES_USER_FILE}" ]; then
  # shellcheck disable=SC2155
  export PGUSER="$(cat "${POSTGRES_USER_FILE}")"
else
  echo "❌ Missing POSTGRES_USER_FILE file."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD_FILE}" ] && [ -z "${POSTGRES_PASSFILE_STORE}" ]; then
  export PGPASSWORD="${POSTGRES_PASSWORD}"
elif [ -r "${POSTGRES_PASSWORD_FILE}" ]; then
  # shellcheck disable=SC2155
  export PGPASSWORD="$(cat "${POSTGRES_PASSWORD_FILE}")"
elif [ -r "${POSTGRES_PASSFILE_STORE}" ]; then
  export PGPASSFILE="${POSTGRES_PASSFILE_STORE}"
else
  echo "❌ Missing POSTGRES_PASSWORD_FILE or POSTGRES_PASSFILE_STORE file."
  exit 1
fi

# Telegram Bot (optional)
if [ -n "${TELEGRAM_BOT_TOKEN_FILE}" ] && [ -r "${TELEGRAM_BOT_TOKEN_FILE}" ]; then
  # shellcheck disable=SC2155
  export TELEGRAM_BOT_TOKEN="$(cat "${TELEGRAM_BOT_TOKEN_FILE}")"
fi

if [ -n "${TELEGRAM_CHAT_ID_FILE}" ] && [ -r "${TELEGRAM_CHAT_ID_FILE}" ]; then
  # shellcheck disable=SC2155
  export TELEGRAM_CHAT_ID="$(cat "${TELEGRAM_CHAT_ID_FILE}")"
fi
# MTProto large-file upload credentials (optional, from https://my.telegram.org/apps)
if [ -n "${TELEGRAM_API_ID_FILE}" ] && [ -r "${TELEGRAM_API_ID_FILE}" ]; then
  # shellcheck disable=SC2155
  export TELEGRAM_API_ID="$(cat "${TELEGRAM_API_ID_FILE}")"
fi
if [ -n "${TELEGRAM_API_HASH_FILE}" ] && [ -r "${TELEGRAM_API_HASH_FILE}" ]; then
  # shellcheck disable=SC2155
  export TELEGRAM_API_HASH="$(cat "${TELEGRAM_API_HASH_FILE}")"
fi

# Fall back to backupgram's bundled shared Telegram app credentials when the
# operator supplied neither their own id nor hash. Only the app *identity* is
# shared — auth still uses the operator's own bot token and backups go to their
# own chat, so operator data is never exposed. Opt out with
# TELEGRAM_USE_DEFAULT_API=FALSE. The file is written at image build (root-only,
# not an env var); it is intentionally out of the container's visible env.
_DEFAULT_TG_API_FILE="/etc/backupgram/default-telegram-api"
if [ "${TELEGRAM_USE_DEFAULT_API}" != "FALSE" ] \
  && [ -z "${TELEGRAM_API_ID}" ] && [ -z "${TELEGRAM_API_HASH}" ] \
  && [ -r "${_DEFAULT_TG_API_FILE}" ]; then
  { read -r _def_api_id; read -r _def_api_hash; } < "${_DEFAULT_TG_API_FILE}"
  if [ -n "${_def_api_id}" ] && [ -n "${_def_api_hash}" ]; then
    export TELEGRAM_API_ID="${_def_api_id}"
    export TELEGRAM_API_HASH="${_def_api_hash}"
    TELEGRAM_API_IS_DEFAULT="TRUE"
  fi
  unset _def_api_id _def_api_hash
fi

if [ -n "${TELEGRAM_API_ID}" ] && [ -n "${TELEGRAM_API_HASH}" ]; then
  if [ "${TELEGRAM_API_IS_DEFAULT}" = "TRUE" ]; then
    echo "ℹ️ Large-file upload uses backupgram's shared Telegram app (MTProto, up to 2GB)."
    echo "   Your backups and bot stay private — this only identifies the app to Telegram, so your data isn't affected at all."
    echo "   Recommended: set your own TELEGRAM_API_ID / TELEGRAM_API_HASH (https://my.telegram.org/apps) to be fully on your own."
    echo "   Disable the shared default with TELEGRAM_USE_DEFAULT_API=FALSE."
  else
    echo "✅ Large-file upload enabled (MTProto, up to 2GB)."
  fi
fi

# Upload method selector: smart (auto by size) | botapi (Bot API only) | mtproto (binary only).
TELEGRAM_UPLOAD_METHOD="$(echo "${TELEGRAM_UPLOAD_METHOD:-smart}" | tr '[:upper:]' '[:lower:]')"
case "${TELEGRAM_UPLOAD_METHOD}" in
  smart | botapi) ;;
  mtproto)
    if [ -z "${TELEGRAM_API_ID}" ] || [ -z "${TELEGRAM_API_HASH}" ]; then
      echo "❌ TELEGRAM_UPLOAD_METHOD=mtproto requires TELEGRAM_API_ID and TELEGRAM_API_HASH." >&2
      exit 1
    fi
    ;;
  *)
    echo "❌ TELEGRAM_UPLOAD_METHOD must be one of: smart, botapi, mtproto (got '${TELEGRAM_UPLOAD_METHOD}')." >&2
    exit 1
    ;;
esac
export TELEGRAM_UPLOAD_METHOD

# Split comma-separated chat ids into a space-separated list for fan-out delivery.
TELEGRAM_CHAT_IDS="${TELEGRAM_CHAT_ID//,/ }"

# A forum-topic id is valid only within one supergroup, so warn that it is
# ignored when delivering to multiple chats.
if [ -n "${TELEGRAM_THREAD_ID}" ]; then
  read -ra _chat_id_arr <<< "${TELEGRAM_CHAT_IDS}"
  if [ "${#_chat_id_arr[@]}" -gt 1 ]; then
    echo "⚠️ Multiple chat ids set — TELEGRAM_THREAD_ID will be ignored (topic ids are per-supergroup)." >&2
  fi
  unset _chat_id_arr
fi

# Set Telegram API URL (default to official, allow custom self-hosted Bot API)
export TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
  if [ "${TELEGRAM_API_URL}" != "https://api.telegram.org" ]; then
    echo "✅ Telegram notifications enabled (custom API: ${TELEGRAM_API_URL})."
  else
    echo "✅ Telegram notifications enabled."
  fi
elif [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -z "${TELEGRAM_CHAT_ID}" ]; then
  echo "⚠️ TELEGRAM_BOT_TOKEN is set but TELEGRAM_CHAT_ID is missing. Telegram disabled." >&2
elif [ -z "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
  echo "⚠️ TELEGRAM_CHAT_ID is set but TELEGRAM_BOT_TOKEN is missing. Telegram disabled." >&2
else
  echo "⚠️ Telegram credentials not provided. Telegram notifications disabled."
fi

# Unsigned integer settings. Digits are spelled out: in a UTF-8 locale [0-9] also matches
# non-ASCII digits (٥, ５).
for _uint_var in BACKUP_MIN_BYTES BACKUP_GID; do
  if [ -n "${!_uint_var}" ] && ! [[ "${!_uint_var}" =~ ^[0123456789]+$ ]]; then
    echo "❌ ${_uint_var} must be a whole number (got '${!_uint_var}')." >&2
    exit 1
  fi
done
unset _uint_var

# TRUE/FALSE settings
for _bool_var in BACKUP_RLS_GUARD METRICS_ENABLE; do
  case "${!_bool_var:-FALSE}" in
    TRUE | FALSE) ;;
    *)
      echo "❌ ${_bool_var} must be TRUE or FALSE (got '${!_bool_var}')." >&2
      exit 1
      ;;
  esac
done
unset _bool_var

if [ -n "${METRICS_TEXTFILE_DIR}" ] && { [ ! -d "${METRICS_TEXTFILE_DIR}" ] || [ ! -w "${METRICS_TEXTFILE_DIR}" ]; }; then
  echo "❌ METRICS_TEXTFILE_DIR must be a writable directory (got '${METRICS_TEXTFILE_DIR}')." >&2
  exit 1
fi

BACKUP_LAYOUT="${BACKUP_LAYOUT:-period}"
case "${BACKUP_LAYOUT}" in
  period | snapshot) ;;
  *)
    echo "❌ BACKUP_LAYOUT must be period or snapshot (got '${BACKUP_LAYOUT}')." >&2
    exit 1
    ;;
esac

# Encryption (optional)
if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
  # A second line would be written to the passphrase file and silently dropped by gpg.
  if [[ "${BACKUP_ENCRYPTION_KEY}" == *$'\n'* ]]; then
    echo "❌ BACKUP_ENCRYPTION_KEY must be a single line (gpg reads only the first line of the passphrase file)." >&2
    exit 1
  fi
  if command -v gpg >/dev/null 2>&1; then
    echo "✅ Backup encryption enabled (GPG)."
  else
    echo "❌ BACKUP_ENCRYPTION_KEY is set but gpg is not installed." >&2
    exit 1
  fi
fi

export PGHOST="${POSTGRES_HOST}"
export PGPORT="${POSTGRES_PORT}"

# shellcheck disable=SC2034
KEEP_MINS="${BACKUP_KEEP_MINS}"
# shellcheck disable=SC2034
KEEP_DAYS="${BACKUP_KEEP_DAYS}"
# shellcheck disable=SC2034
KEEP_WEEKS=$((BACKUP_KEEP_WEEKS * 7 + 1))
# shellcheck disable=SC2034
KEEP_MONTHS=$((BACKUP_KEEP_MONTHS * 31 + 1))

if [ ! -d "${BACKUP_DIR}" ] || [ ! -w "${BACKUP_DIR}" ] || [ ! -x "${BACKUP_DIR}" ]; then
  echo "❌ BACKUP_DIR points to a file or folder with insufficient permissions."
  exit 1
fi

# Off-site copies (S3): resolve and validate the S3_* settings. Executed (the startup
# check), a bad one refuses to start. Sourced by a run, it only turns the off-site copies
# off (S3_SETTINGS_INVALID): the local backups and restores go on.
_S3_ENV_LENIENT="FALSE"
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  _S3_ENV_LENIENT="TRUE"
fi
# shellcheck source=scripts/s3-env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/s3-env.sh"
unset _S3_ENV_LENIENT
