# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image that runs automated PostgreSQL backups on a cron schedule, with rotating retention, Telegram delivery, optional GPG encryption, webhooks, an optional REST control API, Prometheus metrics with a Grafana dashboard, off-site copies to S3-compatible storage, and built-in restore tooling. Published as `ganiyevuz/backupgram:<pg-version>[-alpine]` for 4 PostgreSQL versions (15–18) × 2 base images (Debian/Alpine) × 2 platforms (amd64, arm64).

Four parts, all baked into a Postgres-based image:
- `scripts/` + `hooks/` — Bash; the backup/restore logic itself. `backup.sh` sources its helpers from `scripts/lib/` (`layout.sh`, `dump.sh`, `discover.sh`, `rls_guard.sh`, `metrics.sh`, `s3.sh`).
- `tg-upload/` — Go module `tgupload`: MTProto uploader for Telegram files >50MB (up to 2GB).
- `rest-api/` — Go module `backupgram`: the `backupgram-api` HTTP server (packages `config`, `handlers`, `jobs`, `server`, `supervisor`, `httpx`, `backups`).
- `s3-sync/` — Go module `s3sync` (only dependency: `minio-go`): the `s3-sync` binary for off-site copies — `sync`, `ls`, `get`, `latest`. A storage interface (minio-go implementation) plus pure functions (eligibility, key mapping, upload plan, prune decisions) that the unit tests drive with a fake storage.

The three Go binaries are built in separate `golang:1.25-alpine` stages of each Dockerfile (`s3-sync` statically, `CGO_ENABLED=0`). There is no lint toolchain for the Bash side; it's verified by end-to-end scenarios (`tests/scenarios.sh`, run locally with `tests/run-local.sh`) that the CI matrix (`.github/workflows/ci.yml`) runs against a live `postgres:16` service container. `monitoring/` holds the Grafana dashboard and Prometheus alert rules the metrics feed.

## Runtime architecture

The container entrypoint chain:

```
init.sh (ENTRYPOINT)
  ├─ BACKUPGRAM_MODE=s3-sync:        /scripts/s3-env.sh, then exec go-cron -s "$S3_SCHEDULE" -p "$HEALTHCHECK_PORT" -- /scripts/s3-sync.sh   # the off-site uploader
  └─ /env.sh                         # standalone validation when VALIDATE_ON_START=TRUE
  ├─ REST_API_ENABLE=TRUE or METRICS_ENABLE=TRUE:  exec backupgram-api   # PID 1; supervises go-cron as a child and can restart it
  └─ otherwise:             exec go-cron -s "$SCHEDULE" -p "$HEALTHCHECK_PORT" [-i] -- /backup.sh
```

`go-cron` (downloaded from prodrigestivill/go-cron in the Dockerfile) owns the schedule and serves the healthcheck port; `-i` (from `BACKUP_ON_START=TRUE`) runs one backup immediately. With the REST API or metrics on, `backupgram-api` builds the same go-cron args itself (`rest-api/main.go`) and runs backups/restores as jobs that exec the in-image absolute paths `/backup.sh` / `/restore.sh`.

**`backupgram-api` modes** (`rest-api/main.go`, `server.Router`): `/healthz` always; `GET /metrics` when `METRICS_ENABLE=TRUE` (unauthenticated, serves `${BACKUP_DIR}/.metrics.prom`; an empty 200 before the first run); the token-protected REST routes only when `REST_API_ENABLE=TRUE`. A token is required only for the REST API, so `METRICS_ENABLE=TRUE` alone is a metrics-only server. `/metrics` exposes database names and results, so the docs tell users to keep `REST_API_PORT` on an internal network.

