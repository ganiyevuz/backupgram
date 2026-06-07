# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Image tags track the bundled PostgreSQL major version (15–18); project releases
are tagged separately using CalVer (`YYYY.M.PATCH`).

## [Unreleased]

## [2026.6.1] - 2026-06-06

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

### Fixed
- **Restore works non-interactively** — `restore.sh` skips the `[y/N]` prompt when
  there is no TTY (the REST API and CI) instead of aborting under `set -e`, and
  **creates the target database if missing**, so restoring into a fresh database
  succeeds.
- **`/status` reports the effective schedule** — it reads the runtime override
  (falling back to the environment) instead of the boot-time `SCHEDULE`, so a
  schedule changed via `PATCH /config` is reflected immediately.
- **No spurious backup on schedule change** — restarting `go-cron` after a
  `SCHEDULE` update no longer re-triggers an immediate run via `BACKUP_ON_START`.

### Security
- **REST API auth is fail-closed** — bearer tokens are compared in constant time
  (`crypto/subtle`); the server refuses to start if `REST_API_ENABLE=TRUE` and no
  readable token is configured, rather than starting unauthenticated.
- **REST API path safety** — backup paths from API requests are resolved against
  the backup root (`filepath.Base` + prefix check), so download/delete cannot
  escape `BACKUP_DIR`; deletes additionally require `?confirm=true`.
- **Injection-safe restore** — the restore target database name is validated and
  created via `createdb --`, and SQL identifiers are single-quote escaped, so a
  crafted name cannot smuggle shell/SQL arguments.

## [2026.6.0] - 2026-06-02

### Added
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

### Changed
- `TELEGRAM_CHAT_ID` is now parsed as a comma-separated chat list to support
  fan-out delivery; a single chat id remains fully backward compatible.
- **Supported PostgreSQL versions are now 15–18** (`latest` = 18), changed from
  13–17.
- **Published platforms reduced to `linux/amd64` and `linux/arm64`** (from five),
  dropping the rarely-used emulated architectures.
- **Images now build in parallel — one CI job per target** (version × base),
  replacing the single monolithic multi-arch build. CI also gained
  run-concurrency cancellation, least-privilege permissions, and per-job timeouts.

### Removed
- **PostgreSQL 13 and 14 images** — PG13 reached end-of-life (Nov 2025); neither
  is built any longer. Pin to `15`–`18` instead (a newer `pg_dump` can still back
  up an older server).
- **`linux/arm/v7`, `linux/s390x`, and `linux/ppc64le` image variants** — no
  longer published.

### Security
- **Path-traversal hardening** — the Telegram-supplied filename used by
  `restore --from-telegram` is sanitized with `filepath.Base`, so a malicious
  message filename cannot write outside the download directory.

## [2026.4.0] - 2026-04-17

### Changed
- **Major refactor and project restructuring** — reorganized the backup scripts
  and documentation and expanded the tool's feature set (rotating retention,
  GPG encryption, webhooks, cluster dumps, and restore tooling).

### Fixed
- Telegram upload failures now surface the API error reason instead of failing
  silently.
- `set -E -e -o pipefail` no longer aborts the run on the `[ -d … ] && rm`
  short-circuit.
- `verify_backup` no longer fails on uncompressed (`-Z0`) dumps.
- `encrypt_file` log output no longer pollutes the function's return value.

[Unreleased]: https://github.com/ganiyevuz/backupgram/compare/2026.6.1...HEAD
[2026.6.1]: https://github.com/ganiyevuz/backupgram/compare/2026.6.0...2026.6.1
[2026.6.0]: https://github.com/ganiyevuz/backupgram/compare/2026.4.0...2026.6.0
[2026.4.0]: https://github.com/ganiyevuz/backupgram/releases/tag/2026.4.0
