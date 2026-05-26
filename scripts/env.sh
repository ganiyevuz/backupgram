#!/usr/bin/env bash

# Pre-validate the environment
if [ -z "${POSTGRES_DB}" ] && [ -z "${POSTGRES_DB_FILE}" ]; then
  echo "❌ You need to set the POSTGRES_DB or POSTGRES_DB_FILE environment variable."
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

# Process vars
if [ -z "${POSTGRES_DB_FILE}" ]; then
  POSTGRES_DBS="${POSTGRES_DB//,/ }"
elif [ -r "${POSTGRES_DB_FILE}" ]; then
  # shellcheck disable=SC2034
  POSTGRES_DBS="$(cat "${POSTGRES_DB_FILE}")"
else
  echo "❌ Missing POSTGRES_DB_FILE file."
  exit 1
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

# Encryption (optional)
if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
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
