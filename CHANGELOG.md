# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Image tags track the bundled PostgreSQL major version (15–18); project releases
are tagged separately using CalVer (`YYYY.M.PATCH`).

## [2026.10.0] - 2026-10-01

### Breaking
- `backup` exits **75** when another run holds the lock, and **1** when any database
  failed (the others still run). Both used to exit 0. REST API backup jobs now report
  these runs as failed.
- Failure lines (each failed database's `❌ …` line and the `❌ Failed: <dbs>` summary)
  go to stderr, so `backup > log` no longer captures them: use `2>&1`.
- Retention covers every file in each folder, not only the databases in the run: a
  dropped or renamed database's copies now age out (they used to stay forever). The
  databases that failed in the run keep all their copies, and retention is skipped
  when no database was backed up, so neither a total outage nor a database failing
  night after night erodes its last good copies.
- The container healthcheck reads the last scheduled run's exit status from
  `go-cron`: a run that exited `75` (locked out by a manual or REST API run) counts as
  healthy; any other non-zero exit reports `UNHEALTHY: last backup run exited <N>`
  (it used to read every failed run as `go-cron is not responding`).
- The lock moved from `/tmp/backup.lock` to `${BACKUP_DIR}/.lock`, so the scheduled run
  and a manual `docker exec … backup` (or two containers running the same
  configuration on one volume) run one at a time. Keep **one `BACKUP_DIR` per
  server/configuration**: with different servers or retention settings in one folder,
  every-file retention and dropped-database pruning would act on each other's files.
- Every file of a run carries the run's start time (it was each database's dump time).
- A `BACKUP_ENCRYPTION_KEY` containing a newline is refused at startup (`❌
  BACKUP_ENCRYPTION_KEY must be a single line …`): gpg reads only the first line of
  the passphrase file, so the rest of such a key was silently ignored.

### Added
- **Off-site copies to S3-compatible storage** (AWS S3, Hetzner, Backblaze B2, Wasabi,
  Cloudflare R2, or RustFS/Garage/SeaweedFS on another machine), in addition to the
  local folders. See `docs/OFFSITE.md`.
  - Two ways to run it: set `S3_BUCKET` and its credentials (also as `S3_*_FILE`
    secrets) to sync at the end of every backup run that reaches the dumps, or run a
    separate uploader container (`BACKUPGRAM_MODE=s3-sync`, `S3_SCHEDULE`) that needs
    no database access, no key and only a read-only backup folder.
  - Dumps go to `<S3_PREFIX>/<db>/<file>`, are checked against their local size and
    uploaded again when it differs. A backlog goes up newest first. Unencrypted dumps
    stay local unless `S3_ALLOW_UNENCRYPTED=TRUE`; directory dumps are not uploaded.
  - The bucket is pruned by tiers with the same day counts as the disk (`S3_KEEP_DAYS` /
    `_WEEKS` / `_MONTHS`, counted over every stamped dump). It never loses the newest
    copy of a database that still has a dump, and nothing is pruned while `last/` holds
    no dump (a new or wrong folder). `S3_PRUNE=FALSE` uploads only, for write-only
    credentials and object lock.
  - Each sync stops at `S3_SYNC_TIMEOUT` (1 to 999999999 seconds, default 3600) and
    counts as failed, so a stalled endpoint holds up the backups (their lock) for at
    most that long, plus up to 5 seconds to abort an unfinished upload.
  - Off-site problems never change a backup run's exit code. A bad S3 setting stops the
    container from starting; one that breaks later (an unreadable secret file) turns the
    off-site copies off with a warning and a failed sync, never the local backups.
  - The uploader runs `go-cron` under `tini -s -g`, so `docker stop` ends a running sync
    cleanly: it aborts its upload and records a failed sync. A backup container is
    unchanged: `docker stop` waits for a running backup up to the stop timeout with
    `go-cron` as PID 1, and ends it after about 5 s with `backupgram-api` as PID 1
    (REST API or metrics on); a sync still running then is killed outright.
  - `restore --from-s3 <db|key>` streams a dump from the bucket into the restore, and
    `list --s3 [db]` lists the bucket.
  - Metrics `backupgram_offsite_*` (per database with a dump in `last/`; timestamp `0`
    when the bucket holds none of its dumps; `backupgram_offsite_databases` counts those
    databases), the alerts `BackupgramOffsiteTooOld`, `BackupgramOffsiteSyncFailed` and
    `BackupgramOffsiteNoDatabases` (no dump in `last/` for 26 h, usually an uploader
    mounted on the wrong volume; the sync also warns on every such run), and an off-site
    age panel in the dashboard.
