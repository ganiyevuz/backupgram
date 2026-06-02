# Examples

Ready-to-run Compose files. Each is self-contained — pick the one closest to your need, copy it to `docker-compose.yml`, and supply secrets via a `.env` file.

```sh
cp examples/docker-compose.minimal.yml docker-compose.yml
cp examples/.env.example .env        # then edit .env with real values
docker compose up -d
```

## Which one do I pick?

| Example | Use it when | Max file size | Extra service |
|---|---|---|---|
| [`docker-compose.minimal.yml`](docker-compose.minimal.yml) | Quickest start — one DB, daily, Telegram | 50 MB | none |
| [`docker-compose.full.yml`](docker-compose.full.yml) | Reference — every option, commented | 50 MB | none |
| [`docker-compose.large-files-mtproto.yml`](docker-compose.large-files-mtproto.yml) | Backups > 50 MB, simplest (**recommended**) | 2 GB | none |
| [`docker-compose.large-files-server.yml`](docker-compose.large-files-server.yml) | Backups > 50 MB, prefer a Bot API server | 2 GB | `telegram-bot-api` sidecar |
| [`docker-compose.multi-destination.yml`](docker-compose.multi-destination.yml) | Deliver each backup to several chats | 2 GB | none |

All of them read secrets from [`.env.example`](.env.example) — copy it to `.env` and fill in your values.

## Notes

- **Large files (> 50 MB):** the official Telegram Bot API caps uploads at 50 MB. The two `large-files-*` examples lift that to 2 GB — the **mtproto** one uses the image's built-in uploader (no extra container), the **server** one runs a self-hosted Bot API daemon. Both need `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`. See [docs/LARGE_FILES.md](../docs/LARGE_FILES.md).
- **Multiple chats:** set `TELEGRAM_CHAT_ID` to a comma-separated list. The backup is uploaded once and fanned out to every chat.
- **Restore:** every backup message's caption carries a `🔖 Restore ID`; recover with `docker exec -it <container> restore --from-telegram <id>`. See [docs/CLI.md](../docs/CLI.md).
- **Full variable reference:** [docs/CONFIGURATION.md](../docs/CONFIGURATION.md).