**REST API config overrides:** `PATCH /config` accepts only keys in the server-side whitelist (`mutableKeys` in `rest-api/config/config.go`; anything else → 403). It persists to `$BACKUP_DIR/.api-overrides.json` and a shell-sourceable `$BACKUP_DIR/.api-overrides.env`, which `env.sh` and `healthcheck.sh` source — so runtime overrides flow into the Bash side without a restart. Adding a new mutable setting means touching the whitelist *and* making sure `env.sh` reads it. Security-relevant settings (`BACKUP_RLS_GUARD`, `BACKUP_GID`, `BACKUP_LAYOUT`, `BACKUP_MIN_BYTES`, the `METRICS_*` settings, `BACKUPGRAM_MODE` and every `S3_*` setting) stay out of the whitelist on purpose; `POSTGRES_DB_INCLUDE` is in it.

**`scripts/env.sh` is dual-purpose and central:**
- **Sourced** by `backup.sh` and `restore.sh` — validates required vars, resolves Docker-secret `*_FILE` variants, exports `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`, splits comma-separated `POSTGRES_DB` into `$POSTGRES_DBS`, and computes retention thresholds.
- **Executed** standalone (as `/env.sh`) by `init.sh` for startup validation — hence it both `export`s vars and `exit 1`s on bad config.
- Retention math lives here: `KEEP_WEEKS=$((BACKUP_KEEP_WEEKS*7+1))` and `KEEP_MONTHS=$((BACKUP_KEEP_MONTHS*31+1))` convert weeks/months into the day counts that `find -mtime` uses in `backup.sh`.

**`scripts/backup.sh` is the core cycle**, in order: source `env.sh` and `scripts/lib/*.sh` (the lock needs `BACKUP_DIR`) → lock `${BACKUP_DIR}/.lock` (`flock -n`; a busy lock prints one line and exits **75** before touching anything — it is in `BACKUP_DIR`, not `/tmp`, so containers sharing a volume also serialise) → one `STAMP` for the whole run and setup (`BACKUP_GID` perms, remove stale `last/.*.part`, passphrase file) → `pre-backup` hook → `pg_isready` → discovery (if `POSTGRES_DB_AUTODISCOVER=TRUE`: `POSTGRES_DB_INCLUDE` globs → `POSTGRES_DB_EXCLUDE` → databases without `CONNECT` are skipped and logged; ignored in cluster mode) → disk-space check → **per database** (`backup_database`): RLS guard (`BACKUP_RLS_GUARD`) → dump into `last/.<name>.part` → size check + full verification → rename into place → link into the other folders → Telegram → after the loop: prune dropped databases from `last/` (snapshot layout) → retention (once, over every file; **skipped when no database succeeded**, so a total outage never erodes the last good copies) → off-site sync (`s3_sync`, when `S3_BUCKET` is set; runs even when every dump failed, and its outcome never changes the exit code) → metrics → `/tmp/backup_status` → summary Telegram message → `post-backup` hook. Exit `0` when every database dumped, `1` when any failed (the others still ran) or the run aborted early (aborts write the metrics first).

**Per-database pipeline** (`scripts/lib/dump.sh`): `.part` → verify → rename. A failed dump, a dump below `BACKUP_MIN_BYTES` or one that does not read back in full is removed and the previous dump stays. Encryption streams: `pg_dump | gpg` writes the `.part` (nothing unencrypted on disk), the key goes through a `mktemp` passphrase file, never a command line, and verification reads through the decryption pipe. Directory-format (`-Fd`) dumps are never encrypted.

**Rotation model** (`scripts/lib/layout.sh`): each run writes a timestamped file into `last/`, then **hard-links** it into `daily/`, `weekly/`, `monthly/` (same inode = no extra disk). `*-latest` pointers are created per slot (symlink/hardlink/none via `BACKUP_LATEST_TYPE`). Directory-format dumps (`-Fd`) can't be hard-linked, so they're `cp -r`'d and tar.gz'd for Telegram. This is why `BACKUP_DIR` must be a POSIX filesystem with hardlink+symlink support (no VFAT/exFAT/CIFS). Two layouts (`BACKUP_LAYOUT`): **`period`** (default) names `daily/weekly/monthly` files by day / ISO week / month and replaces them each run, with `last/` age-pruned by `BACKUP_KEEP_MINS`; **`snapshot`** puts the run's timestamped name in every folder (`weekly/` only on Sundays, `monthly/` only on the 1st), `last/` keeps exactly the newest dump of each existing database, and a dropped database's stamped dump **and** its `last/<db>-latest…` entry leave `last/` while `daily/weekly/monthly` keep theirs.

