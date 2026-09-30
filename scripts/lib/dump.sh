# Dumping, sourced by backup.sh: format detection, the passphrase file, the
# streaming dump into a .part file, and its verification. Nothing unencrypted is
# written when encryption is on, and the key never appears on a command line.

# Human-readable size of a file or directory.
get_size() {
  if [ -d "$1" ]; then
    du -sh "$1" 2>/dev/null | cut -f1
  elif [ -f "$1" ]; then
    du -h "$1" 2>/dev/null | cut -f1
  else
    echo "0"
  fi
}

# Raw byte size (POSIX-compatible, works on Alpine/BusyBox).
get_size_bytes() {
  if [ -d "$1" ]; then
    local kb
    kb=$(du -sk "$1" 2>/dev/null | cut -f1)
    echo $((kb * 1024))
  elif [ -f "$1" ]; then
    wc -c < "$1" 2>/dev/null | tr -d ' '
  else
    echo "0"
  fi
}

# Reads POSTGRES_EXTRA_OPTS once. Sets DUMP_FORMAT (plain|custom|tar|directory|cluster),
# DUMP_CODEC (gzip|none|other: how the dump's bytes are compressed) and DUMP_OPTS.
detect_dump_format() {
  local tok prev="" fmt="" comp=""
  set -f
  # shellcheck disable=SC2086
  for tok in ${POSTGRES_EXTRA_OPTS}; do
    case "${prev}" in
      -F | --format) fmt="${tok}" ;;
      -Z | --compress) comp="${tok}" ;;
    esac
    case "${tok}" in
      -F?*) fmt="${tok#-F}" ;;
      --format=*) fmt="${tok#--format=}" ;;
      -Z?*) comp="${tok#-Z}" ;;
      --compress=*) comp="${tok#--compress=}" ;;
    esac
    prev="${tok}"
  done
  set +f

  DUMP_OPTS="${POSTGRES_EXTRA_OPTS}"
  if [ "${POSTGRES_CLUSTER}" = "TRUE" ]; then
    DUMP_FORMAT="cluster"
    DUMP_CODEC="gzip"      # pg_dumpall output is always piped through gzip
    return 0
  fi
  case "${fmt}" in
    c | custom) DUMP_FORMAT="custom" ;;
    t | tar) DUMP_FORMAT="tar" ;;
    d | directory) DUMP_FORMAT="directory" ;;
    *) DUMP_FORMAT="plain" ;;
  esac
  case "${DUMP_FORMAT}:${comp}" in
    tar:*) DUMP_CODEC="none" ;;                        # pg_dump never compresses tar
    *:0 | *:none | *:*level=0) DUMP_CODEC="none" ;;
    plain:) DUMP_CODEC="none" ;;                       # plain is uncompressed unless asked
    plain:[1-9] | plain:gzip*) DUMP_CODEC="gzip" ;;
    *) DUMP_CODEC="other" ;;                           # custom/directory compress by default; lz4/zstd
  esac
  if [ "${DUMP_FORMAT}" = "directory" ]; then
    echo "📂 Directory format (-Fd) detected. Removing compression option..."
    DUMP_OPTS=$(echo "${POSTGRES_EXTRA_OPTS}" | sed 's/-Z[0-9]*//g' | xargs)
  fi
}

# Writes BACKUP_ENCRYPTION_KEY to a private temp file (removed on exit) for
# --passphrase-file. KEYFILE stays empty when encryption is off.
prepare_keyfile() {
  KEYFILE=""
  [ -n "${BACKUP_ENCRYPTION_KEY}" ] || return 0
  KEYFILE="$(mktemp)"
  trap 'rm -f "${KEYFILE}"' EXIT
  printf '%s' "${BACKUP_ENCRYPTION_KEY}" > "${KEYFILE}"
}

# True when this run's artifacts are GPG-encrypted (directory dumps never are).
dump_encrypted() {
  [ -n "${KEYFILE}" ] && [ "${DUMP_FORMAT}" != "directory" ]
}

final_suffix() {
  if dump_encrypted; then
    printf '%s' "${BACKUP_SUFFIX}.gpg"
  else
    printf '%s' "${BACKUP_SUFFIX}"
  fi
}

final_name() {
  printf '%s' "$1-${STAMP}$(final_suffix)"
}

# stdin → encrypted file $1. GPG compression is off when the dump is compressed already.
gpg_encrypt_to() {
  local args=(--batch --yes --no-symkey-cache --symmetric --cipher-algo AES256 --passphrase-file "${KEYFILE}")
  if [ "${DUMP_CODEC}" != "none" ]; then
    args+=(--compress-algo none)
  fi
  gpg "${args[@]}" -o "$1"
}

# Encrypted file $1 → stdout. GPG's exit status reports the integrity check.
gpg_decrypt() {
  gpg --batch --quiet --no-symkey-cache --decrypt --passphrase-file "${KEYFILE}" "$1"
}

# Dumps one database (or the cluster) into PART. Every stage of a pipe must succeed.
dump_to_part() {
  local db="$1" part="$2" rc=0
  set -f
  case "${DUMP_FORMAT}" in
    cluster)
      if dump_encrypted; then
        # shellcheck disable=SC2086
        pg_dumpall ${DUMP_OPTS} | gzip | gpg_encrypt_to "${part}" || rc=1
      else
        # shellcheck disable=SC2086
        pg_dumpall ${DUMP_OPTS} | gzip > "${part}" || rc=1
      fi
      ;;
    directory)
      # shellcheck disable=SC2086
      pg_dump -d "${db}" -f "${part}" ${DUMP_OPTS} ${EXCLUDE_ARGS} || rc=1
      ;;
    *)
      if dump_encrypted; then
        # shellcheck disable=SC2086
        pg_dump -d "${db}" ${DUMP_OPTS} ${EXCLUDE_ARGS} | gpg_encrypt_to "${part}" || rc=1
      else
        # shellcheck disable=SC2086
        pg_dump -d "${db}" -f "${part}" ${DUMP_OPTS} ${EXCLUDE_ARGS} || rc=1
      fi
      ;;
  esac
  set +f
  return "${rc}"
}

# Rejects an empty dump, and one below BACKUP_MIN_BYTES.
check_part_size() {
  local db="$1" part="$2" size
  size="$(get_size_bytes "${part}")"
  if [ "${size:-0}" -le 0 ]; then
    echo "❌ ${db}: dump is empty. Previous dump kept." >&2
    return 1
  fi
  if [ "${size}" -lt "${BACKUP_MIN_BYTES:-0}" ]; then
    echo "❌ ${db}: dump is ${size} bytes, below BACKUP_MIN_BYTES=${BACKUP_MIN_BYTES}. Previous dump kept." >&2
    return 1
  fi
}

# Reads the dump back in full, through the decryption pipe when encrypted.
# `cat` drains what pg_restore leaves unread, so gpg always reaches its integrity check.
verify_part() {
  local part="$1"
  case "${DUMP_FORMAT}" in
    directory)
      pg_restore -f /dev/null "${part}"
      ;;
    custom | tar)
      if dump_encrypted; then
        gpg_decrypt "${part}" | { pg_restore -f /dev/null && cat >/dev/null; }
      else
        pg_restore -f /dev/null "${part}"
      fi
      ;;
    *)
      if [ "${DUMP_CODEC}" = "gzip" ]; then
        if dump_encrypted; then
          gpg_decrypt "${part}" | gunzip -c >/dev/null
        else
          gunzip -c "${part}" >/dev/null
        fi
      elif dump_encrypted; then
        gpg_decrypt "${part}" >/dev/null
      fi
      ;;
  esac
}
