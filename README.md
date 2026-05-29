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

New to the project? Follow the **[Getting Started guide](docs/GETTING_STARTED.md)**
for a zero-to-restorable-backup walkthrough. For a full-featured example with
encryption, webhooks, and retention tuning, see
[`examples/docker-compose.full.yml`](examples/docker-compose.full.yml).

---

## Features

- **Scheduled backups** via `go-cron` with a configurable `SCHEDULE`.
- **Rotating retention** — `last` / `daily` / `weekly` / `monthly` slots via space-saving hard links.
- **Multiple databases** and **cluster-wide** dumps (`pg_dumpall`).
- **Multiple formats** — gzip SQL, directory (`-Fd`), each optionally **GPG AES-256 encrypted**.
- **Telegram delivery** — Bot API for small files, built-in **MTProto upload up to 2 GB**, multi-chat fan-out.
- **Restore tooling** — interactive, by-file, cross-database, or **`--from-telegram`** disaster recovery.
- **Safety** — backup verification, `pg_isready` and disk-space checks, `flock` against overlapping runs.
- **Integrations** — webhooks (pre/post/error), custom `run-parts` hooks, Docker secrets (`*_FILE`).

---

## Documentation

| Doc | What's in it |
|---|---|
| [Getting Started](docs/GETTING_STARTED.md) | First-backup walkthrough and troubleshooting |
| [Configuration Reference](docs/CONFIGURATION.md) | Every environment variable, Docker secrets, retention math |
| [CLI Commands](docs/CLI.md) | `backup`, `restore`, `list`, `status`, `help` with example output |
| [Architecture](docs/ARCHITECTURE.md) | Runtime chain, backup cycle, rotation model, format branches (C4 + mermaid) |
| [Large Files](docs/LARGE_FILES.md) | MTProto upload for backups over 50 MB |
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
