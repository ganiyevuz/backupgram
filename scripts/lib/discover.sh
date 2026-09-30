# Auto-discovery, sourced by backup.sh: which databases this run backs up.

# True when NAME matches one of the POSTGRES_DB_INCLUDE globs, or the list is empty.
db_included() {
  local pat pats
  [ -n "${POSTGRES_DB_INCLUDE}" ] || return 0
  set -f
  # shellcheck disable=SC2206
  pats=(${POSTGRES_DB_INCLUDE//,/ })
  set +f
  for pat in "${pats[@]}"; do
    # shellcheck disable=SC2254
    case "$1" in
      ${pat}) return 0 ;;
    esac
  done
  return 1
}

# True when NAME is listed exactly in POSTGRES_DB_EXCLUDE (comma-separated).
db_excluded() {
  local ex exs
  set -f
  # shellcheck disable=SC2206
  exs=(${POSTGRES_DB_EXCLUDE//,/ })
  set +f
  for ex in "${exs[@]}"; do
    if [ "$1" = "${ex}" ]; then
      return 0
    fi
  done
  return 1
}

# Sets POSTGRES_DBS (space-separated) and DISCOVER_SKIPPED (databases this login may
# not CONNECT to — logged and skipped, not failed). Non-zero when the listing fails
# or nothing is left to back up: never "backed up nothing, exit 0".
discover_databases() {
  local listing name can
  POSTGRES_DBS=""
  DISCOVER_SKIPPED=""
  echo "🔍 Auto-discovering databases..."
  # Constant SQL: include/exclude are applied in Bash, so user text never reaches SQL.
  if ! listing=$(psql -X -d postgres -tA -F '|' -c \
    "SELECT datname, has_database_privilege(datname, 'CONNECT') FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY datname"); then
    echo "❌ Error: database auto-discovery query failed. Aborting." >&2
    return 1
  fi
  while IFS='|' read -r name can; do
    [ -n "${name}" ] || continue
    db_included "${name}" || continue
    if db_excluded "${name}"; then
      continue
    fi
    if [ "${can}" != "t" ]; then
      echo "⏭️ ${name} skipped: no CONNECT privilege"
      DISCOVER_SKIPPED="${DISCOVER_SKIPPED:+${DISCOVER_SKIPPED} }${name}"
      continue
    fi
    POSTGRES_DBS="${POSTGRES_DBS:+${POSTGRES_DBS} }${name}"
  done <<< "${listing}"
  if [ -z "${POSTGRES_DBS}" ]; then
    echo "❌ Auto-discover found no databases to back up (after exclusions). Aborting." >&2
    return 1
  fi
  echo "✅ Auto-discovered $(wc -w <<< "${POSTGRES_DBS}" | tr -d ' ') database(s): ${POSTGRES_DBS}"
}