**Format-specific branches** appear throughout — keep them in sync across `backup.sh` (`scripts/lib/dump.sh`: `detect_dump_format`, `verify_part`, `final_suffix`) and `restore.sh` (decrypt → un-tar → dispatch by extension):
- gzip SQL (`.sql.gz`) — default, verified with `gunzip -c`; `-Z0` produces uncompressed plain SQL, which only gets a size check.
- custom (`-Fc`) / tar — verified with `pg_restore -f /dev/null` (through `gpg --decrypt` when encrypted).
- directory (`-Fd`) — verified/restored via `pg_restore`; never encrypted.
- cluster (`pg_dumpall | gzip`) — plain SQL, verified with `gunzip`, **skips** `pg_restore`, restored via `psql -d postgres`.
- GPG (`.gpg`) — wraps any of the above except directory; `restore.sh` streams custom/`.sql`/`.sql.gz` straight from `gpg` into the restore (only a tar-archived directory decrypts to a temp file), and a wrong key exits 1 with `❌ Could not read the backup …`.

**Metrics** (`scripts/lib/metrics.sh`): after retention (and on early aborts) `backup.sh` renders Prometheus gauges from the files on disk plus the run's results, and writes them atomically to `${BACKUP_DIR}/.metrics.prom` (`METRICS_ENABLE=TRUE`) and/or `${METRICS_TEXTFILE_DIR}/backupgram[-<project>].prom`. Dot files are never backups: `list`, `status`, metrics and `GET /backups` skip names starting with `.`.

**Off-site copies (S3)** (`s3-sync/`, `scripts/s3-env.sh`, `scripts/lib/s3.sh`, `scripts/s3-sync.sh`): `s3-env.sh` resolves the `S3_*_FILE` secrets (the file wins), fills defaults (`S3_KEEP_*` inherit `BACKUP_KEEP_*`) and validates; it is sourced by `env.sh`, `restore.sh`, `list.sh` and the uploader, and executed by `init.sh` in uploader mode (where `env.sh`, `POSTGRES_*` and the key are never needed). `s3-sync sync --dir "$BACKUP_DIR" --status <file>` uploads what the bucket lacks, then prunes. Eligible files are stamped (`<db>-YYYYMMDD-HHMMSS<suffix>`, parsed in `time.Local`, so both containers share `TZ`) regular files in `last/` and `daily/`, never dot files (an in-flight `.part`), `-latest` entries or directory dumps, and `.gpg` only unless `S3_ALLOW_UNENCRYPTED=TRUE`. The key is `<S3_PREFIX>/<db>/<file>`; a key present with another size is uploaded again, and every upload is checked with a stat. Pruning applies the tiers (`S3_KEEP_*`, same day counts as the disk) and never deletes the newest object of a database that still has a stamped file in `last/`; an object not at exactly `<S3_PREFIX>/<db>/<stamped file>` is never touched. The status file (`result <ok|failed> <time>`, one `newest <db> <time> <bytes> <key>` per database) feeds `render_offsite_metrics` (`backupgram_offsite_*`): appended to the run's metrics in backup mode, or alone in `${METRICS_TEXTFILE_DIR}/backupgram-offsite[-<project>].prom` in uploader mode (no HTTP endpoint). `scripts/s3-sync.sh` takes a lock, runs one sync and exits `1` when it failed (go-cron then answers 503, so the container shows unhealthy until the next good sync). `restore --from-s3` and `list --s3` call `s3-sync latest|get|ls`; the object streams through `gpg` into the restore, never to disk.

**Telegram upload routing** (`backup.sh`, per `TELEGRAM_UPLOAD_METHOD`, validated in `env.sh`): `smart` (default) uses the Bot API and falls back to `tg-upload` for files >50MB when `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` are available; `botapi` never uses MTProto; `mtproto` sends everything via `tg-upload`. Multiple chats upload once and reuse the returned `file_id`.

