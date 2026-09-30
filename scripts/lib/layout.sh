# Backup folder layout, sourced by backup.sh: preparing the folders, linking a
# finished dump into daily/weekly/monthly, and retention. Uses BACKUP_DIR, the
# run variables (STAMP, RUN_*) and the KEEP_* thresholds computed in env.sh.

prepare_backup_dir() {
  mkdir -p "${BACKUP_DIR}/last" "${BACKUP_DIR}/daily" "${BACKUP_DIR}/weekly" "${BACKUP_DIR}/monthly"
}

# Puts SRC at DEST: a hard link for a file (replacing DEST), a fresh copy for a
# directory dump, which cannot be hard-linked.
place_copy() {
  local src="$1" dest="$2"
  if [ -d "${src}" ]; then
    rm -rf "${dest}" || return 1
    cp -r "${src}" "${dest}" || return 1
  else
    ln -f "${src}" "${dest}" || return 1
  fi
}

# Points <slot>/<db>-latest<suffix> at <slot>/<name>, per BACKUP_LATEST_TYPE
# (symlink: a relative link; hardlink: the same inode; none: nothing).
update_latest() {
  local slot="$1" name="$2" db="$3" suffix="$4" dir latest
  case "${BACKUP_LATEST_TYPE}" in
    symlink | hardlink) ;;
    *) return 0 ;;
  esac
  dir="${BACKUP_DIR}/${slot}"
  latest="${dir}/${db}-latest${suffix}"
  if [ -d "${dir}/${name}" ]; then
    rm -rf "${latest}" || return 1
    cp -r "${dir}/${name}" "${latest}" || return 1
  elif [ "${BACKUP_LATEST_TYPE}" = "symlink" ]; then
    ln -sfn "${name}" "${latest}" || return 1
  else
    ln -f "${dir}/${name}" "${latest}" || return 1
  fi
}

# Links the finished dump FILE (last/<db>-<STAMP><suffix>) into the other folders.
# period layout: one file per day/week/month, replaced by every run of that period.
link_into_slots() {
  local db="$1" file="$2" name suffix daily weekly monthly
  name="$(basename "${file}")"
  suffix="${name#"${db}-${STAMP}"}"
  daily="${db}-${RUN_DATE}${suffix}"
  weekly="${db}-${RUN_WEEK}${suffix}"
  monthly="${db}-${RUN_MONTH}${suffix}"
  place_copy "${file}" "${BACKUP_DIR}/daily/${daily}" || return 1
  place_copy "${file}" "${BACKUP_DIR}/weekly/${weekly}" || return 1
  place_copy "${file}" "${BACKUP_DIR}/monthly/${monthly}" || return 1
  update_latest last "${name}" "${db}" "${suffix}" || return 1
  update_latest daily "${daily}" "${db}" "${suffix}" || return 1
  update_latest weekly "${weekly}" "${db}" "${suffix}" || return 1
  update_latest monthly "${monthly}" "${db}" "${suffix}" || return 1
}

# Deletes entries of one folder older than AGE (find TEST: -mtime days or -mmin
# minutes) whose names end in SUFFIX. -latest links and dot files are never touched.
prune_slot() {
  local slot="$1" test="$2" age="$3" suffix="$4"
  [ -n "${age}" ] || return 0
  find "${BACKUP_DIR}/${slot}" -maxdepth 1 -mindepth 1 ! -name '.*' ! -name '*-latest*' \
    -name "*${suffix}" "${test}" "+${age}" -exec rm -rf '{}' +
}

# Retention over every backup file in each folder, not only this run's databases:
# a dropped or renamed database's copies age out like the others.
apply_retention() {
  local suffix="$1"
  prune_slot daily -mtime "${KEEP_DAYS}" "${suffix}"
  prune_slot weekly -mtime "${KEEP_WEEKS}" "${suffix}"
  prune_slot monthly -mtime "${KEEP_MONTHS}" "${suffix}"
  prune_slot last -mmin "${KEEP_MINS}" "${suffix}"
}
