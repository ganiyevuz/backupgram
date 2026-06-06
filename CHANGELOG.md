# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Image tags track the bundled PostgreSQL major version (15–18) rather than a
project semantic version, so changes are grouped under `[Unreleased]` until a
release scheme is adopted.

## [Unreleased]

### Added
- **Auto-discover databases** — set `POSTGRES_DB_AUTODISCOVER=TRUE` to back up
  every non-template database on the server. The built-in `postgres` maintenance
  database and anything in `POSTGRES_DB_EXCLUDE` are skipped, `POSTGRES_DB`
  becomes optional, and the list is refreshed each run. Ignored when
  `POSTGRES_CLUSTER=TRUE`; an empty discovered set aborts the run.
- **Restore from Telegram** — `restore --from-telegram <message-id>` downloads a
  backup straight from the configured chat and restores it. Each backup message
  now carries a `🔖 Restore ID` in its caption (embedded after both Bot API and
  MTProto sends) to make the source message easy to find.
- **Multi-chat fan-out** — `TELEGRAM_CHAT_ID` accepts a comma-separated list of
  destinations. The backup is uploaded once and the resulting `file_id` (Bot API)
  or uploaded `InputFile` (MTProto) is reused to fan out to every chat without
  re-uploading.
- **Upload method selector** — `TELEGRAM_UPLOAD_METHOD` (`smart` | `botapi` |
  `mtproto`) controls the transport. `smart` (default) picks Bot API for files
  under 50 MB and MTProto above it.
- **MTProto large-file upload** — the bundled `tg-upload` Go binary sends
  backups up to 2 GB over MTProto when `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`
  are set, bypassing the Bot API's 50 MB document limit. Both also support
  Docker secrets via `TELEGRAM_API_ID_FILE` / `TELEGRAM_API_HASH_FILE`.
- **Upload progress** — TTY-aware progress output (a live bar in a terminal,
  periodic log lines in non-interactive runs) with transfer speed and ETA.
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
- **Images now build in parallel — one CI job per target** (version × base) —
  replacing the single monolithic multi-arch build, which was faster and
  isolated each target's failures. CI also gained run-concurrency cancellation,
  least-privilege permissions, and per-job timeouts.

### Removed
- **PostgreSQL 13 and 14 images** — PG13 reached end-of-life (Nov 2025); neither
  is built any longer. Pin to `15`–`18` instead (a newer `pg_dump` can still
  back up an older server).
- **`linux/arm/v7`, `linux/s390x`, and `linux/ppc64le` image variants** — no
  longer published.

### Security
- **Path-traversal hardening** — the Telegram-supplied filename used by
  `restore --from-telegram` is sanitized with `filepath.Base`, so a malicious
  message filename cannot write outside the download directory.

[Unreleased]: https://github.com/ganiyevuz/postgres-backup-telegram/commits/main
