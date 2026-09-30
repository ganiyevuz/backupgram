# Prometheus metrics, sourced by backup.sh. Rendered after each run from the files
# on disk (so they survive restarts, and stop advancing when the container is dead)
# plus this run's results, then written for node-exporter's textfile collector
# (METRICS_TEXTFILE_DIR) and/or for backupgram-api's GET /metrics (METRICS_ENABLE).

# Escapes a label value for the text exposition format.
prom_escape() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

# "<database> <mtime> <bytes>" for the newest stamped entry of each database in last/.
newest_per_database() {
  local f n
  for f in "${BACKUP_DIR}/last/"*; do
    [ -e "${f}" ] || continue
    n="$(basename "${f}")"
    case "${n}" in
      *-latest*) continue ;;
    esac
    [[ "${n}" =~ ^(.+)-[0-9]{8}-[0-9]{6}\. ]] || continue
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "$(stat -c %Y "${f}")" "$(get_size_bytes "${f}")"
  done | sort -k1,1 -k2,2nr | awk '!seen[$1]++'
}

# Prints one gauge's HELP and TYPE lines.
prom_header() {
  echo "# HELP $1 $2"
  echo "# TYPE $1 gauge"
}

# The metrics of a run that ends with exit code RC.
render_metrics() {
  local rc="$1" now l newest db mtime size slot count kb
  now="$(date +%s)"
  l="project=\"$(prom_escape "${PROJECT_NAME}")\""
  newest="$(newest_per_database)"

  prom_header backupgram_backup_last_timestamp_seconds "When the newest dump of the database in last/ was written (Unix time)."
  while read -r db mtime size; do
    [ -n "${db}" ] && echo "backupgram_backup_last_timestamp_seconds{${l},database=\"$(prom_escape "${db}")\"} ${mtime}"
  done <<< "${newest}"
  prom_header backupgram_backup_last_size_bytes "Size of the newest dump of the database in last/."
  while read -r db mtime size; do
    [ -n "${db}" ] && echo "backupgram_backup_last_size_bytes{${l},database=\"$(prom_escape "${db}")\"} ${size}"
  done <<< "${newest}"

  prom_header backupgram_backup_success "1 when the database's dump succeeded in the most recent run, else 0."
  while read -r db; do
    [ -n "${db}" ] && echo "backupgram_backup_success{${l},database=\"$(prom_escape "${db}")\"} ${DB_OK[${db}]}"
  done < <(printf '%s\n' "${!DB_OK[@]}" | sort)
  prom_header backupgram_backup_duration_seconds "How long the database's dump took in the most recent run."
  while read -r db; do
    [ -n "${db}" ] && echo "backupgram_backup_duration_seconds{${l},database=\"$(prom_escape "${db}")\"} ${DB_SECONDS[${db}]}"
  done < <(printf '%s\n' "${!DB_SECONDS[@]}" | sort)

  prom_header backupgram_run_timestamp_seconds "When the most recent run finished (Unix time)."
  echo "backupgram_run_timestamp_seconds{${l}} ${now}"
  prom_header backupgram_run_duration_seconds "How long the most recent run took."
  echo "backupgram_run_duration_seconds{${l}} $((now - BACKUP_START_TIME))"
  prom_header backupgram_run_success "1 when the most recent run exited 0, else 0."
  if [ "${rc}" = "0" ]; then
    echo "backupgram_run_success{${l}} 1"
  else
    echo "backupgram_run_success{${l}} 0"
  fi
  prom_header backupgram_run_databases "Databases in the most recent run, by result."
  echo "backupgram_run_databases{${l},result=\"ok\"} ${BACKUP_SUCCESS:-0}"
  echo "backupgram_run_databases{${l},result=\"failed\"} ${BACKUP_FAILED:-0}"
  echo "backupgram_run_databases{${l},result=\"skipped\"} $(wc -w <<< "${DISCOVER_SKIPPED}" | tr -d ' ')"

  prom_header backupgram_backup_files "Backups kept per folder (-latest links and dot files excluded)."
  for slot in last daily weekly monthly; do
    count="$(find "${BACKUP_DIR}/${slot}" -maxdepth 1 -mindepth 1 ! -name '.*' ! -name '*-latest*' 2>/dev/null | wc -l | tr -d ' ')"
    echo "backupgram_backup_files{${l},slot=\"${slot}\"} ${count}"
  done
  prom_header backupgram_disk_available_bytes "Free space on the filesystem holding BACKUP_DIR."
  kb="$(df -Pk "${BACKUP_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"
  echo "backupgram_disk_available_bytes{${l}} $(( ${kb:-0} * 1024 ))"
}

# The textfile's name: backupgram.prom, or backupgram-<project>.prom (sanitised).
metrics_textfile_name() {
  if [ -n "${PROJECT_NAME}" ]; then
    printf 'backupgram-%s.prom' "$(printf '%s' "${PROJECT_NAME}" | tr -c 'A-Za-z0-9_-' '_')"
  else
    printf 'backupgram.prom'
  fi
}

# Writes DEST through a temp file + rename, so a reader never sees half a file.
# World-readable: node-exporter usually runs as nobody.
write_file_atomic() {
  local dest="$1" tmp
  tmp="$(dirname "${dest}")/.$(basename "${dest}").tmp"
  printf '%s\n' "$2" > "${tmp}" || return 1
  chmod 0644 "${tmp}" || return 1
  mv "${tmp}" "${dest}"
}

# Writes the metrics of a run ending with exit code RC where they are wanted.
write_metrics() {
  local body
  if [ "${METRICS_ENABLE}" != "TRUE" ] && [ -z "${METRICS_TEXTFILE_DIR}" ]; then
    return 0
  fi
  body="$(render_metrics "$1")"
  if [ "${METRICS_ENABLE}" = "TRUE" ]; then
    write_file_atomic "${BACKUP_DIR}/.metrics.prom" "${body}" || return 1
  fi
  if [ -n "${METRICS_TEXTFILE_DIR}" ]; then
    write_file_atomic "${METRICS_TEXTFILE_DIR}/$(metrics_textfile_name)" "${body}" || return 1
  fi
}
