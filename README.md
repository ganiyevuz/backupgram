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

- **Large files (> 50 MB):** the official Bot API caps uploads at 50 MB; the two
  `large-files-*` examples lift that to 2 GB (mtproto = built-in, no container;
  server = self-hosted Bot API daemon). See [docs/LARGE_FILES.md](docs/LARGE_FILES.md).
- **Multiple chats:** set `TELEGRAM_CHAT_ID` to a comma-separated list — the backup
  is uploaded once and fanned out to every chat.

---

## Features

- **Scheduled backups** via `go-cron` with a configurable `SCHEDULE`.
- **Rotating retention** — `last` / `daily` / `weekly` / `monthly` slots via space-saving hard links.
- **Multiple databases** and **cluster-wide** dumps (`pg_dumpall`).
- **Auto-discover databases** — back up every non-template database on the server (`POSTGRES_DB_AUTODISCOVER`), with an exclude list (`POSTGRES_DB_EXCLUDE`).
- **Multiple formats** — gzip SQL, directory (`-Fd`), each optionally **GPG AES-256 encrypted**.
- **Telegram delivery** — Bot API for small files, built-in **MTProto upload up to 2 GB**, multi-chat fan-out.
- **Restore tooling** — interactive, by-file, cross-database, or **`--from-telegram`** disaster recovery.
- **Safety** — backup verification, `pg_isready` and disk-space checks, `flock` against overlapping runs.
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
| `POSTGRES_DB_AUTODISCOVER` | `FALSE` | Back up every non-template DB (makes `POSTGRES_DB` optional); exclude names via `POSTGRES_DB_EXCLUDE` |
| `SCHEDULE` | `@daily` | Cron expression for the backup schedule |
| `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` | `7` / `4` / `6` | Retention per rotation slot |
| `BACKUP_ENCRYPTION_KEY` | `""` | GPG passphrase (enables AES-256 encryption) |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | `""` | Telegram delivery (chat id list = fan-out) |

See the **[Configuration Reference](docs/CONFIGURATION.md)** for the complete list.

---

## CLI Commands

Available inside the container via `docker exec -it <container> <command>`:

| Command | Purpose |
|---|---|
| `backup` | Trigger a full backup cycle immediately |
| `restore` | Restore from a backup (interactive, by file, cross-db, or `--from-telegram`) |
| `list` | List backups by rotation slot (`--cleanup-preview` for a retention dry run) |
| `status` | Config, last result, inventory, disk usage, lock status |
| `help` | Quick command reference |

See **[CLI Commands](docs/CLI.md)** for usage and example output.

---

## How Backups Work

Each cycle writes a timestamped file to `last/`, then hard-links it into `daily/`,
`weekly/`, and `monthly/` (shared inode — no extra disk). Retention cleanup runs
after each successful backup, pruning each slot independently.

> The `/backups` volume must be a POSIX filesystem with hardlink and symlink
> support. VFAT, exFAT, and SMB/CIFS are not supported.

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
