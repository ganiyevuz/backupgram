#!/usr/bin/env bash
set -Eeo pipefail

# List all backups with sizes and dates
# Usage: list [database_name] [--cleanup-preview] [--s3]

BACKUP_DIR="${BACKUP_DIR:-/backups}"
FILTER_DB=""
CLEANUP_PREVIEW=false
LIST_S3=false

# Parse arguments
for ARG in "$@"; do
  case "${ARG}" in
    --cleanup-preview) CLEANUP_PREVIEW=true ;;
    --s3) LIST_S3=true ;;
    *) FILTER_DB="${ARG}" ;;
  esac
done

# Off-site listing: the bucket's dumps, per database, with the tier that keeps each.
if [ "${LIST_S3}" = true ]; then
  LIST_DIR="$(dirname "$(readlink -f "$0")")"
  # shellcheck source=scripts/s3-env.sh
  source "${LIST_DIR}/s3-env.sh"
  # shellcheck source=scripts/lib/s3.sh
  source "${LIST_DIR}/lib/s3.sh"
  if ! s3_enabled; then
    echo "❌ list --s3 needs S3_BUCKET and its credentials." >&2
    exit 1
  fi
  S3_ARGS=(ls)
  if [ -n "${FILTER_DB}" ]; then
    S3_ARGS+=(--db "${FILTER_DB}")
  fi
  if ! LISTING="$(s3-sync "${S3_ARGS[@]}")"; then
    echo "❌ Could not list $(s3_location)." >&2
    exit 1
  fi
  # One box per database (keys are <prefix>/<db>/<name>, listed sorted). Columns of
  # `s3-sync ls`: key, bytes (unused here), size, taken, tier.
  TOTAL=0
  CURRENT=""
  while IFS=$'\t' read -r KEY _ SIZE TAKEN TIER; do
    [ -n "${KEY}" ] || continue
    DB="${KEY%/*}"
    DB="${DB##*/}"
    if [ "${DB}" != "${CURRENT}" ]; then
      if [ -n "${CURRENT}" ]; then
        echo "╚══════════════════════════════════════╝"
        echo ""
      fi
      echo "╔══════════════════════════════════════╗"
      echo "║  OFF-SITE ${DB}"
      echo "╠══════════════════════════════════════╣"
      CURRENT="${DB}"
    fi
    printf "║  %-6s  %s  %-8s %s\n" "${SIZE}" "${TAKEN}" "${TIER}" "${KEY}"
    TOTAL=$((TOTAL + 1))
  done <<< "${LISTING}"
  if [ -n "${CURRENT}" ]; then
    echo "╚══════════════════════════════════════╝"
    echo ""
  fi
  echo "${TOTAL} off-site dump(s) in $(s3_location)"
  exit 0
fi

if [ ! -d "${BACKUP_DIR}" ]; then
  echo "❌ Backup directory not found: ${BACKUP_DIR}" >&2
  exit 1
fi

