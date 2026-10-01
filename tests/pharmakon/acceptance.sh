#!/usr/bin/env bash
# Acceptance: the real Alpine image, configured as Pharmakon will run it (spec §12),
# against the Pharmakon-shaped fixture. Walks the checks of Pharmakon's
# docs/backup-container-requirements.md §10 that can run off their servers.
# Usage: tests/pharmakon/acceptance.sh            (builds backupgram-local:18-alpine)
#        BACKUPGRAM_IMAGE=<image> tests/pharmakon/acceptance.sh
#        KEEP=1 …                                  (leave the containers running)
set -Eeo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
COMPOSE=(docker compose -f compose.yml)
KEY="pharmakon acceptance key"

fail() {
  echo "❌ ACCEPTANCE FAIL: $*" >&2
  exit 1
}
ok() {
  echo "✅ $*"
}
in_runner() {
  "${COMPOSE[@]}" exec -T runner bash -c "$1"
}
# Runs the job the way operators do (docker exec … /backup.sh); sets OUT and RC.
run_job() {
  set +e
  OUT="$("${COMPOSE[@]}" exec -T backup /backup.sh 2>&1)"
  RC=$?
  set -e
  printf '%s\n' "${OUT}" | sed 's/^/    │ /'
  ALL_OUT="${ALL_OUT}${OUT}"
}
has() {
  grep -qF -- "$1" <<< "${OUT}" || fail "output lacks: $1"
}

if [ "${KEEP:-0}" != "1" ]; then
  trap '"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true' EXIT
fi
if [ -z "${BACKUPGRAM_IMAGE}" ]; then
  (cd "${REPO}" && docker buildx bake alpine-latest \
    --set alpine-latest.tags=backupgram-local:18-alpine \
    --set "alpine-latest.platform=linux/$(docker version -f '{{.Server.Arch}}')" --load)
fi
"${COMPOSE[@]}" up -d --build --wait db runner s3
"${COMPOSE[@]}" up -d backup uploader
in_runner "bash tests/pharmakon/fixture.sh"
ALL_OUT=""