**CLI commands** are symlinks in `/usr/local/bin` (see Dockerfiles): `backup`, `restore`, `list`, `status`, `help`. Run via `docker exec -it <container> <cmd>`.

**Hooks** (`hooks/`) run via `run-parts` with arg `pre-backup` | `post-backup` | `error`. The bundled `00-webhook` implements all the `WEBHOOK_*` env vars. Add custom scripts alongside it.

## Build system — read before editing

`docker-bake.hcl` is a **generated file**. Do not hand-edit it. Change `generate-docker-bake.sh` (it holds the version/platform/tag lists), then regenerate:

```sh
./generate-docker-bake.sh        # rewrites docker-bake.hcl in place
```

CI runs `./generate-docker-bake.sh docker-bake-generated.hcl && cmp docker-bake.hcl docker-bake-generated.hcl` — an out-of-sync `docker-bake.hcl` fails the build.

Both Dockerfiles (`docker/debian.Dockerfile`, `docker/alpine.Dockerfile`) must be kept in lockstep — they share an identical `ENV` block (the canonical list of every variable + default) and identical symlink setup. Update both together.

The shared default Telegram app is injected **only at build time** via the BuildKit secret `id=tg_default_api` (a two-line file: `api_id`, `api_hash`), which both Dockerfiles bake into `/etc/backupgram/default-telegram-api` (root-only, `0600`) and into the `tg-upload` binary via `-ldflags`. The source file `docker/default-telegram-api` is **gitignored — never commit it** and never put the values in `ENV`/`ARG`/docs. The committed base bake (`docker-bake.hcl`) carries no secret; the secret is added only by the CI-only override `docker-bake.secret.hcl`, and CI writes the source file from the `TG_DEFAULT_API_ID` / `TG_DEFAULT_API_HASH` repo secrets before `docker buildx bake -f docker-bake.hcl -f docker-bake.secret.hcl`. Local builds without the file simply ship no default (`env.sh` and `tg-upload` degrade gracefully).

Build commands:

```sh
docker buildx bake --pull                                   # build all targets locally
docker buildx bake debian-17                                # single target
REGISTRY_PREFIX="you/" docker buildx bake --pull --push     # build + push
```

Multi-arch builds need QEMU + a buildx container builder — see `docs/BUILD.md`.

## Testing

Go (run from each module dir; mirrors the CI `test-go` job):

```sh
(cd tg-upload && go vet ./... && go test ./...)
(cd rest-api  && go vet ./... && go test ./... -race)
(cd s3-sync   && go vet ./... && go test ./... -race)
(cd rest-api  && go test ./config -run TestName)   # single test
```

