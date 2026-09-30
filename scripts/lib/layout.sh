# Backup folder layout, sourced by backup.sh: preparing the folders, linking a
# finished dump into daily/weekly/monthly, and retention. Uses BACKUP_DIR, the
# run variables (STAMP, RUN_*) and the KEEP_* thresholds computed in env.sh.

# Creates the folders (group BACKUP_GID, setgid 2750, files 0640 when set) and
# removes .part files a killed run left behind. Runs only with the lock held, so
# no live run's .part can be removed.
prepare_backup_dir() {
  local slots=("${BACKUP_DIR}/last" "${BACKUP_DIR}/daily" "${BACKUP_DIR}/weekly" "${BACKUP_DIR}/monthly")
  if [ -n "${BACKUP_GID}" ]; then
    umask 027
  fi
  mkdir -p "${slots[@]}"
  if [ -n "${BACKUP_GID}" ]; then
    chgrp "${BACKUP_GID}" "${BACKUP_DIR}" "${slots[@]}"
    chmod 2750 "${BACKUP_DIR}" "${slots[@]}"
  fi
  find "${BACKUP_DIR}/last" -maxdepth 1 -mindepth 1 -name '.*.part' -exec rm -rf '{}' +
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

# Prints the database of a stamped name <db>-YYYYMMDD-HHMMSS<suffix>; prints nothing
# for any other name. The stamp is always the last 15 characters before the suffix, so
# a database name may itself contain hyphens and digits (keep-20260101). Never fails:
# it runs inside $(…), where set -E hands it the ERR trap.
stamped_db_name() {
  local name="$1" suffix="$2" base
  [[ "${name}" == *"${suffix}" ]] || return 0
  base="${name%"${suffix}"}"
  [[ "${base}" =~ ^(.+)-[0-9]{8}-[0-9]{6}$ ]] || return 0
  printf '%s' "${BASH_REMATCH[1]}"
}

# Removes DB's older dumps from last/, now that KEEP is in place. Names that are not
# stamped (the -latest link) give an empty database name and are left alone.
prune_last_for_db() {
  local db="$1" keep="$2" suffix="$3" f n
  for f in "${BACKUP_DIR}/last/"*; do
    [ -e "${f}" ] || continue
    n="$(basename "${f}")"
    [ "${n}" != "${keep}" ] || continue
    if [ "$(stamped_db_name "${n}" "${suffix}")" = "${db}" ]; then
      rm -rf "${f}" || return 1
    fi
  done
}

# snapshot layout: every folder holds the run's own timestamped file (a hard link;
# a copy for directory dumps). daily/ gets every run, weekly/ Sunday's run, monthly/
# the 1st's; last/ keeps only the newest dump of the database.
link_snapshot() {
  local db="$1" file="$2" name="$3" suffix="$4" slot slots=(daily)
  if [ "${RUN_WEEKDAY}" = "7" ]; then
    slots+=(weekly)
  fi
  if [ "${RUN_DAY}" = "01" ]; then
    slots+=(monthly)
  fi
  update_latest last "${name}" "${db}" "${suffix}" || return 1
  for slot in "${slots[@]}"; do
    place_copy "${file}" "${BACKUP_DIR}/${slot}/${name}" || return 1
    update_latest "${slot}" "${name}" "${db}" "${suffix}" || return 1
  done
  prune_last_for_db "${db}" "${name}" "${suffix}"
}

# Links the finished dump FILE (last/<db>-<STAMP><suffix>) into the other folders.
# period layout (default): one file per day/week/month, replaced by every run of that
# period; snapshot: see link_snapshot.
link_into_slots() {
  local db="$1" file="$2" name suffix daily weekly monthly
  name="$(basename "${file}")"
  suffix="${name#"${db}-${STAMP}"}"
  if [ "${BACKUP_LAYOUT}" = "snapshot" ]; then
    link_snapshot "${db}" "${file}" "${name}" "${suffix}"
    return
  fi
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

# NAME with the find -name glob characters ([ ] * ? \) escaped, so it matches only itself.
glob_escape() {
  printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'
}

# Deletes entries of one folder older than AGE (find TEST: -mtime days or -mmin
# minutes) whose names end in SUFFIX. -latest links and dot files are never touched.
# The remaining arguments are extra find tests (the failed databases' exclusions).
prune_slot() {
  local slot="$1" test="$2" age="$3" suffix="$4"
  shift 4
  [ -n "${age}" ] || return 0
  find "${BACKUP_DIR}/${slot}" -maxdepth 1 -mindepth 1 ! -name '.*' ! -name '*-latest*' "$@" \
    -name "*${suffix}" "${test}" "+${age}" -exec rm -rf '{}' +
}

# Retention over every backup file in each folder, not only this run's databases:
# a dropped or renamed database's copies age out like the others. The databases
# given after SUFFIX failed in this run: their copies (<db>-<digit>…) are the last
# good ones and are kept, in every folder. Non-zero when a folder could not be pruned.
apply_retention() {
  local suffix="$1" db keep=() rc=0
  shift
  for db in "$@"; do
    keep+=(! -name "$(glob_escape "${db}")-[0-9]*")
  done
  prune_slot daily -mtime "${KEEP_DAYS}" "${suffix}" "${keep[@]}" || rc=1
  prune_slot weekly -mtime "${KEEP_WEEKS}" "${suffix}" "${keep[@]}" || rc=1
  prune_slot monthly -mtime "${KEEP_MONTHS}" "${suffix}" "${keep[@]}" || rc=1
  # snapshot: last/ is managed by prune_last_for_db / prune_dropped_databases instead.
  if [ "${BACKUP_LAYOUT}" != "snapshot" ]; then
    prune_slot last -mmin "${KEEP_MINS}" "${suffix}" "${keep[@]}" || rc=1
  fi
  return "${rc}"
}

# snapshot layout: last/ holds the newest dump of each database that still exists.
# A dropped database's dump and its -latest entry (link or copy) leave last/; its
# daily/weekly/monthly links age out normally. If the server cannot be listed,
# nothing is removed. Non-zero only when a removal fails.
prune_dropped_databases() {
  local suffix="$1" existing f n db dropped=""
  [ "${BACKUP_LAYOUT}" = "snapshot" ] || return 0
  [ "${POSTGRES_CLUSTER}" != "TRUE" ] || return 0
  # `|| exit 1` inside the $(…): the failure is handled there, so the ERR trap set -E
  # hands to the substitution never sees it, and the substitution still exits 1.
  if ! existing=$(psql -X -d postgres -tAc "SELECT datname FROM pg_database" || exit 1) || [ -z "${existing}" ]; then
    echo "⚠️ Could not list the server's databases; no dropped database's dump was removed." >&2
    return 0
  fi
  for f in "${BACKUP_DIR}/last/"*; do
    [ -e "${f}" ] || continue
    n="$(basename "${f}")"
    db="$(stamped_db_name "${n}" "${suffix}")"
    [ -n "${db}" ] || continue
    if ! grep -qxF -- "${db}" <<< "${existing}"; then
      rm -rf "${f}" || return 1
      # Once per database, however many of its dumps last/ still held.
      if ! grep -qxF -- "${db}" <<< "${dropped}"; then
        dropped+="${db}"$'\n'
        rm -rf "${BACKUP_DIR}/last/${db}-latest${suffix}" || return 1
        echo "🗑️ ${db} no longer exists: its dump left last/ (daily/weekly/monthly keep theirs)"
      fi
    fi
  done
}
