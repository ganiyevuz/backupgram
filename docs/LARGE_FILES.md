# Sending Backups Larger Than 50 MB

The official Telegram Bot API (`https://api.telegram.org`) caps uploads at **50 MB**. To send larger backups, pick one of two routes.

## Route A — Built-in MTProto uploader (recommended, no extra service)

The image bundles `tg-upload`, a static binary that uploads over MTProto (up to **2 GB**) directly — no sidecar container. Backups ≤ 50 MB still go through the normal Bot API path; only larger files use MTProto.

1. Get `api_id` and `api_hash` from <https://my.telegram.org/apps>.
2. Set these on the `backup` service (in addition to `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`):
   - `TELEGRAM_API_ID`
   - `TELEGRAM_API_HASH`
3. Leave `TELEGRAM_API_URL` unset (defaults to the official API).

See [`examples/docker-compose.large-files-mtproto.yml`](../examples/docker-compose.large-files-mtproto.yml).

**Targets:** the bot must be a member of the destination. Supergroups/channels (`-100…` ids) and basic groups work. Sending to an individual user requires that user to have started the bot.

**Multiple chats:** `TELEGRAM_CHAT_ID` accepts a comma-separated list (e.g. `-1001111111111,12345678`). The backup is uploaded once and delivered to every chat (`file_id` reuse for ≤50 MB, a single MTProto upload reused for larger files). `TELEGRAM_THREAD_ID` is honoured only when exactly one chat is configured.

`TELEGRAM_API_ID` / `TELEGRAM_API_HASH` also support Docker secrets via `TELEGRAM_API_ID_FILE` / `TELEGRAM_API_HASH_FILE`.

## Route B — Self-hosted Bot API server

Run the official `telegram-bot-api` daemon as a sidecar and point `TELEGRAM_API_URL` at it. The existing `curl` path then handles files up to 2 GB unchanged. This is heavier (an extra service + volume) but keeps everything on the Bot API.

See [`examples/docker-compose.large-files.yml`](../examples/docker-compose.large-files.yml).

## Forcing a transport with `TELEGRAM_UPLOAD_METHOD`

By default delivery is `smart` — it picks the transport automatically by file size and configuration. Set `TELEGRAM_UPLOAD_METHOD` to force one:

- `smart` (default) — ≤50 MB via the Bot API; larger files via a self-hosted server (if `TELEGRAM_API_URL` is custom) or MTProto (if `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` are set).
- `botapi` — always the Bot API (`curl`) against `TELEGRAM_API_URL`. On the official API, files >50 MB are kept locally with a warning (never silently switched to MTProto).
- `mtproto` — always the bundled `tg-upload` binary, for files of any size. Requires `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` (validated at startup).

An explicitly chosen method is never silently overridden; if it cannot deliver a file, the backup is kept locally and the run continues.

## Which to choose?

| | Route A (MTProto binary) | Route B (self-hosted server) |
|---|---|---|
| Extra service | none | `telegram-bot-api` container |
| Max size | 2 GB | 2 GB |
| Needs `api_id`/`api_hash` | yes | yes |
| Best for | most users | those already running a Bot API server |
