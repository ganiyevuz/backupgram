# shellcheck shell=bash
# Off-site copies, sourced by backup.sh, restore.sh, list.sh and s3-sync.sh: runs
# s3-sync and turns its status file into metrics. The settings come from s3-env.sh;
# prom_escape, prom_header and write_file_atomic come from lib/metrics.sh.

S3_STATUS_FILE="${S3_STATUS_FILE:-/tmp/backupgram-s3-status}"

s3_enabled() {
  [ -n "${S3_BUCKET}" ]
}

# s3://bucket[/prefix], for messages.
s3_location() {
  local p="${S3_PREFIX#/}"
  p="${p%/}"
  if [ -n "${p}" ]; then
    printf 's3://%s/%s' "${S3_BUCKET}" "${p}"
  else
    printf 's3://%s' "${S3_BUCKET}"
  fi
}

# Writes the status of a failed sync that s3-sync did not record itself.
s3_status_failed() {
  printf 'result failed %s\n' "$(date +%s)" > "${S3_STATUS_FILE}"
}

# One sync: upload what the bucket lacks, prune it, write the status file. 0 = ok.
# A sync that ends without writing its status (killed, or it could not) leaves a failed one,
# as does a run whose S3 settings are invalid (s3-env.sh), which skips the sync.
s3_sync() {
  rm -f "${S3_STATUS_FILE}"
  if [ "${S3_SETTINGS_INVALID}" = "TRUE" ]; then
    echo "⚠️ off-site: skipped, an S3 setting is invalid (see above). The local backup is not affected." >&2
    s3_status_failed || true
    return 1
  fi
  if s3-sync sync --dir "${BACKUP_DIR}" --status "${S3_STATUS_FILE}"; then
    return 0
  fi
  if [ ! -e "${S3_STATUS_FILE}" ]; then
    s3_status_failed || true
  fi
  return 1
}

# The off-site metrics, from the status file; none before this container's first sync (an
# early abort then reports no off-site state rather than a failed sync). Each family's
# HELP/TYPE comes right before its samples.
render_offsite_metrics() {
  local l result="" finished="" databases="" newest="" db stamp bytes
  [ -r "${S3_STATUS_FILE}" ] || return 0
  l="project=\"$(prom_escape "${PROJECT_NAME}")\""
  read -r _ result finished < <(grep '^result ' "${S3_STATUS_FILE}" || true) || true
  read -r _ databases < <(grep '^databases ' "${S3_STATUS_FILE}" || true) || true
  newest="$(grep '^newest ' "${S3_STATUS_FILE}" || true)"
  prom_header backupgram_offsite_last_timestamp_seconds "When the newest off-site dump of the database was taken (Unix time)."
  while read -r _ db stamp bytes _; do
    if [ -n "${db}" ]; then
      echo "backupgram_offsite_last_timestamp_seconds{${l},database=\"$(prom_escape "${db}")\"} ${stamp}"
    fi
  done <<< "${newest}"
  prom_header backupgram_offsite_last_size_bytes "Size of the newest off-site dump of the database."
  while read -r _ db stamp bytes _; do
    if [ -n "${db}" ]; then
      echo "backupgram_offsite_last_size_bytes{${l},database=\"$(prom_escape "${db}")\"} ${bytes}"
    fi
  done <<< "${newest}"
  prom_header backupgram_offsite_sync_success "1 when the last off-site sync succeeded, else 0."
  if [ "${result}" = "ok" ]; then
    echo "backupgram_offsite_sync_success{${l}} 1"
  else
    echo "backupgram_offsite_sync_success{${l}} 0"
  fi
  prom_header backupgram_offsite_sync_timestamp_seconds "When the last off-site sync finished (Unix time)."
  echo "backupgram_offsite_sync_timestamp_seconds{${l}} ${finished:-$(date +%s)}"
  # 0 means an empty or wrong folder: nothing reaches the bucket (BackupgramOffsiteNoDatabases).
  if [ -n "${databases}" ]; then
    prom_header backupgram_offsite_databases "Databases with a dump in last/, which the off-site sync copies."
    echo "backupgram_offsite_databases{${l}} ${databases}"
  fi
}

# Uploader mode: the off-site metrics alone, to METRICS_TEXTFILE_DIR as
# backupgram-offsite.prom or backupgram-offsite-<project>.prom (beside the backup's own file).
write_offsite_metrics() {
  [ -n "${METRICS_TEXTFILE_DIR}" ] || return 0
  write_file_atomic "${METRICS_TEXTFILE_DIR}/$(metrics_textfile_name | sed 's/^backupgram/backupgram-offsite/')" \
    "$(render_offsite_metrics)"
}
