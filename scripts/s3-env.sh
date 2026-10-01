#!/usr/bin/env bash
# Off-site (S3) settings: resolves the Docker-secret *_FILE variants (the file wins),
# fills the defaults and validates. Sourced by env.sh (backup mode), restore/list and
# the uploader; executed by init.sh in uploader mode and by the uploader's job before
# each sync. Exits 1 with a ❌ line on a bad setting, except in a run, where env.sh
# sources it with _S3_ENV_LENIENT=TRUE: a bad setting then prints a ⚠️ line, sets
# S3_SETTINGS_INVALID=TRUE and returns, so a setting that breaks after startup turns
# the off-site copies off, never the local backups and restores. With S3_BUCKET empty
# it only checks BACKUPGRAM_MODE.

S3_SETTINGS_INVALID=""

# Resolves, exports and checks the settings. On the first bad one, puts its message in
# _s3_problem and returns 1. Runs in an `if`, so every check is explicit and none exits.
_s3_env() {
  local secret file_var var
  BACKUPGRAM_MODE="${BACKUPGRAM_MODE:-backup}"
  case "${BACKUPGRAM_MODE}" in
    backup | s3-sync) ;;
    *)
      _s3_problem="BACKUPGRAM_MODE must be backup or s3-sync (got '${BACKUPGRAM_MODE}')."
      return 1
      ;;
  esac
  export BACKUPGRAM_MODE

  if [ "${BACKUPGRAM_MODE}" = "s3-sync" ] && [ -z "${S3_BUCKET}" ]; then
    _s3_problem="BACKUPGRAM_MODE=s3-sync requires S3_BUCKET."
    return 1
  fi
  if [ -z "${S3_BUCKET}" ]; then
    return 0
  fi

  for secret in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
    file_var="${secret}_FILE"
    if [ -n "${!file_var}" ]; then
      if [ ! -r "${!file_var}" ]; then
        _s3_problem="${file_var} points to a missing or unreadable file."
        return 1
      fi
      export "${secret}=$(cat "${!file_var}")"
    fi
  done
  if [ -z "${S3_ACCESS_KEY_ID}" ] || [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
    _s3_problem="S3_BUCKET is set but S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY (or their _FILE variants) are missing."
    return 1
  fi
  export S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
  export S3_ENDPOINT="${S3_ENDPOINT:-https://s3.amazonaws.com}"
  export S3_REGION="${S3_REGION:-us-east-1}"
  export S3_PREFIX="${S3_PREFIX:-}"
  export S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-FALSE}"
  export S3_PRUNE="${S3_PRUNE:-TRUE}"
  export S3_ALLOW_UNENCRYPTED="${S3_ALLOW_UNENCRYPTED:-FALSE}"
  export S3_KEEP_DAYS="${S3_KEEP_DAYS:-${BACKUP_KEEP_DAYS:-7}}"
  export S3_KEEP_WEEKS="${S3_KEEP_WEEKS:-${BACKUP_KEEP_WEEKS:-4}}"
  export S3_KEEP_MONTHS="${S3_KEEP_MONTHS:-${BACKUP_KEEP_MONTHS:-6}}"
  export S3_SYNC_TIMEOUT="${S3_SYNC_TIMEOUT:-3600}"
  for var in S3_FORCE_PATH_STYLE S3_PRUNE S3_ALLOW_UNENCRYPTED; do
    case "${!var}" in
      TRUE | FALSE) ;;
      *)
        _s3_problem="${var} must be TRUE or FALSE (got '${!var}')."
        return 1
        ;;
    esac
  done
  for var in S3_KEEP_DAYS S3_KEEP_WEEKS S3_KEEP_MONTHS; do
    if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
      _s3_problem="${var} must be a whole number (got '${!var}')."
      return 1
    fi
  done
  # 1 to 9 digits, not all zeros: the values s3-sync accepts too.
  if ! [[ "${S3_SYNC_TIMEOUT}" =~ ^[0-9]{1,9}$ && "${S3_SYNC_TIMEOUT}" =~ [1-9] ]]; then
    _s3_problem="S3_SYNC_TIMEOUT must be a whole number of seconds from 1 to 999999999 (got '${S3_SYNC_TIMEOUT}')."
    return 1
  fi
  case "${S3_ENDPOINT}" in
    http://?* | https://?*) ;;
    *)
      _s3_problem="S3_ENDPOINT must start with http:// or https:// (got '${S3_ENDPOINT}')."
      return 1
      ;;
  esac
  return 0
}

_s3_problem=""
if ! _s3_env; then
  if [ "${_S3_ENV_LENIENT}" = "TRUE" ]; then
    echo "⚠️ ${_s3_problem} Off-site copies are off until it is fixed." >&2
    # shellcheck disable=SC2034  # read by lib/s3.sh and restore.sh
    S3_SETTINGS_INVALID="TRUE"
  else
    echo "❌ ${_s3_problem}" >&2
    exit 1
  fi
fi
unset -f _s3_env
unset _s3_problem