# Cleanup preview mode
if [ "${CLEANUP_PREVIEW}" = true ]; then
  # The real directory of this script: /list.sh and /usr/local/bin/list are symlinks.
  source "$(dirname "$(readlink -f "$0")")/env.sh" 2>/dev/null || true

  echo "════════════════════════════════════════"
  echo "  Cleanup Preview (dry run)"
  echo "════════════════════════════════════════"
  echo ""
  echo "Current retention policy:"
  if [ "${BACKUP_LAYOUT:-period}" = "snapshot" ]; then
    echo "  Last:    newest dump of each database (snapshot layout)"
  else
    echo "  Last:    keep ${BACKUP_KEEP_MINS:-1440} minutes"
  fi
  echo "  Daily:   keep ${BACKUP_KEEP_DAYS:-7} days"
  echo "  Weekly:  keep $((${BACKUP_KEEP_WEEKS:-4} * 7 + 1)) days"
  echo "  Monthly: keep $((${BACKUP_KEEP_MONTHS:-6} * 31 + 1)) days"
  echo ""

  TOTAL_DELETE=0
  TOTAL_SIZE=0

  KEEP_MINS="${BACKUP_KEEP_MINS:-1440}"
  KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
  KEEP_WEEKS=$(( (${BACKUP_KEEP_WEEKS:-4}) * 7 + 1 ))
  KEEP_MONTHS=$(( (${BACKUP_KEEP_MONTHS:-6}) * 31 + 1 ))

  SUFFIX="${BACKUP_SUFFIX:-.sql.gz}"
  if [ -n "${BACKUP_ENCRYPTION_KEY}" ]; then
    SUFFIX="${SUFFIX}.gpg"
  fi

  # Check each slot
  SLOT_SPECS=("daily:mtime:${KEEP_DAYS}" "weekly:mtime:${KEEP_WEEKS}" "monthly:mtime:${KEEP_MONTHS}")
  if [ "${BACKUP_LAYOUT:-period}" != "snapshot" ]; then
    SLOT_SPECS=("last:mmin:${KEEP_MINS}" "${SLOT_SPECS[@]}")
  fi
  for SLOT_INFO in "${SLOT_SPECS[@]}"; do
    SLOT=$(echo "${SLOT_INFO}" | cut -d: -f1)
    TIME_FLAG=$(echo "${SLOT_INFO}" | cut -d: -f2)
    TIME_VAL=$(echo "${SLOT_INFO}" | cut -d: -f3)
    SLOT_DIR="${BACKUP_DIR}/${SLOT}"
    [ ! -d "${SLOT_DIR}" ] && continue

    FILES=$(find "${SLOT_DIR}" -maxdepth 1 -mindepth 1 ! -name '.*' ! -name '*-latest*' -name "*${SUFFIX}" -"${TIME_FLAG}" "+${TIME_VAL}" 2>/dev/null)
    [ -z "${FILES}" ] && continue

    echo "Would delete from ${SLOT}/:"
    while IFS= read -r FILEPATH; do
      [ -z "${FILEPATH}" ] && continue
      SIZE=$(du -h "${FILEPATH}" 2>/dev/null | cut -f1)
      MOD_DATE=$(date -r "${FILEPATH}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
      echo "  🗑  ${SIZE}  ${MOD_DATE}  $(basename "${FILEPATH}")"
      TOTAL_DELETE=$((TOTAL_DELETE + 1))
    done <<< "${FILES}"
    echo ""
  done

  if [ "${TOTAL_DELETE}" -eq 0 ]; then
    echo "Nothing to clean up. All backups are within retention policy."
  else
    echo "────────────────────────────────────────"
    echo "Total: ${TOTAL_DELETE} files would be deleted"
    echo "────────────────────────────────────────"
  fi
  exit 0
fi

# Normal listing mode
TOTAL=0

for SLOT in last daily weekly monthly; do
  SLOT_DIR="${BACKUP_DIR}/${SLOT}"
  [ ! -d "${SLOT_DIR}" ] && continue

  FILES=$(find "${SLOT_DIR}" -maxdepth 1 -mindepth 1 ! -name '.*' \( -type f -o -type l -o -type d \) 2>/dev/null | sort -r)
  [ -z "${FILES}" ] && continue

  if [ -n "${FILTER_DB}" ]; then
    FILES=$(echo "${FILES}" | grep "/${FILTER_DB}-" || true)
    [ -z "${FILES}" ] && continue
  fi

  echo "╔══════════════════════════════════════╗"
  echo "║  ${SLOT^^}$(printf '%*s' $((35 - ${#SLOT})) '')║"
  echo "╠══════════════════════════════════════╣"

  while IFS= read -r FILEPATH; do
    [ -z "${FILEPATH}" ] && continue
    FILENAME=$(basename "${FILEPATH}")

    if [ -d "${FILEPATH}" ]; then
      SIZE=$(du -sh "${FILEPATH}" 2>/dev/null | cut -f1)
    else
      SIZE=$(du -h "${FILEPATH}" 2>/dev/null | cut -f1)
    fi

    MOD_DATE=$(date -r "${FILEPATH}" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "${FILEPATH}" 2>/dev/null | cut -d. -f1 || echo "unknown")

    INDICATORS=""
    if [[ "${FILENAME}" == *"-latest"* ]]; then
      INDICATORS=" [latest]"
    fi
    if [[ "${FILENAME}" == *.gpg ]]; then
      INDICATORS="${INDICATORS} [encrypted]"
    fi

    printf "║  %-6s  %s  %s%s\n" "${SIZE}" "${MOD_DATE}" "${FILENAME}" "${INDICATORS}"
    TOTAL=$((TOTAL + 1))
  done <<< "${FILES}"

  echo "╚══════════════════════════════════════╝"
  echo ""
done

if [ "${TOTAL}" -eq 0 ]; then
  if [ -n "${FILTER_DB}" ]; then
    echo "No backups found for database: ${FILTER_DB}"
  else
    echo "No backups found in ${BACKUP_DIR}"
  fi
fi

# Disk usage summary
echo "Disk usage: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1) total"
AVAILABLE=$(df -h "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "${AVAILABLE}" ]; then
  echo "Available:  ${AVAILABLE}"
fi