# §10.1 — one run by hand: every database gets a last/ file, daily/ links it.
run_job
[ "${RC}" = "0" ] || fail "first run exited ${RC}"
has "⏭️ pharmacy_broken skipped: no CONNECT privilege"
# shellcheck disable=SC2016  # expanded by the runner's bash, not here
in_runner '
  set -e
  cd /backups
  for db in control pharmacy_alpha pharmacy_beta; do
    f=$(find last -maxdepth 1 -name "${db}-*.dump.gpg")
    [ "$(echo "$f" | wc -l)" = 1 ] && [ -n "$f" ] || { echo "last/ for ${db}: $f"; exit 1; }
    echo "$(basename "$f")" | grep -qE "^${db}-[0-9]{8}-[0-9]{6}\.dump\.gpg$" || { echo "bad name $f"; exit 1; }
    [ "$(stat -c %i "$f")" = "$(stat -c %i "daily/$(basename "$f")")" ] || { echo "daily/ is not a hard link of $f"; exit 1; }
  done
  [ -z "$(find last -name "pharmacy_broken-*" -o -name "analytics-*" -o -name "*-latest*")" ]
  for d in . last daily weekly monthly; do [ "$(stat -c "%a %g" "$d")" = "2750 1000" ] || { echo "$d: $(stat -c "%a %g" "$d")"; exit 1; }; done
  [ "$(stat -c "%a %g" manual)" = "2770 1000" ] || { echo "manual: $(stat -c "%a %g" manual)"; exit 1; }
  for f in last/*.dump.gpg; do [ "$(stat -c "%a %g" "$f")" = "640 1000" ] || { echo "$f: $(stat -c "%a %g" "$f")"; exit 1; }; done
' || fail "§10.1 layout, names, links or permissions"
ok "§10.1 one run: control, pharmacy_alpha, pharmacy_beta in last/ + daily/, names, 2750/2770/0640 group 1000"

# §10.2 — backup-stats reads the newest file per database in last/ (same regex); metrics too.
# shellcheck disable=SC2016  # expanded by the runner's bash, not here
in_runner '
  set -e
  n=$(ls -t /backups/last | grep -E -- "-[0-9]{8}-[0-9]{6}\." | sed -E "s/-[0-9]{8}-[0-9]{6}\..*$//" | sort -u | wc -l)
  [ "$n" = 3 ] || { echo "backup-stats would see $n databases"; exit 1; }
  promtool check metrics < /textfile/backupgram-platform-test.prom
  grep -qx "backupgram_run_databases{project=\"platform-test\",result=\"skipped\"} 1" /textfile/backupgram-platform-test.prom
' || fail "§10.2 backup-stats view / metrics"
ok "§10.2 backup-stats sees 3 databases; metrics pass promtool"

# §10.3 — a branch restore from a dump the new container wrote (backup-runner's commands).
in_runner "
  set -e
  f=\$(ls /backups/last/pharmacy_alpha-*.dump.gpg)
  k=\$(mktemp); printf '%s' '${KEY}' > \"\$k\"
  export PGHOST=db PGPASSWORD=svc_pw
  psql -X -q -U svc_control_api -d pharmacy_alpha -c 'ALTER SCHEMA br01 RENAME TO br01_before_20261001120000' -c 'CREATE SCHEMA br01'
  gpg --batch --quiet --no-symkey-cache --decrypt --passphrase-file \"\$k\" < \"\$f\" \
    | pg_restore -U svc_control_api -d pharmacy_alpha -n br01 --no-owner --no-privileges --single-transaction --exit-on-error
  [ \"\$(psql -X -tA -U svc_control_api -d pharmacy_alpha -c 'SELECT count(*) FROM br01.otdel')\" = 50 ]
" || fail "§10.3 branch restore"
ok "§10.3 br01 restored alone from the image's dump"

# §10.4 — RLS table without backup_reads_all: that database fails, its old dump stays.
before=$(in_runner 'stat -c %i /backups/last/pharmacy_beta-*.dump.gpg')
in_runner "PGHOST=db PGPASSWORD=svc_pw psql -X -q -U svc_control_api -d pharmacy_beta -c 'CREATE TABLE public.riayati_gap (id text PRIMARY KEY, branch_no smallint NOT NULL)' -c 'ALTER TABLE public.riayati_gap ENABLE ROW LEVEL SECURITY'"
sleep 1
run_job
[ "${RC}" = "1" ] || fail "§10.4 run exited ${RC}, expected 1"
has "❌ pharmacy_beta: row-level security without a full-read policy for svc_backup: public.riayati_gap. Previous dump kept."
[ "$(in_runner 'stat -c %i /backups/last/pharmacy_beta-*.dump.gpg')" = "${before}" ] || fail "§10.4 pharmacy_beta's dump was replaced"
in_runner "PGHOST=db PGPASSWORD=svc_pw psql -X -q -U svc_control_api -d pharmacy_beta -c 'DROP TABLE public.riayati_gap'"
ok "§10.4 RLS guard failed pharmacy_beta and kept its dump"

# §10.5 + §10.6 — a run stuck on a lock is killed mid-run: the previous dump survives, and a
# second run meanwhile exits 75; the next run removes any .part.
alpha_before=$(in_runner 'stat -c %i /backups/last/pharmacy_alpha-*.dump.gpg')
in_runner "PGHOST=db PGPASSWORD=svc_pw psql -X -q -U svc_control_api -d pharmacy_alpha -c 'BEGIN' -c 'LOCK TABLE br02.otdel IN ACCESS EXCLUSIVE MODE' -c 'SELECT pg_sleep(30)' -c 'COMMIT'" &
locker=$!
sleep 2
"${COMPOSE[@]}" exec -d backup /backup.sh
sleep 4
run_job
[ "${RC}" = "75" ] || fail "§10.6 second run exited ${RC}, expected 75"
has "Another backup run holds /backups/.lock. Not started."
[ -n "$(in_runner 'find /backups/last -name ".*.part"')" ] || fail "§10.6 no .part present while the run was stuck (or the locked-out run removed it)"
# "bash [/]backup[.]sh" matches the run's command line (bash /backup.sh) but neither this
# sh -c's own, which a plain "/backup.sh" pattern would SIGKILL before it reached pg_dump
# and gpg, nor go-cron's (-- /backup.sh).
"${COMPOSE[@]}" exec -T backup sh -c 'pkill -9 -f "bash [/]backup[.]sh"; pkill -9 pg_dump; pkill -9 gpg; true'
[ -n "$(in_runner 'find /backups/last -name ".*.part"')" ] || fail "§10.5 no .part left by the killed run"
wait "${locker}" || true
[ "$(in_runner 'stat -c %i /backups/last/pharmacy_alpha-*.dump.gpg')" = "${alpha_before}" ] || fail "§10.5 the killed run replaced pharmacy_alpha's dump"
run_job
[ "${RC}" = "0" ] || fail "§10.5 the run after the kill exited ${RC}"
[ -z "$(in_runner 'find /backups/last -name ".*.part"')" ] || fail "§10.5 a .part survived the next run"
ok "§10.5 killed run kept the old dump, next run cleaned up; §10.6 concurrent run exited 75"

# §10.7 — a discarded pharmacy's dump leaves last/; its daily copies remain.
in_runner "PGHOST=db PGPASSWORD=admin psql -X -q -U platform_admin -d postgres -c 'DROP DATABASE pharmacy_beta WITH (FORCE)'"
sleep 1
run_job
[ "${RC}" = "0" ] || fail "§10.7 run exited ${RC}"
has "🗑️ pharmacy_beta no longer exists: its dump left last/"
[ -z "$(in_runner 'find /backups/last -name "pharmacy_beta-*"')" ] || fail "§10.7 pharmacy_beta still in last/"
[ -n "$(in_runner 'find /backups/daily -name "pharmacy_beta-*"')" ] || fail "§10.7 pharmacy_beta's daily copies are gone"
ok "§10.7 dropped pharmacy left last/, kept daily/"

# §10.8 — no secret in the logs.
ALL_OUT="${ALL_OUT}$("${COMPOSE[@]}" logs backup 2>&1)"
if grep -qF -- "${KEY}" <<< "${ALL_OUT}" || grep -qF -- "svc_pw" <<< "${ALL_OUT}"; then
  fail "§10.8 a secret appears in the output or docker logs"
fi
ok "§10.8 no secret in docker logs or run output"

# Off-site copies — the uploader beside the backup: no database, no key, a read-only folder.
# shellcheck disable=SC2016  # expanded by the runner's bash, not here
in_runner '
  for i in $(seq 1 30); do
    curl -sf -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user testkey:testsecret123 http://s3:9000/platform-offsite >/dev/null && exit 0
    sleep 1
  done
  exit 1
' || fail "off-site: could not create the bucket"
set +e
OUT="$("${COMPOSE[@]}" exec -T uploader /scripts/s3-sync.sh 2>&1)"
RC=$?
set -e
printf '%s\n' "${OUT}" | sed 's/^/    │ /'
[ "${RC}" = "0" ] || fail "off-site: the uploader's sync exited ${RC}"
has "☁️ Off-site s3://platform-offsite/platform-test: "
# shellcheck disable=SC2016  # expanded by the runner's bash, not here
in_runner '
  set -e
  export S3_BUCKET=platform-offsite S3_ENDPOINT=http://s3:9000 S3_FORCE_PATH_STYLE=TRUE S3_PREFIX=platform-test \
    S3_ACCESS_KEY_ID=testkey S3_SECRET_ACCESS_KEY=testsecret123
  keys="$(s3-sync ls | cut -f1)"
  for f in /backups/last/*.dump.gpg; do
    name="$(basename "$f")"
    db="$(sed -E "s/-[0-9]{8}-[0-9]{6}\..*$//" <<< "${name}")"
    grep -qxF "platform-test/${db}/${name}" <<< "${keys}" || { echo "missing off-site: ${name}"; exit 1; }
  done
' || fail "off-site: a database's newest dump is not in the bucket"
"${COMPOSE[@]}" exec -T uploader sh -c 'command -v getent >/dev/null && ! getent hosts db' \
  || fail "off-site: the uploader can resolve the database host"
if "${COMPOSE[@]}" exec -T uploader sh -c 'touch /backups/.write-probe' >/dev/null 2>&1; then
  fail "off-site: the uploader can write the backups"
fi
# Checked inside the container, so no value is ever printed.
# shellcheck disable=SC2016  # expanded by the uploader's shell, not here
"${COMPOSE[@]}" exec -T uploader sh -c '[ -z "${POSTGRES_PASSWORD}${POSTGRES_PASSWORD_FILE}${BACKUP_ENCRYPTION_KEY}" ]' \
  || fail "off-site: the uploader holds a database password or the backup key"
ok "off-site: every database's newest dump is in the bucket; the uploader has no database, no key, a read-only folder"

# The uploader runs go-cron under tini, which passes docker stop's TERM to a running sync;
# the stop ends cleanly (exit 0), well inside Docker's 10 s timeout, not by SIGKILL.
[ "$("${COMPOSE[@]}" exec -T uploader cat /proc/1/comm)" = "tini" ] || fail "off-site: the uploader's PID 1 is not tini"
# -g is what passes the TERM to a running sync; an idle uploader would stop cleanly without it.
cmdline="$("${COMPOSE[@]}" exec -T uploader sh -c 'tr "\0" " " < /proc/1/cmdline')"
[[ "${cmdline}" == "tini -s -g -- /usr/local/bin/go-cron "* ]] \
  || fail "off-site: the uploader's PID 1 is not tini -s -g -- go-cron: ${cmdline}"
started=$(date +%s)
"${COMPOSE[@]}" stop uploader
elapsed=$(( $(date +%s) - started ))
[ "${elapsed}" -lt 10 ] || fail "off-site: stopping the uploader took ${elapsed}s (killed at the timeout?)"
code="$(docker inspect -f '{{.State.ExitCode}}' "$("${COMPOSE[@]}" ps -aq uploader)")"
[ "${code}" = "0" ] || fail "off-site: the stopped uploader exited ${code}"
ok "off-site: the uploader's PID 1 is tini -s -g; docker compose stop ended it cleanly in ${elapsed}s"

echo "════ Pharmakon acceptance: all checks passed"
