# Configuration Reference

Every setting is an environment variable passed to the container. Credentials
can also be supplied as Docker secrets via the `*_FILE` variants, which take
precedence over the plain variable.

- [Database Connection](#database-connection)
- [Backup Schedule and Retention](#backup-schedule-and-retention)
- [Encryption](#encryption)
- [Telegram Notifications](#telegram-notifications)
- [Webhooks](#webhooks)
- [Health and Advanced](#health-and-advanced)
- [Docker Secrets](#docker-secrets)
- [Retention Math](#retention-math)

---

## Database Connection

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | **required** | PostgreSQL hostname |
| `POSTGRES_PORT` | `5432` | PostgreSQL port |
| `POSTGRES_USER` | **required** | PostgreSQL user |
| `POSTGRES_PASSWORD` | **required** | PostgreSQL password |
| `POSTGRES_DB` | **required** | Database name(s), comma-separated for multiple |
| `POSTGRES_EXTRA_OPTS` | `-Z1` | Extra flags passed to `pg_dump` / `pg_dumpall` (word-split, so `-Z0 -Fd` works) |
| `POSTGRES_CLUSTER` | `FALSE` | Set `TRUE` to use `pg_dumpall` for a full cluster dump |
| `POSTGRES_EXCLUDE_TABLES` | `""` | Comma-separated tables to exclude from the dump |
| `POSTGRES_CONNECT_TIMEOUT` | `30` | Seconds to wait for the `pg_isready` connectivity check |

> The local `pg_dump` client major version must match the server. Pick the image
> tag accordingly (e.g. `:16` against a PostgreSQL 16 server).

---

## Backup Schedule and Retention

| Variable | Default | Description |
|---|---|---|
| `SCHEDULE` | `@daily` | Cron expression ([syntax reference](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules)) |
| `BACKUP_ON_START` | `FALSE` | Run a backup immediately on container start |
| `VALIDATE_ON_START` | `TRUE` | Validate configuration on startup (runs `env.sh` standalone) |
| `BACKUP_DIR` | `/backups` | Directory inside the container to store backups |
| `BACKUP_SUFFIX` | `.sql.gz` | Filename suffix for backup files |
| `BACKUP_LATEST_TYPE` | `symlink` | How to create the `latest` pointer: `symlink`, `hardlink`, or `none` |
| `BACKUP_KEEP_DAYS` | `7` | Days to retain daily backups |
| `BACKUP_KEEP_WEEKS` | `4` | Weeks to retain weekly backups |
| `BACKUP_KEEP_MONTHS` | `6` | Months to retain monthly backups |
| `BACKUP_KEEP_MINS` | `1440` | Minutes to retain backups in the `last` folder |

See [Retention Math](#retention-math) for how weeks/months convert to the day
counts used by `find -mtime`.

---

## Encryption

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ENCRYPTION_KEY` | `""` | GPG passphrase for AES-256 encryption. Leave empty to disable. When set, an extra `.gpg` suffix is appended and the file is symmetrically encrypted. |

---

## Telegram Notifications

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | `""` | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | `""` | Chat ID(s) — comma-separated for multiple destinations (get it from [@userinfobot](https://t.me/userinfobot)) |
| `TELEGRAM_API_ID` | `""` | Telegram app `api_id` ([my.telegram.org](https://my.telegram.org/apps)). Enables built-in MTProto upload of backups up to 2 GB |
| `TELEGRAM_API_HASH` | `""` | Telegram app `api_hash`. Required together with `TELEGRAM_API_ID` |
| `TELEGRAM_THREAD_ID` | `""` | Message thread ID for supergroup topics (applied only when a single chat is configured) |
| `TELEGRAM_UPLOAD_METHOD` | `smart` | Backup-file transport: `smart` (auto by size), `botapi` (always Bot API via `curl`), or `mtproto` (always the bundled binary; requires `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`) |
| `TELEGRAM_NOTIFY_ON` | `all` | When to send notifications: `all`, `failure`, `success`, `none` |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Bot API base URL. A custom (self-hosted) URL bypasses the 50 MB document limit check |
| `PROJECT_NAME` | `""` | Label included in Telegram captions and alerts |

Backup files under 50 MB are sent as documents via the Bot API. Larger files
(up to 2 GB) are uploaded over MTProto by the bundled `tg-upload` binary when
`TELEGRAM_API_ID` and `TELEGRAM_API_HASH` are set; otherwise they are reported
with a text alert. See [LARGE_FILES.md](LARGE_FILES.md).

> The 50 MB limit is enforced **only** when `TELEGRAM_API_URL` is the official
> `https://api.telegram.org`. A custom self-hosted Bot API URL bypasses it.

---

## Webhooks

| Variable | Default | Description |
|---|---|---|
| `WEBHOOK_URL` | `""` | Called on both success and error |
| `WEBHOOK_ERROR_URL` | `""` | Called only on error |
| `WEBHOOK_PRE_BACKUP_URL` | `""` | Called before backup starts |
| `WEBHOOK_POST_BACKUP_URL` | `""` | Called after successful backup |
| `WEBHOOK_EXTRA_ARGS` | `""` | Additional `curl` arguments for webhook calls |

All webhook calls send a JSON payload with `status`, `hostname`, `timestamp`,
`database`, and `project` fields. Implemented by the bundled `00-webhook` hook.

---

## Health and Advanced

| Variable | Default | Description |
|---|---|---|
| `HEALTHCHECK_PORT` | `8080` | Port for the health check endpoint (served by `go-cron`) |
| `BACKUP_MAX_AGE_HOURS` | `48` | Hours before a backup is considered stale (used by healthcheck) |
| `BACKUP_MIN_DISK_SPACE` | `100` | Minimum free disk space (MB) required before starting a backup |
| `TZ` | `""` | POSIX timezone (e.g. `Europe/Berlin`) for schedule evaluation |

---

## Docker Secrets

For any credential, a `*_FILE` variant pointing at a file (typically a mounted
Docker secret) takes precedence over the plain variable:

- `POSTGRES_USER_FILE`, `POSTGRES_PASSWORD_FILE`, `POSTGRES_DB_FILE`, `POSTGRES_PASSFILE_STORE`
- `TELEGRAM_BOT_TOKEN_FILE`, `TELEGRAM_CHAT_ID_FILE`, `TELEGRAM_API_ID_FILE`, `TELEGRAM_API_HASH_FILE`

---

## Retention Math

`env.sh` converts the human-friendly `BACKUP_KEEP_*` values into the day counts
that `find -mtime` uses during cleanup:

```sh
KEEP_WEEKS=$((BACKUP_KEEP_WEEKS  * 7  + 1))   # e.g. 4 weeks  -> 29 days
KEEP_MONTHS=$((BACKUP_KEEP_MONTHS * 31 + 1))  # e.g. 6 months -> 187 days
```

`last/` is pruned by minutes (`BACKUP_KEEP_MINS`), `daily/` by `BACKUP_KEEP_DAYS`,
and `weekly/`/`monthly/` by the computed day counts above. Each folder is cleaned
independently after every successful backup. Use `list --cleanup-preview` to see
exactly what the current policy would delete.