Bash scenarios — `tests/scenarios.sh` holds one `scenario_<name>` function per behaviour (helpers in `tests/lib.sh`); `tests/run-local.sh` runs them in Docker against PostgreSQL 18 (`PG_MAJOR=16` for CI's version; `KEEP=1` leaves the containers up):

```sh
tests/run-local.sh                          # every scenario
tests/run-local.sh lock_busy encrypted_custom   # just these
PG_MAJOR=16 tests/run-local.sh              # the PostgreSQL version CI uses
```

**One CI step per scenario** (`bash tests/scenarios.sh <name>`, against `postgres:16`, with `faketime` and `promtool` installed) — so a new backup mode, format branch or setting gets a new `scenario_*` function *and* a matching CI step. The `s3_*` scenarios need an S3 server: the local harness has an `s3` service (`rustfs/rustfs:1.0.0`, credentials `testkey` / `testsecret123`, ready when `GET /health` answers 200; never put a plain `tmpfs` on its `/data`, it runs as a non-root user), and CI starts the same image with `docker run` in the `test-script` job (Actions services cannot pass a command) and builds `s3-sync` into `/usr/local/bin`. `s3_env` in `tests/lib.sh` creates a fresh bucket (`curl --aws-sigv4`) and exports the `S3_*` settings; the prune scenarios pick stamps relative to today instead of using `faketime`, which does not affect a static Go binary. `minio/minio` images are no longer pullable. `tests/pharmakon/fixture.sh` builds a Pharmakon-shaped server (service logins, row-level security, a database the login cannot `CONNECT` to) for the `pharmakon_*` scenarios, and `tests/pharmakon/acceptance.sh` is the acceptance run of the real `18-alpine` image against it.

Bash — run a script the way CI does, directly against a reachable Postgres:

```sh
POSTGRES_HOST=127.0.0.1 POSTGRES_DB=database POSTGRES_USER=user POSTGRES_PASSWORD=test \
BACKUP_DIR=/tmp/backups POSTGRES_EXTRA_OPTS="-Z0" \
bash -x scripts/backup.sh
```

CI (`.github/workflows/ci.yml`) exercises each mode as a separate step — plain dump, directory format (`-Z0 -Fd`), cluster (`pg_dumpall`), table exclusion, auto-discover, REST API end-to-end, GPG encryption, MTProto upload (only when secrets exist), `list`, non-interactive `restore`, Telegram-disabled — then builds the images, then publishes on push to `main`. **When adding a backup mode or format branch, add a matching CI step.** The local `pg_dump` client version must match the server (CI installs `postgresql-client-16` against `postgres:16`).

The REST API CI step shows how to run `backupgram-api` outside the image: `go build -C rest-api`, symlink `scripts/{env,backup,restore}.sh` to `/`, and set `GOCRON_BIN` to a stub so the supervisor doesn't need real go-cron. For a full-image loop, `docker-compose.local.yml` runs a locally built `pgbackup-local:17` (build command in its header comment) with the API on `localhost:8081`.

## Docs

`docs/*.md` is published to Read the Docs via MkDocs Material (`mkdocs.yml`, `docs_dir: docs`; `docs/superpowers/` and `dockerhub-header.md` are excluded). Local preview: `uv run --with-requirements docs/requirements.txt mkdocs serve`. `CHANGELOG.md` uses dated CalVer releases (e.g. `2026.7.0`); `llms.txt` is a hand-maintained summary — update it with user-facing features.

## Conventions

- All scripts start with `set -Eeo pipefail`; `backup.sh` traps `ERR` to fire the `error` hook.
- **A function called in an `if` condition or on the left of `||`/`&&` runs without errexit** (`set -e` is suspended inside it). Check every command in such a function (`cmd || return 1`) — `backup_database`, `link_into_slots` and the `lib/` helpers are called that way on purpose, so a failure is handled, not fatal.
- **`set -E` hands the `ERR` trap to every command substitution**, so a command failing inside `$(…)` can fire the `error` hook even when the caller handles the result (bash 5.1/5.2 hold it back while the substitution itself sits in a condition — do not rely on that). Keep helpers used inside `$(…)` from failing (`stamped_db_name` prints nothing instead of returning 1), and handle an expected failure inside the substitution: `if ! x=$(psql … || exit 1); then`. `tests/scenarios.sh error_hook_not_fired_on_success` guards this.
- **Never end a pipeline in `grep -q` when its first stage may still be writing**: `grep -q` exits at the first match and `pipefail` turns the writer's SIGPIPE into a failure. Capture the output first, or use `awk` / `grep >/dev/null`.
- `pg_dump`/`pg_dumpall` invocations are unquoted-on-purpose to word-split `POSTGRES_EXTRA_OPTS` — keep the `# shellcheck disable=SC2086` directives when touching those lines, and keep pathname expansion off (`set -f`) around them so a glob in `POSTGRES_EXTRA_OPTS` is never expanded against files.
- User-facing output uses emoji status prefixes (✅ ❌ ⚠️ 🔒) and `────`/`════` rule lines; match the surrounding style.
- Secrets resolve via `*_FILE` (Docker secrets) taking precedence over the plain env var — preserve that precedence when adding new credentials.
- Telegram's 50MB limit is enforced **only** when `TELEGRAM_API_URL` is the official `https://api.telegram.org`; a custom self-hosted Bot API URL bypasses the check.