- **Prometheus metrics** (`METRICS_TEXTFILE_DIR`, `METRICS_ENABLE` → `GET /metrics`), a
  Grafana dashboard and alert rules under `monitoring/` (backup too old, missed twice,
  database failed, run failed, dump shrank, low disk, scrape down).
  `METRICS_ENABLE=TRUE` without `REST_API_ENABLE` runs a metrics-only server (`/healthz`
  and `/metrics`, no token). `/metrics` is unauthenticated and lists database names:
  keep `REST_API_PORT` on an internal network. See `docs/MONITORING.md`.
- `POSTGRES_DB_INCLUDE` — glob patterns for auto-discovered databases (also changeable
  through the REST API); databases the login may not `CONNECT` to are skipped and logged.
- `BACKUP_RLS_GUARD` — refuses a dump that row-level security would silently cut short.
- `BACKUP_LAYOUT=snapshot` — timestamped names in every folder, weekly on Sundays,
  monthly on the 1st, `last/` holds exactly the newest dump of each existing database.
  A dropped database's dump and its `-latest` entry leave `last/`; its `daily/`,
  `weekly/` and `monthly/` copies stay until retention removes them.
- `BACKUP_MIN_BYTES` — a dump smaller than this is rejected and the previous one kept
  (an empty dump always is).
- `BACKUP_GID` — group for the backup folders (setgid, `2750`) and files (`0640`).
- A backup run warns when `-Ft` dumps get a `BACKUP_SUFFIX` that does not end in
  `.tar`: `restore` picks its method from the file name.

### Fixed
- Encryption no longer writes an unencrypted dump to disk first: `pg_dump` is piped into
  GPG. The key is passed through a temporary passphrase file, never the command line
  (it was visible in `ps`). `restore` does the same and streams the decryption.
- A failed or truncated dump never replaces a good one: dumps go to `last/.<name>.part`,
  are verified in full (custom/tar/directory with `pg_restore`, gzip with `gunzip`,
  through the decryption pipe), and only then renamed into place. Leftover `.part`
  files are removed by the next run.
