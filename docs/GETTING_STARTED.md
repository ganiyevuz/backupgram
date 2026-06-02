# Getting Started

A step-by-step walkthrough from zero to a verified, restorable backup. Plan for
about 10 minutes.

**You will:** run the backup container → trigger a backup → verify it → restore
it → (optionally) wire up Telegram delivery.

- [Prerequisites](#prerequisites)
- [1. Pick the right image tag](#1-pick-the-right-image-tag)
- [2. Create a compose file](#2-create-a-compose-file)
- [3. Start the stack](#3-start-the-stack)
- [4. Trigger your first backup](#4-trigger-your-first-backup)
- [5. Verify the backup](#5-verify-the-backup)
- [6. Practice a restore](#6-practice-a-restore)
- [7. Add Telegram delivery](#7-add-telegram-delivery-optional)
- [Troubleshooting](#troubleshooting)
- [Next steps](#next-steps)

---

## Prerequisites

- Docker with Compose v2 (`docker compose`).
- A reachable PostgreSQL server (the example below runs one in the same stack).
- The image tag must match your PostgreSQL **major** version — see step 1.

---

## 1. Pick the right image tag

The bundled `pg_dump` client must match the server's major version. Choose the
tag accordingly:

| Your PostgreSQL | Debian tag | Alpine tag |
|---|---|---|
| 18 (newest) | `ganiyevuz/postgres-backup-telegram:18` (or `:latest`) | `…:18-alpine` (or `:alpine`) |
| 17 | `…:17` | `…:17-alpine` |
| 16 | `…:16` | `…:16-alpine` |
| 15 | `…:15` | `…:15-alpine` |

> The bundled `pg_dump` must be the same major version as your server **or newer**, so pick the tag matching your PostgreSQL version (a newer tag also works for an older server).

---

## 2. Create a compose file

Save this as `docker-compose.yml`:

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
      BACKUP_ON_START: "TRUE"   # run one backup immediately so you can verify now
    volumes:
      - backups:/backups

volumes:
  pgdata:
  backups:
```

`BACKUP_ON_START: "TRUE"` is the only addition over the minimal example — it
saves you from waiting for the schedule on first run.

---

## 3. Start the stack

```sh
docker compose up -d
```

Check the backup container came up cleanly (config is validated on start):

```sh
docker compose logs backup
```

You should see the validation pass and, because of `BACKUP_ON_START`, a backup
run. If validation fails, the container exits — read the error and fix the env
var it names.

---

## 4. Trigger your first backup

If you didn't set `BACKUP_ON_START`, trigger one manually:

```sh
docker compose exec backup backup
```

Expected tail:

```
Backup created: /backups/last/mydb-20260416-143000.sql.gz (42M, 8s)
----------------------------------------
Backup completed in 12s: 1 succeeded, 0 failed
----------------------------------------
```

---

## 5. Verify the backup

```sh
docker compose exec backup list
docker compose exec backup status
```

`list` shows the file under `LAST` (and a hard-linked copy under `DAILY`).
`status` shows `Last Backup: Status: OK`. That confirms the dump was created and
passed verification.

---

## 6. Practice a restore

> Restoring overwrites data. Restore into a **throwaway** database to practice
> safely.

```sh
# Restore the latest backup into a new database, non-interactively
docker compose exec backup restore /backups/last/mydb-latest.sql.gz mydb_practice
```

Or run `restore` with no arguments for an interactive numbered picker. A backup
you can't restore isn't a backup — make this a habit.

---

## 7. Add Telegram delivery (optional)

Get a bot token from [@BotFather](https://t.me/BotFather) and your chat id from
[@userinfobot](https://t.me/userinfobot), then add to the `backup` service env:

```yaml
      TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
      TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
```

Files under 50 MB are sent immediately as documents. For databases that produce
larger dumps (up to 2 GB), also set `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` to
enable MTProto upload — see [LARGE_FILES.md](LARGE_FILES.md). Re-create the
container and trigger a backup to confirm the message arrives:

```sh
docker compose up -d backup
docker compose exec backup backup
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Container exits on start | Failed config validation | Read `docker compose logs backup`; set the missing/invalid var |
| `pg_dump: server version mismatch` | Image tag ≠ server major version | Use the matching tag (step 1) |
| Backup created but not on Telegram | File > 50 MB without MTProto creds | Set `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`, or a self-hosted `TELEGRAM_API_URL` |
| `unsupported filesystem` / hard-link errors | `BACKUP_DIR` on VFAT/exFAT/CIFS | Use a POSIX volume (ext4, xfs, …) |
| Permission denied writing backups | Volume owner mismatch | `chown` the volume to the image UID (999 Debian / 70 Alpine) |

---

## Next steps

- [Configuration Reference](CONFIGURATION.md) — every env var, retention math.
- [CLI Commands](CLI.md) — full `backup` / `restore` / `list` / `status` reference.
- [Architecture](ARCHITECTURE.md) — how the backup cycle and rotation work.
- [Large Files](LARGE_FILES.md) — MTProto upload for backups over 50 MB.
