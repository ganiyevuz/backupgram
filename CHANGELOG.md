# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Image tags track the bundled PostgreSQL major version (13–17) rather than a
project semantic version, so changes are grouped under `[Unreleased]` until a
release scheme is adopted.

## [Unreleased]

### Added
- **Restore from Telegram** — `restore --from-telegram <message-id>` downloads a
  backup straight from the configured chat and restores it. Each backup message
  now carries a `🔖 Restore ID` in its caption (embedded after both Bot API and
  MTProto sends) to make the source message easy to find.
- **Multi-chat fan-out** — `TELEGRAM_CHAT_ID` accepts a comma-separated list of
  destinations. The backup is uploaded once and the resulting `file_id` is
  reused to fan out to every chat without re-uploading.
- **Upload method selector** — `TELEGRAM_UPLOAD_METHOD` (`smart` | `botapi` |
  `mtproto`) controls the transport. `smart` (default) picks Bot API for files
  under 50 MB and MTProto above it.
- **MTProto large-file upload** — the bundled `tg-upload` Go binary sends
  backups up to 2 GB over MTProto when `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`
  are set, bypassing the Bot API's 50 MB document limit.
- **Upload progress** — TTY-aware progress output (a live bar in a terminal,
  periodic log lines in non-interactive runs) with transfer speed and ETA.

### Changed
- `TELEGRAM_CHAT_ID` is now parsed as a comma-separated chat list to support
  fan-out delivery; a single chat id remains fully backward compatible.

[Unreleased]: https://github.com/ganiyevuz/postgres-backup-telegram/commits/main
