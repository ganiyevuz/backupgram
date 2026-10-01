#!/usr/bin/env bash
# Off-site (S3) settings: resolves the Docker-secret *_FILE variants (the file wins),
# fills the defaults and validates. Sourced by env.sh (backup mode), restore/list and
# the uploader; executed by init.sh in uploader mode. Exits 1 with a ❌ line on a bad
# setting. With S3_BUCKET empty it only checks BACKUPGRAM_MODE.

BACKUPGRAM_MODE="${BACKUPGRAM_MODE:-backup}"
case "${BACKUPGRAM_MODE}" in
  backup | s3-sync) ;;
  *)
    echo "❌ BACKUPGRAM_MODE must be backup or s3-sync (got '${BACKUPGRAM_MODE}')." >&2
    exit 1
    ;;
esac
export BACKUPGRAM_MODE

if [ "${BACKUPGRAM_MODE}" = "s3-sync" ] && [ -z "${S3_BUCKET}" ]; then
  echo "❌ BACKUPGRAM_MODE=s3-sync requires S3_BUCKET." >&2
  exit 1
fi

if [ -n "${S3_BUCKET}" ]; then
  for _s3_secret in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
    _s3_file_var="${_s3_secret}_FILE"
    if [ -n "${!_s3_file_var}" ]; then
      if [ ! -r "${!_s3_file_var}" ]; then
        echo "❌ ${_s3_file_var} points to a missing or unreadable file." >&2
        exit 1
      fi
      export "${_s3_secret}=$(cat "${!_s3_file_var}")"
    fi
  done
  if [ -z "${S3_ACCESS_KEY_ID}" ] || [ -z "${S3_SECRET_ACCESS_KEY}" ]; then
    echo "❌ S3_BUCKET is set but S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY (or their _FILE variants) are missing." >&2
    exit 1
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
  for _s3_bool in S3_FORCE_PATH_STYLE S3_PRUNE S3_ALLOW_UNENCRYPTED; do
    case "${!_s3_bool}" in
      TRUE | FALSE) ;;
      *)
        echo "❌ ${_s3_bool} must be TRUE or FALSE (got '${!_s3_bool}')." >&2
        exit 1
        ;;
    esac
  done
  for _s3_uint in S3_KEEP_DAYS S3_KEEP_WEEKS S3_KEEP_MONTHS; do
    if ! [[ "${!_s3_uint}" =~ ^[0-9]+$ ]]; then
      echo "❌ ${_s3_uint} must be a whole number (got '${!_s3_uint}')." >&2
      exit 1
    fi
  done
  # 1 to 9 digits, not all zeros: the values s3-sync accepts too.
  if ! [[ "${S3_SYNC_TIMEOUT}" =~ ^[0-9]{1,9}$ && "${S3_SYNC_TIMEOUT}" =~ [1-9] ]]; then
    echo "❌ S3_SYNC_TIMEOUT must be a whole number of seconds from 1 to 999999999 (got '${S3_SYNC_TIMEOUT}')." >&2
    exit 1
  fi
  case "${S3_ENDPOINT}" in
    http://?* | https://?*) ;;
    *)
      echo "❌ S3_ENDPOINT must start with http:// or https:// (got '${S3_ENDPOINT}')." >&2
      exit 1
      ;;
  esac
  unset _s3_secret _s3_file_var _s3_bool _s3_uint
fi