- `restore` no longer reports success for a backup it could not read in full:
  - An encrypted dump that does not decrypt, or a damaged `.sql.gz` (gzip's checksum),
    encrypted or not, exits 1 with `❌ Could not read the backup (wrong
    BACKUP_ENCRYPTION_KEY or a damaged file).`
  - A restore that stops before it has read the whole backup (`pg_restore` refusing the
    archive, a lost connection) exits 1 with `❌ The restore stopped before it read the
    whole backup (see the errors above).`
  - In both cases a target database the restore created is dropped again, and an
    existing one gets `⚠️ '<db>' may be partially restored: drop it before retrying.`
  - Both checks apply to streamed restores: everything except local unencrypted
    custom-format and tar files and directory dumps. Damage in a local unencrypted
    custom-format file, any unencrypted `.tar` dump, or an unencrypted plain `.sql`
    dump still shows only as `pg_restore` / `psql` errors; an unencrypted custom-format
    object from the bucket that `pg_restore` rejects before its end fails with the
    stopped-early line.
  - A streamed `.tar` dump is read to its end, since `pg_restore` never reads a tar
    archive's tail.
  - The target name derived from the file name also strips a trailing `.dump`.
- Whole-number settings accept ASCII digits only: under the image's UTF-8 locale a
  digit such as `５` passed the check and failed later.
- `BACKUP_LATEST_TYPE=hardlink` pointed the `-latest` link at a path relative to the
  working directory.
- Glob characters in `POSTGRES_EXTRA_OPTS` / `POSTGRES_EXCLUDE_TABLES` are no longer
  expanded against files.
- `list`, `status` and `GET /backups` ignore dot files (`.part`, `.lock`, metrics).
- `restore` and `list --cleanup-preview` run as the CLI commands (`docker exec … restore`)
  found no `env.sh` next to their `/usr/local/bin` symlink: `restore` failed at once.

## [2026.7.0] - 2026-07-10

### Added
- **Zero-setup large files** — a shared Telegram app is baked into the image at
  build time (from CI secrets, never stored in the repo), so MTProto upload of
  backups up to 2 GB works without registering your own app. It only identifies
  the app to Telegram; your bot token and backups stay private. Opt out with
  `TELEGRAM_USE_DEFAULT_API=FALSE`, or set your own `TELEGRAM_API_ID` /
  `TELEGRAM_API_HASH` to be fully independent.
- **`TELEGRAM_USE_DEFAULT_API`** (default `TRUE`) — new setting to toggle the shared
  default app; also changeable at runtime via the REST API (`PATCH /config`). Set
  `FALSE` to require your own `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`.

## [2026.6.1](https://github.com/ganiyevuz/backupgram/compare/2026.6.0...2026.6.1) - 2026-06-06

### Added
- **REST API control surface** — opt-in (`REST_API_ENABLE=TRUE`) HTTP API behind a
  single admin bearer token (`REST_API_TOKEN`/`_FILE`): trigger backups, query
  status, list/download/delete backups, restore (from a stored file or a Telegram
  message id), and change a whitelisted set of runtime settings. Long operations
  run as async jobs (`202` + `GET /jobs/{id}`); when enabled the bundled
  `backupgram-api` becomes PID 1 and supervises `go-cron`. See `docs/REST_API.md`.
- **Auto-discover databases** — set `POSTGRES_DB_AUTODISCOVER=TRUE` to back up
  every non-template database on the server. The built-in `postgres` maintenance
  database and anything in `POSTGRES_DB_EXCLUDE` are skipped, `POSTGRES_DB`
  becomes optional, and the list is refreshed each run. Ignored when
  `POSTGRES_CLUSTER=TRUE`; an empty discovered set aborts the run.
- **`TELEGRAM_UPLOAD_METHOD` is runtime-configurable** via the REST API —
  `GET /config` reports it and `PATCH /config` accepts `smart` | `botapi` |
  `mtproto`, so the transport can be changed without recreating the container.
- **Restore works non-interactively** — `restore.sh` skips the `[y/N]` prompt when
  there is no TTY (the REST API and CI) instead of aborting under `set -e`, and
  **creates the target database if missing**, so restoring into a fresh database
  succeeds.
- **`/status`** **reports the effective schedule** — it reads the runtime override
  (falling back to the environment) instead of the boot-time `SCHEDULE`, so a
  schedule changed via `PATCH /config` is reflected immediately.
- **No spurious backup on schedule change** — restarting `go-cron` after a
  `SCHEDULE` update no longer re-triggers an immediate run via `BACKUP_ON_START`.

### Fixed
- **REST API auth is fail-closed** — bearer tokens are compared in constant time
  (`crypto/subtle`); the server refuses to start if `REST_API_ENABLE=TRUE` and no
  readable token is configured, rather than starting unauthenticated.
- **REST API path safety** — backup paths from API requests are resolved against
  the backup root (`filepath.Base` + prefix check), so download/delete cannot
  escape `BACKUP_DIR`; deletes additionally require `?confirm=true`.
- **Injection-safe restore** — the restore target database name is validated and
  created via `createdb --`, and SQL identifiers are single-quote escaped, so a
  crafted name cannot smuggle shell/SQL arguments.

### Security
- **MTProto large-file upload** — the bundled `tg-upload` Go binary sends backups
  up to 2 GB over MTProto when `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` are set,
  bypassing the Bot API's 50 MB document limit. Both also support Docker secrets
  via `TELEGRAM_API_ID_FILE` / `TELEGRAM_API_HASH_FILE`.

- **Upload method selector** — `TELEGRAM_UPLOAD_METHOD` (`smart` | `botapi` |
  `mtproto`) controls the transport. `smart` (default) picks Bot API for files
  under 50 MB and MTProto above it.

- **Multi-chat fan-out** — `TELEGRAM_CHAT_ID` accepts a comma-separated list of
  destinations. The backup is uploaded once and the resulting `file_id` (Bot API)
  or uploaded `InputFile` (MTProto) is reused to fan out to every chat without
  re-uploading.

- **Restore from Telegram** — `restore --from-telegram <message-id>` downloads a
  backup straight from the configured chat and restores it. Each backup message
  now carries a `🔖 Restore ID` in its caption (after both Bot API and MTProto
  sends) to make the source message easy to find.

- **Upload progress** — TTY-aware progress output (a live bar in a terminal,
  periodic log lines in non-interactive runs) with transfer speed and ETA.

- **Custom Telegram Bot API** — `TELEGRAM_API_URL` targets a self-hosted Bot API
  server (the 50 MB cap is enforced only against the official API).

- **PostgreSQL 18 images** — `18` / `18-alpine`, also published as `latest` /
  `alpine`.

- **Documentation & examples** — focused guides under `docs/` (Getting Started,
  Configuration, CLI, Architecture, Large Files, Build); standardized example
  compose files with a picker `examples/README.md`, a consolidated
  `examples/.env.example`, and a `multi-destination` example.

## [2026.6.0](https://github.com/ganiyevuz/backupgram/compare/2026.4.0...2026.6.0) - 2026-06-02

### Added
- `TELEGRAM_CHAT_ID` is now parsed as a comma-separated chat list to support
  fan-out delivery; a single chat id remains fully backward compatible.

- **Supported PostgreSQL versions are now 15–18** (`latest` = 18), changed from
  13–17.

- **Published platforms reduced to** **`linux/amd64`** **and** **`linux/arm64`** (from five),
  dropping the rarely-used emulated architectures.

- **Images now build in parallel — one CI job per target** (version × base),
  replacing the single monolithic multi-arch build. CI also gained
  run-concurrency cancellation, least-privilege permissions, and per-job timeouts.

### Changed
- **PostgreSQL 13 and 14 images** — PG13 reached end-of-life (Nov 2025); neither
  is built any longer. Pin to `15`–`18` instead (a newer `pg_dump` can still back
  up an older server).

- **`linux/arm/v7`,** **`linux/s390x`, and** **`linux/ppc64le`** **image variants** — no
  longer published.

### Removed
- Telegram upload failures now surface the API error reason instead of failing
  silently.

- `set -E -e -o pipefail` no longer aborts the run on the `[ -d … ] && rm`
  short-circuit.

- `verify_backup` no longer fails on uncompressed (`-Z0`) dumps.

- `encrypt_file` log output no longer pollutes the function's return value.

### Security
- **Path-traversal hardening** — the Telegram-supplied filename used by
  `restore --from-telegram` is sanitized with `filepath.Base`, so a malicious
  message filename cannot write outside the download directory.

## [2026.4.0](https://github.com/ganiyevuz/backupgram/releases/tag/2026.4.0) - 2026-04-17

### Changed
- **Major refactor and project restructuring** — reorganized the backup scripts
  and documentation and expanded the tool's feature set (rotating retention,
  GPG encryption, webhooks, cluster dumps, and restore tooling).

### Fixed






