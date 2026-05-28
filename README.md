# postgres-backup-telegram

![Docker Pulls](https://img.shields.io/docker/pulls/ganiyevuz/postgres-backup-telegram)
[![CI](https://github.com/ganiyevuz/docker-postgres-backup-telegram/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ganiyevuz/docker-postgres-backup-telegram/actions)
![License](https://img.shields.io/github/license/ganiyevuz/docker-postgres-backup-telegram)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-13%20%7C%2014%20%7C%2015%20%7C%2016%20%7C%2017-336791?logo=postgresql&logoColor=white)

Automated PostgreSQL backups in Docker with rotating retention, Telegram notifications, optional GPG encryption, and built-in restore tooling.

Supports multiple databases, cluster-wide dumps (`pg_dumpall`), table exclusion, disk space checks, backup verification, webhook integrations, and Docker secrets. Available for **linux/amd64**, **linux/arm64**, **linux/arm/v7**, **linux/s390x**, and **linux/ppc64le** in both Debian and Alpine variants.

---

## Quick Start

Create a `docker-compose.yml` (see also [`examples/`](examples/)):

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_DB: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
    volumes:
      - pgdata:/var/lib/postgresql/data

  backup:
    image: ganiyevuz/postgres-backup-telegram:17
    depends_on:
      - postgres
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      SCHEDULE: "@daily"
      TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
      TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
    volumes:
      - backups:/backups

volumes:
  pgdata:
  backups:
```

```sh
docker compose up -d
```

For a full-featured example with encryption, webhooks, retention tuning, and more, see [`examples/docker-compose.full.yml`](examples/docker-compose.full.yml).

---

## Environment Variables

### Database Connection

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | **required** | PostgreSQL hostname |
| `POSTGRES_PORT` | `5432` | PostgreSQL port |
| `POSTGRES_USER` | **required** | PostgreSQL user |
| `POSTGRES_PASSWORD` | **required** | PostgreSQL password |
| `POSTGRES_DB` | **required** | Database name(s), comma-separated for multiple |
| `POSTGRES_EXTRA_OPTS` | `-Z1` | Extra flags passed to `pg_dump` / `pg_dumpall` |
| `POSTGRES_CLUSTER` | `FALSE` | Set `TRUE` to use `pg_dumpall` for a full cluster dump |
| `POSTGRES_EXCLUDE_TABLES` | `""` | Comma-separated tables to exclude from the dump |
| `POSTGRES_CONNECT_TIMEOUT` | `30` | Seconds to wait for `pg_isready` connectivity check |

Docker secrets alternatives: `POSTGRES_USER_FILE`, `POSTGRES_PASSWORD_FILE`, `POSTGRES_DB_FILE`, `POSTGRES_PASSFILE_STORE`.

### Backup Schedule and Retention

| Variable | Default | Description |
|---|---|---|
| `SCHEDULE` | `@daily` | Cron expression ([syntax reference](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules)) |
| `BACKUP_ON_START` | `FALSE` | Run a backup immediately on container start |
| `VALIDATE_ON_START` | `TRUE` | Validate configuration on startup |
| `BACKUP_DIR` | `/backups` | Directory inside the container to store backups |
| `BACKUP_SUFFIX` | `.sql.gz` | Filename suffix for backup files |
| `BACKUP_LATEST_TYPE` | `symlink` | How to create the `latest` pointer: `symlink`, `hardlink`, or `none` |
| `BACKUP_KEEP_DAYS` | `7` | Days to retain daily backups |
| `BACKUP_KEEP_WEEKS` | `4` | Weeks to retain weekly backups |
| `BACKUP_KEEP_MONTHS` | `6` | Months to retain monthly backups |
| `BACKUP_KEEP_MINS` | `1440` | Minutes to retain backups in the `last` folder |

### Encryption

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ENCRYPTION_KEY` | `""` | GPG passphrase for AES-256 encryption. Leave empty to disable |

### Telegram Notifications

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | | Chat ID(s) — comma-separated for multiple destinations (get it from [@userinfobot](https://t.me/userinfobot)) |
| `TELEGRAM_API_ID` | `""` | Telegram app `api_id` ([my.telegram.org](https://my.telegram.org/apps)). Enables built-in MTProto upload of backups up to 2 GB |
| `TELEGRAM_API_HASH` | `""` | Telegram app `api_hash`. Required together with `TELEGRAM_API_ID` |
| `TELEGRAM_THREAD_ID` | `""` | Message thread ID for supergroup topics (applied only when a single chat is configured) |
| `TELEGRAM_UPLOAD_METHOD` | `smart` | Backup-file transport: `smart` (auto by size), `botapi` (always Bot API via `curl`), or `mtproto` (always the bundled binary; requires `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`) |
| `TELEGRAM_NOTIFY_ON` | `all` | When to send notifications: `all`, `failure`, `success`, `none` |
| `PROJECT_NAME` | `""` | Label included in Telegram captions and alerts |

Docker secrets alternatives: `TELEGRAM_BOT_TOKEN_FILE`, `TELEGRAM_CHAT_ID_FILE`, `TELEGRAM_API_ID_FILE`, `TELEGRAM_API_HASH_FILE`.

Backup files under 50 MB are sent as documents via the Bot API. Larger files (up to 2 GB) are uploaded over MTProto by the bundled `tg-upload` binary when `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` are set; otherwise they are reported with a text alert. See [docs/LARGE_FILES.md](docs/LARGE_FILES.md).

### Webhooks

| Variable | Default | Description |
|---|---|---|
| `WEBHOOK_URL` | | Called on both success and error |
| `WEBHOOK_ERROR_URL` | | Called only on error |
| `WEBHOOK_PRE_BACKUP_URL` | | Called before backup starts |
| `WEBHOOK_POST_BACKUP_URL` | | Called after successful backup |
| `WEBHOOK_EXTRA_ARGS` | | Additional `curl` arguments for webhook calls |

All webhook calls send a JSON payload with `status`, `hostname`, `timestamp`, `database`, and `project` fields.

### Health and Advanced

| Variable | Default | Description |
|---|---|---|
| `HEALTHCHECK_PORT` | `8080` | Port for the health check endpoint |
| `BACKUP_MAX_AGE_HOURS` | `48` | Hours before a backup is considered stale (used by healthcheck) |
| `BACKUP_MIN_DISK_SPACE` | `100` | Minimum free disk space (MB) required before starting a backup |
| `TZ` | | POSIX timezone (e.g. `Europe/Berlin`) for schedule evaluation |

---

## CLI Commands

All commands are available inside the container via `docker exec`:

### `backup` -- Trigger a manual backup

Runs a full backup cycle immediately: dump, verify, encrypt (if enabled), rotate, send to Telegram, and clean old files.

```sh
docker exec -it my-backup backup
```

```
Checking database connectivity (timeout: 30s)...
Database is reachable.
Disk space OK (45032MB available).
Creating dump of mydb database from postgres...
Backup created: /backups/last/mydb-20260416-143000.sql.gz (42M, 8s)
Backup sent to Telegram.
Cleaning older files for mydb...
----------------------------------------
Backup completed in 12s: 1 succeeded, 0 failed
----------------------------------------
```

### `restore` -- Restore from a backup

Without arguments, shows an interactive picker. With a file path, restores directly. Auto-detects format (`.sql.gz`, `.sql.gz.gpg`, directory, tar.gz) and handles GPG decryption automatically.

```sh
# Interactive mode -- pick from a numbered list
docker exec -it my-backup restore

# Direct restore from a specific file
docker exec -it my-backup restore /backups/last/mydb-latest.sql.gz

# Restore into a different database
docker exec -it my-backup restore /backups/daily/mydb-20260416.sql.gz mydb_staging
```

Interactive mode output:

```
----------------------------------------
  Available Backups
----------------------------------------
  [ 1] 42M     2026-04-16 14:30  last/mydb-20260416-143000.sql.gz
  [ 2] 42M     2026-04-16 14:30  last/mydb-latest.sql.gz
  [ 3] 42M     2026-04-16 02:00  daily/mydb-20260416.sql.gz
  [ 4] 38M     2026-04-14 02:00  weekly/mydb-202616.sql.gz
  [ 5] 35M     2026-04-01 02:00  monthly/mydb-202604.sql.gz
----------------------------------------

Select backup number [1-5]: 3

Selected: /backups/daily/mydb-20260416.sql.gz

Target database (leave empty to auto-detect): 

----------------------------------------
Restore Details:
  Source: /backups/daily/mydb-20260416.sql.gz
  Target: mydb@postgres:5432
----------------------------------------

This will restore data into database 'mydb'.
Existing data may be overwritten.

Continue? [y/N]: y
Detected compressed SQL dump.
Restoring mydb...
----------------------------------------
Restore completed in 15s: mydb@postgres
----------------------------------------
```

### `list` -- List all backups

Shows all backup files grouped by rotation slot with sizes, dates, and indicators for `[latest]` and `[encrypted]` files.

```sh
# List all backups
docker exec -it my-backup list

# Filter by database name
docker exec -it my-backup list mydb

# Preview what the retention policy would delete (dry run)
docker exec -it my-backup list --cleanup-preview
```

List output:

```
+======================================+
|  LAST                                |
+======================================+
|  42M   2026-04-16 14:30  mydb-20260416-143000.sql.gz
|  42M   2026-04-16 14:30  mydb-latest.sql.gz [latest]
+======================================+

+======================================+
|  DAILY                               |
+======================================+
|  42M   2026-04-16 02:00  mydb-20260416.sql.gz
|  41M   2026-04-15 02:00  mydb-20260415.sql.gz
|  42M   2026-04-16 02:00  mydb-latest.sql.gz [latest]
+======================================+

Disk usage: 168M total
Available:  45G
```

Cleanup preview output:

```
========================================
  Cleanup Preview (dry run)
========================================

Current retention policy:
  Last:    keep 1440 minutes
  Daily:   keep 7 days
  Weekly:  keep 29 days
  Monthly: keep 187 days

Would delete from daily/:
  (trash)  41M  2026-04-08 02:00  mydb-20260408.sql.gz
  (trash)  40M  2026-04-07 02:00  mydb-20260407.sql.gz

----------------------------------------
Total: 2 files would be deleted
----------------------------------------
```

### `status` -- System status overview

Shows current configuration, last backup result, backup inventory counts, disk usage, and lock status at a glance.

```sh
docker exec -it my-backup status
```

```
========================================
  Backup System Status
========================================

Configuration:
  Host:       postgres
  Port:       5432
  Databases:  mydb,analytics
  Schedule:   0 2 * * *
  Cluster:    FALSE
  Project:    My Project
  Encryption: enabled (AES-256)
  Telegram:   enabled (notify: all)

Retention Policy:
  Keep last:    1440 minutes
  Keep daily:   7 days
  Keep weekly:  4 weeks
  Keep monthly: 6 months

Last Backup:
  Status:     OK
  Time:       2026-04-16 02:00:12 (14h ago)

Backup Inventory:
  last:      3 files
  daily:     7 files
  weekly:    4 files
  monthly:   6 files

Disk Usage:
  Backups:    1.2G
  Available:  45G
  Min space:  100MB

Backup Lock:  idle (not running)
========================================
```

### `help` -- Show available commands

Prints a quick reference of all commands, usage examples, and key environment variables.

```sh
docker exec -it my-backup help
```

---

## How Backups Work

Each backup cycle creates a timestamped file in the `last` folder, then hard-links it into `daily`, `weekly`, and `monthly` folders. Hard links save disk space -- all folders reference the same data on disk.

```
/backups/
  last/
    mydb-20260416-020000.sql.gz       # every backup
    mydb-latest.sql.gz -> (symlink)
  daily/
    mydb-20260416.sql.gz              # latest backup of the day
  weekly/
    mydb-202616.sql.gz                # latest backup of the ISO week
  monthly/
    mydb-202604.sql.gz                # latest backup of the month
```

Retention cleanup runs after each successful backup, removing files older than the configured thresholds. Each folder is cleaned independently using its own `BACKUP_KEEP_*` variable.

A lock file (`flock`) prevents overlapping backup runs.

> The `/backups` volume must be a POSIX-compliant filesystem with hardlink and symlink support. VFAT, exFAT, and SMB/CIFS are not supported.

---

## Hooks

Place executable scripts in the `/hooks` directory inside the container. They are invoked via `run-parts` with one of three arguments:

- `pre-backup` -- before the backup starts
- `post-backup` -- after a successful backup
- `error` -- when a backup fails

The included `00-webhook` hook implements the webhook environment variables described above. Add your own scripts alongside it for custom integrations.

---

## Security Notes

- Run the container as `postgres:postgres` for least-privilege operation.
- Use Docker secrets (`*_FILE` variables) instead of plain-text passwords in production.
- Enable `BACKUP_ENCRYPTION_KEY` to encrypt backups at rest with GPG AES-256.
- The healthcheck runs on an internal port (`8080` by default) -- do not expose it publicly unless needed.

### File permissions for the backup volume

```sh
# Debian-based image (UID 999)
mkdir -p /var/opt/pgbackups && chown -R 999:999 /var/opt/pgbackups

# Alpine-based image (UID 70)
mkdir -p /var/opt/pgbackups && chown -R 70:70 /var/opt/pgbackups
```

---

## Image Tags

Images are published as `ganiyevuz/postgres-backup-telegram:<pg-version>[-alpine]`.

| Tag | Base | PostgreSQL |
|---|---|---|
| `17`, `16`, `15`, `14`, `13` | Debian | Matching version |
| `17-alpine`, `16-alpine`, ... | Alpine | Matching version |

---

## License

See [LICENSE](LICENSE) for details.
