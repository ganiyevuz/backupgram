# backupgram

![Docker Pulls](https://img.shields.io/docker/pulls/ganiyevuz/backupgram)
[![CI](https://github.com/ganiyevuz/backupgram/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ganiyevuz/backupgram/actions)
![License](https://img.shields.io/github/license/ganiyevuz/backupgram)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15%20%7C%2016%20%7C%2017%20%7C%2018-336791?logo=postgresql&logoColor=white)
[![Documentation Status](https://readthedocs.org/projects/backupgram/badge/?version=latest)](https://backupgram.readthedocs.io/en/latest/)

Automated PostgreSQL backups in Docker with rotating retention, Telegram notifications, optional GPG encryption, and built-in restore tooling.

Supports multiple databases, cluster-wide dumps (`pg_dumpall`), table exclusion, disk space checks, backup verification, webhook integrations, and Docker secrets. Available for **linux/amd64** and **linux/arm64** in both Debian and Alpine variants.

---

## Quick Start

Create a `docker-compose.yml` (or copy a ready-made one — see [Examples](#examples) below):

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
    image: ganiyevuz/backupgram:17
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

New to the project? Follow the **[Getting Started guide](docs/GETTING_STARTED.md)**
for a zero-to-restorable-backup walkthrough.

---

## Examples

Ready-to-run Compose files live in [`examples/`](examples/). Pick the one closest
to your need, copy it to `docker-compose.yml`, copy
[`.env.example`](examples/.env.example) to `.env` and fill in your values, then
`docker compose up -d`.

| Example | Use it when | Max file size | Extra service |
|---|---|---|---|
| [`minimal`](examples/docker-compose.minimal.yml) | Quickest start — one DB, daily, Telegram | 50 MB | none |
| [`full`](examples/docker-compose.full.yml) | Reference — every option, commented | 50 MB | none |
| [`large-files-mtproto`](examples/docker-compose.large-files-mtproto.yml) | Backups > 50 MB, simplest (**recommended**) | 2 GB | none |
| [`large-files-server`](examples/docker-compose.large-files-server.yml) | Backups > 50 MB, prefer a Bot API server | 2 GB | `telegram-bot-api` sidecar |
| [`multi-destination`](examples/docker-compose.multi-destination.yml) | Deliver each backup to several chats | 2 GB | none |

```sh
cp examples/docker-compose.minimal.yml docker-compose.yml
cp examples/.env.example .env        # then edit .env with real values
docker compose up -d
```

- **Large files (> 50 MB):** work out of the box up to 2 GB — every image ships a
  shared Telegram app for MTProto upload (details in **Large backups** below). The two
  `large-files-*` examples show using your own app or a self-hosted Bot API server.
- **Multiple chats:** set `TELEGRAM_CHAT_ID` to a comma-separated list — the backup
  is uploaded once and fanned out to every chat.

---

## Large backups (> 50 MB)

The official Telegram Bot API caps uploads at 50 MB. backupgram lifts that to **2 GB
over MTProto with zero setup** — every image ships a shared Telegram app, so large
backups are delivered automatically once `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`
are set. The shared app only identifies the app to Telegram; your bot token
authenticates and backups go to your own chat, so your data is never exposed. It is
baked into the public image (recoverable), so using your own is recommended.

- **Use your own app (recommended):** set `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`
  from <https://my.telegram.org/apps> (also accepted as `*_FILE` Docker secrets).
  They take precedence over the shared default.
- **Disable the shared default:** `TELEGRAM_USE_DEFAULT_API=FALSE` requires your own
  credentials (oversized backups are otherwise reported with a text alert).
- **Force a transport:** `TELEGRAM_UPLOAD_METHOD` = `smart` (default) | `botapi` | `mtproto`.

Full details and the self-hosted Bot API server route: **[docs/LARGE_FILES.md](docs/LARGE_FILES.md)**.

---

## Features

- **Scheduled backups** via `go-cron` with a configurable `SCHEDULE`.
- **Rotating retention** — `last` / `daily` / `weekly` / `monthly` slots via space-saving hard links.
- **Multiple databases** and **cluster-wide** dumps (`pg_dumpall`).
- **Auto-discover databases** — back up every non-template database on the server (`POSTGRES_DB_AUTODISCOVER`), narrowed by include globs (`POSTGRES_DB_INCLUDE`, e.g. `control,pharmacy_*`) and an exclude list (`POSTGRES_DB_EXCLUDE`); databases the login may not `CONNECT` to are skipped and logged.
- **Multiple formats** — gzip SQL, custom, directory (`-Fd`), each optionally **GPG AES-256 encrypted** (directory dumps excepted).
- **Safer pipeline** — encryption streams (`pg_dump` piped into GPG, no clear dump on disk, key never on a command line); every dump is written to a `.part` file, fully verified, and only then renamed into place, so a failed or truncated dump never replaces a good one. `backup` exits `1` when a database failed and `75` when another run holds the lock.
- **Row-level-security guard** — `BACKUP_RLS_GUARD=TRUE` refuses a dump that row-level security would silently cut short.
- **Snapshot layout** — `BACKUP_LAYOUT=snapshot` keeps timestamped names in every folder (weekly on Sundays, monthly on the 1st) and `last/` holds exactly the newest dump of each existing database.
- **Prometheus metrics + Grafana dashboard** — per-database backup age, size and result, written for node-exporter's textfile collector or served at `GET /metrics`, with a dashboard and alert rules in [`monitoring/`](monitoring/). See [docs/MONITORING.md](docs/MONITORING.md).
- **Telegram delivery** — Bot API for small files, **zero-setup MTProto upload up to 2 GB** (a shared app ships in the image), multi-chat fan-out.
- **Off-site copies (S3)** — keep a copy of every dump in any S3-compatible storage (AWS S3, Hetzner, Backblaze B2, Wasabi, Cloudflare R2, or RustFS/Garage/SeaweedFS on another machine): at the end of each backup run or from a separate uploader container (`BACKUPGRAM_MODE=s3-sync`), with remote retention tiers, `list --s3`, `restore --from-s3`, metrics and alerts. See [docs/OFFSITE.md](docs/OFFSITE.md).
- **Restore tooling** — interactive, by-file, cross-database, or **`--from-telegram`** / **`--from-s3`** disaster recovery.
- **Safety** — full backup verification, `pg_isready` and disk-space checks, a lock in `BACKUP_DIR` against overlapping runs.
- **Integrations** — webhooks (pre/post/error), custom `run-parts` hooks, Docker secrets (`*_FILE`).
- **REST API (opt-in)** — trigger/observe/restore/download/delete backups and change runtime settings over HTTP, behind a bearer token. See [docs/REST_API.md](docs/REST_API.md).

---

## Documentation

| Doc | What's in it |
|---|---|
| [Getting Started](docs/GETTING_STARTED.md) | First-backup walkthrough and troubleshooting |
| [Configuration Reference](docs/CONFIGURATION.md) | Every environment variable, Docker secrets, retention math |
| [CLI Commands](docs/CLI.md) | `backup`, `restore`, `list`, `status`, `help` with example output |
| [Architecture](docs/ARCHITECTURE.md) | Runtime chain, backup cycle, rotation model, format branches (C4 + mermaid) |
| [Large Files](docs/LARGE_FILES.md) | MTProto upload for backups over 50 MB |
| [Monitoring](docs/MONITORING.md) | Prometheus metrics, Grafana dashboard, alert rules |
| [Off-site copies](docs/OFFSITE.md) | S3-compatible off-site copies: both deployments, retention, providers, disaster recovery |
| [REST API](docs/REST_API.md) | Optional HTTP control surface: endpoints, auth, runtime config |
| [Build](docs/BUILD.md) | Multi-arch image builds |
| [Changelog](CHANGELOG.md) | Notable changes |

Full doc index: [docs/](docs/README.md).

---

## Configuration

All settings are environment variables; credentials also accept `*_FILE` (Docker
secrets) variants that take precedence over the plain value. The most common:

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | **required** | Connection + database name(s) |
| `POSTGRES_DB_AUTODISCOVER` | `FALSE` | Back up every non-template DB (makes `POSTGRES_DB` optional); narrow with `POSTGRES_DB_INCLUDE` (globs) and `POSTGRES_DB_EXCLUDE` |
| `SCHEDULE` | `@daily` | Cron expression for the backup schedule |
| `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` | `7` / `4` / `6` | Retention per rotation slot |
| `BACKUP_LAYOUT` | `period` | `period` or `snapshot` (timestamped names in every folder) |
| `BACKUP_RLS_GUARD` | `FALSE` | Refuse dumps that row-level security would cut short |
| `BACKUP_ENCRYPTION_KEY` | `""` | GPG passphrase (enables AES-256 encryption) |
| `METRICS_TEXTFILE_DIR` / `METRICS_ENABLE` | `""` / `FALSE` | Prometheus metrics: a textfile for node-exporter, and/or `GET /metrics` on `REST_API_PORT` |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | `""` | Telegram delivery (chat id list = fan-out) |
| `TELEGRAM_USE_DEFAULT_API` | `TRUE` | Use the image's built-in shared app for large-file (2 GB) upload; set `FALSE` to require your own `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` |
| `S3_BUCKET` / `S3_ENDPOINT` / `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | `""` / AWS / `""` / `""` | Off-site copies to S3-compatible storage (credentials also as `*_FILE`); `BACKUPGRAM_MODE=s3-sync` runs a separate uploader |

See the **[Configuration Reference](docs/CONFIGURATION.md)** for the complete list.

---

## CLI Commands

Available inside the container via `docker exec -it <container> <command>`:

| Command | Purpose |
|---|---|
| `backup` | Trigger a full backup cycle immediately |
| `restore` | Restore from a backup (interactive, by file, cross-db, `--from-telegram`, or `--from-s3`) |
| `list` | List backups by rotation slot (`--cleanup-preview` for a retention dry run, `--s3` for the off-site bucket) |
| `status` | Config, last result, inventory, disk usage, lock status |
| `help` | Quick command reference |

See **[CLI Commands](docs/CLI.md)** for usage and example output.

---

## How Backups Work

Each cycle writes every database's dump to a `.part` file in `last/`, verifies it,
renames it into place, then hard-links it into `daily/`, `weekly/`, and `monthly/`
(shared inode — no extra disk). A database that fails keeps its previous dump and
the run exits `1`. Retention cleanup runs once per run after all databases, over
every file of each slot; it leaves the copies of a database that failed in the run
alone, and is skipped when nothing was backed up.

> The `/backups` volume must be a POSIX filesystem with hardlink and symlink
> support. VFAT, exFAT, and SMB/CIFS are not supported. Use one backup folder per
> server/configuration: retention acts on every file in it.

Details and diagrams: **[Architecture](docs/ARCHITECTURE.md)**.

### Hooks

Place executable scripts in `/hooks`; they run via `run-parts` with `pre-backup`,
`post-backup`, or `error`. The bundled `00-webhook` implements the `WEBHOOK_*`
variables — add your own alongside it.

---

## Security Notes

- Run the container as `postgres:postgres` for least-privilege operation.
- Use Docker secrets (`*_FILE` variables) instead of plain-text passwords in production.
- Enable `BACKUP_ENCRYPTION_KEY` to encrypt backups at rest with GPG AES-256.
- The healthcheck runs on an internal port (`8080` by default) — do not expose it publicly unless needed.
- The optional **REST API** (`REST_API_ENABLE`) listens on `8081` (`REST_API_PORT`) behind a bearer token — bind it to loopback and front it with a TLS-terminating reverse proxy; never expose it directly. See [docs/REST_API.md](docs/REST_API.md).
- With `METRICS_ENABLE=TRUE`, `GET /metrics` on that same port needs **no token** and lists database names and backup results — keep the port on an internal network. See [docs/MONITORING.md](docs/MONITORING.md).

### File permissions for the backup volume

```sh
# Debian-based image (UID 999)
mkdir -p /var/opt/pgbackups && chown -R 999:999 /var/opt/pgbackups

# Alpine-based image (UID 70)
mkdir -p /var/opt/pgbackups && chown -R 70:70 /var/opt/pgbackups
```

---

## Image Tags

Images are published as `ganiyevuz/backupgram:<pg-version>[-alpine]`.

| Tag | Base | PostgreSQL |
|---|---|---|
| `latest`, `18`, `17`, `16`, `15` | Debian | Matching version (`latest` = 18) |
| `alpine`, `18-alpine`, `17-alpine`, ... | Alpine | Matching version (`alpine` = 18) |

---

## License

See [LICENSE](LICENSE) for details.
