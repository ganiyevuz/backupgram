# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image (pure Bash, no application runtime) that runs automated PostgreSQL backups on a cron schedule, with rotating retention, Telegram delivery, optional GPG encryption, webhooks, and built-in restore tooling. Published as `ganiyevuz/backupgram:<pg-version>[-alpine]` for 4 PostgreSQL versions (15–18) × 2 base images (Debian/Alpine) × 2 platforms (amd64, arm64).

There is **no local build/lint/test toolchain** — everything is shell scripts baked into a Postgres-based image. Verification happens via the CI matrix (`.github/workflows/ci.yml`), which runs the scripts directly against a live `postgres:16` service container.

## Runtime architecture

The container entrypoint chain:

```
init.sh (ENTRYPOINT)
  └─ /env.sh            # standalone validation when VALIDATE_ON_START=TRUE
  └─ exec go-cron -s "$SCHEDULE" -- /backup.sh   # go-cron is the scheduler + healthcheck HTTP server
```

`go-cron` (downloaded from prodrigestivill/go-cron in the Dockerfile) owns the schedule and serves the healthcheck port. It invokes `backup.sh` per `SCHEDULE`.

**`scripts/env.sh` is dual-purpose and central:**
- **Sourced** by `backup.sh` and `restore.sh` — validates required vars, resolves Docker-secret `*_FILE` variants, exports `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`, splits comma-separated `POSTGRES_DB` into `$POSTGRES_DBS`, and computes retention thresholds.
- **Executed** standalone (as `/env.sh`) by `init.sh` for startup validation — hence it both `export`s vars and `exit 1`s on bad config.
- Retention math lives here: `KEEP_WEEKS=$((BACKUP_KEEP_WEEKS*7+1))` and `KEEP_MONTHS=$((BACKUP_KEEP_MONTHS*31+1))` convert weeks/months into the day counts that `find -mtime` uses in `backup.sh`.

**`scripts/backup.sh` is the core cycle**, in order: `flock` guard (skips if already running) → source `env.sh` → `pre-backup` hook → `pg_isready` connectivity check → disk-space check → dump (`pg_dump` per DB, or `pg_dumpall` when `POSTGRES_CLUSTER=TRUE`) → `verify_backup` → `encrypt_file` (GPG AES-256 if `BACKUP_ENCRYPTION_KEY` set) → rotate → Telegram send → retention cleanup → write `/tmp/backup_status` → summary Telegram message → `post-backup` hook.

**Rotation model:** each run writes a timestamped file into `last/`, then **hard-links** it into `daily/`, `weekly/`, `monthly/` (same inode = no extra disk). `*-latest` pointers are created per slot (symlink/hardlink/none via `BACKUP_LATEST_TYPE`). Directory-format dumps (`-Fd`) can't be hard-linked, so they're `cp -r`'d and tar.gz'd for Telegram. This is why `BACKUP_DIR` must be a POSIX filesystem with hardlink+symlink support (no VFAT/exFAT/CIFS).

**Format-specific branches** appear throughout — keep them in sync across `backup.sh` (`verify_backup`, encryption suffix handling) and `restore.sh` (decrypt → un-tar → dispatch by extension):
- gzip SQL (`.sql.gz`) — default, magic-byte checked (`1f8b`); `-Z0` produces uncompressed and is tolerated.
- directory (`-Fd`) — verified/restored via `pg_restore --list` / `pg_restore`.
- cluster (`pg_dumpall`) — plain SQL, **skips** `pg_restore` verification, restored via `psql -d postgres`.
- GPG (`.gpg`) — wraps any of the above.

**CLI commands** are symlinks in `/usr/local/bin` (see Dockerfiles): `backup`, `restore`, `list`, `status`, `help`. Run via `docker exec -it <container> <cmd>`.

**Hooks** (`hooks/`) run via `run-parts` with arg `pre-backup` | `post-backup` | `error`. The bundled `00-webhook` implements all the `WEBHOOK_*` env vars. Add custom scripts alongside it.

## Build system — read before editing

`docker-bake.hcl` is a **generated file**. Do not hand-edit it. Change `generate-docker-bake.sh` (it holds the version/platform/tag lists), then regenerate:

```sh
./generate-docker-bake.sh        # rewrites docker-bake.hcl in place
```

CI runs `./generate-docker-bake.sh docker-bake-generated.hcl && cmp docker-bake.hcl docker-bake-generated.hcl` — an out-of-sync `docker-bake.hcl` fails the build.

Both Dockerfiles (`docker/debian.Dockerfile`, `docker/alpine.Dockerfile`) must be kept in lockstep — they share an identical `ENV` block (the canonical list of every variable + default) and identical symlink setup. Update both together.

Build commands:

```sh
docker buildx bake --pull                                   # build all targets locally
docker buildx bake debian-17                                # single target
REGISTRY_PREFIX="you/" docker buildx bake --pull --push     # build + push
```

Multi-arch builds need QEMU + a buildx container builder — see `docs/BUILD.md`.

## Testing

Run a script the way CI does — directly against a reachable Postgres, with the same env vars:

```sh
POSTGRES_HOST=127.0.0.1 POSTGRES_DB=database POSTGRES_USER=user POSTGRES_PASSWORD=test \
BACKUP_DIR=/tmp/backups POSTGRES_EXTRA_OPTS="-Z0" \
bash -x scripts/backup.sh
```

CI (`.github/workflows/ci.yml`) exercises each mode as a separate step — plain dump, directory format (`-Z0 -Fd`), cluster (`pg_dumpall`), table exclusion, GPG encryption, `list`, non-interactive `restore`, Telegram-disabled — then builds the images, then publishes on push to `main`. **When adding a backup mode or format branch, add a matching CI step.** The local `pg_dump` client version must match the server (CI installs `postgresql-client-16` against `postgres:16`).

## Conventions

- All scripts start with `set -Eeo pipefail`; `backup.sh` traps `ERR` to fire the `error` hook.
- `pg_dump`/`pg_dumpall` invocations are unquoted-on-purpose to word-split `POSTGRES_EXTRA_OPTS` — keep the `# shellcheck disable=SC2086` directives when touching those lines.
- User-facing output uses emoji status prefixes (✅ ❌ ⚠️ 🔒) and `────`/`════` rule lines; match the surrounding style.
- Secrets resolve via `*_FILE` (Docker secrets) taking precedence over the plain env var — preserve that precedence when adding new credentials.
- Telegram's 50MB limit is enforced **only** when `TELEGRAM_API_URL` is the official `https://api.telegram.org`; a custom self-hosted Bot API URL bypasses the check.
