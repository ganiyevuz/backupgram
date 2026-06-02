# Architecture

This image is a pure-Bash backup runner baked into a PostgreSQL base image —
there is no application runtime. A cron scheduler (`go-cron`) invokes
`backup.sh` on a schedule; the script dumps, verifies, encrypts, rotates,
delivers to Telegram, and prunes.

- [System context (C4 L1)](#system-context-c4-l1)
- [Containers & processes (C4 L2)](#containers--processes-c4-l2)
- [Entrypoint chain](#entrypoint-chain)
- [The backup cycle](#the-backup-cycle)
- [Rotation model](#rotation-model)
- [Format branches](#format-branches)
- [Telegram delivery](#telegram-delivery)

---

## System context (C4 L1)

```mermaid
flowchart TB
    operator["Operator / DevOps<br/><i>configures env, runs CLI</i>"]
    subgraph sys["postgres-backup-telegram (this image)"]
        runner["Backup runner<br/><i>Bash + go-cron</i>"]
    end
    pg[("PostgreSQL server<br/><i>source database(s)</i>")]
    tg["Telegram<br/><i>Bot API + MTProto</i>"]
    hook["Webhook endpoints<br/><i>monitoring / alerting</i>"]
    vol[("Backup volume<br/><i>POSIX filesystem</i>")]

    operator -->|env vars, docker exec| runner
    runner -->|pg_dump / pg_dumpall| pg
    runner -->|upload backups + alerts| tg
    runner -->|JSON payloads| hook
    runner -->|write / rotate / prune| vol
```

---

## Containers & processes (C4 L2)

```mermaid
flowchart TB
    subgraph container["Container"]
        init["init.sh<br/><i>ENTRYPOINT</i>"]
        env["env.sh<br/><i>config validation + var resolution</i>"]
        cron["go-cron<br/><i>scheduler + healthcheck HTTP server</i>"]
        backup["backup.sh<br/><i>core backup cycle</i>"]
        restore["restore.sh<br/><i>restore tooling</i>"]
        hooks["hooks/ (run-parts)<br/><i>pre-backup | post-backup | error</i>"]
        tgupload["tg-upload<br/><i>Go/MTProto binary, &le;2GB</i>"]
    end

    init -->|"VALIDATE_ON_START"| env
    init -->|exec| cron
    cron -->|"per SCHEDULE"| backup
    backup -->|source| env
    backup -->|run-parts| hooks
    backup -->|">50MB or method=mtproto"| tgupload
    restore -->|source| env
    restore -->|"--from-telegram"| tgupload
```

---

## Entrypoint chain

```
init.sh (ENTRYPOINT)
  └─ /env.sh            # standalone validation when VALIDATE_ON_START=TRUE
  └─ exec go-cron -s "$SCHEDULE" -- /backup.sh
```

`go-cron` (from prodrigestivill/go-cron, downloaded in the Dockerfile) owns the
schedule and serves the healthcheck on `HEALTHCHECK_PORT`. It invokes
`backup.sh` once per `SCHEDULE`.

**`env.sh` is dual-purpose and central:**

- **Sourced** by `backup.sh` / `restore.sh` — validates required vars, resolves
  `*_FILE` Docker-secret variants, exports `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT`,
  splits comma-separated `POSTGRES_DB` into `$POSTGRES_DBS`, and computes
  retention thresholds.
- **Executed** standalone (as `/env.sh`) by `init.sh` for startup validation —
  so it both `export`s vars and `exit 1`s on bad config.

---

## The backup cycle

```mermaid
flowchart TD
    start([go-cron fires]) --> lock{flock<br/>already running?}
    lock -->|yes| skip([skip run])
    lock -->|no| source[source env.sh]
    source --> pre[run pre-backup hook]
    pre --> ready{pg_isready?}
    ready -->|no| err[fire error hook + alert]
    ready -->|yes| disk{disk space OK?}
    disk -->|no| err
    disk -->|yes| dump["dump<br/>pg_dump per DB<br/>(or pg_dumpall if cluster)"]
    dump --> verify[verify_backup]
    verify --> enc{BACKUP_ENCRYPTION_KEY?}
    enc -->|yes| gpg["encrypt_file (GPG AES-256)"]
    enc -->|no| rotate
    gpg --> rotate[rotate into daily/weekly/monthly]
    rotate --> send[send to Telegram]
    send --> prune[retention cleanup]
    prune --> status["write /tmp/backup_status"]
    status --> summary[summary Telegram message]
    summary --> post[run post-backup hook]
    post --> done([done])
    err --> done
```

`backup.sh` starts with `set -Eeo pipefail` and traps `ERR` to fire the `error`
hook.

---

## Rotation model

Each run writes a timestamped file into `last/`, then **hard-links** it into
`daily/`, `weekly/`, and `monthly/`. The hard link means the same inode is
shared — no extra disk is consumed. `*-latest` pointers are created per slot
(symlink / hardlink / none via `BACKUP_LATEST_TYPE`).

```
/backups/
  last/
    mydb-20260416-020000.sql.gz       # every backup
    mydb-latest.sql.gz -> (symlink)
  daily/
    mydb-20260416.sql.gz              # latest backup of the day  (hard link)
  weekly/
    mydb-202616.sql.gz                # latest backup of the ISO week
  monthly/
    mydb-202604.sql.gz                # latest backup of the month
```

Retention cleanup runs after each successful backup; each folder is pruned
independently using its own `BACKUP_KEEP_*` threshold (see
[CONFIGURATION.md → Retention Math](CONFIGURATION.md#retention-math)).

> Directory-format dumps (`-Fd`) cannot be hard-linked, so they are `cp -r`'d and
> `tar.gz`'d for Telegram. Because of hard links + symlinks, `BACKUP_DIR` **must**
> be a POSIX filesystem — VFAT, exFAT, and SMB/CIFS are not supported.

---

## Format branches

The same format-specific logic appears in both `backup.sh` (verify, encryption
suffix) and `restore.sh` (decrypt → un-tar → dispatch by extension). Keep them
in sync.

| Format | Produced by | Verified via | Restored via |
|---|---|---|---|
| gzip SQL (`.sql.gz`) | default `pg_dump` | magic-byte check (`1f8b`); `-Z0` uncompressed tolerated | `psql` / `pg_restore` |
| directory (`-Fd`) | `pg_dump -Fd` | `pg_restore --list` | `pg_restore` |
| cluster | `pg_dumpall` (`POSTGRES_CLUSTER=TRUE`) | **skipped** (plain SQL) | `psql -d postgres` |
| GPG (`.gpg`) | wraps any of the above | after decrypt | decrypt, then dispatch |

---

## Telegram delivery

```mermaid
flowchart TD
    file([backup file ready]) --> method{TELEGRAM_UPLOAD_METHOD}
    method -->|botapi| botapi
    method -->|mtproto| mtproto
    method -->|smart| size{size &lt; 50MB?<br/><i>only vs official API URL</i>}
    size -->|yes| botapi["Bot API (curl)<br/>send as document"]
    size -->|no| mtproto["tg-upload (MTProto)<br/>upload once, &le;2GB"]
    botapi --> fanout["fan out to all<br/>TELEGRAM_CHAT_ID(s)<br/><i>reuse file_id</i>"]
    mtproto --> fanout
    fanout --> caption["embed 🔖 Restore ID<br/>in caption"]
```

- The 50 MB limit is enforced **only** against the official
  `https://api.telegram.org`; a custom self-hosted Bot API URL bypasses it.
- MTProto upload requires `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`; without them,
  oversized files are reported with a text alert instead.
- Multi-chat: `TELEGRAM_CHAT_ID` accepts a comma-separated list — the file is
  uploaded once and the resulting `file_id` is reused per chat.
- Each delivered backup carries a `🔖 Restore ID` in its caption, consumed by
  `restore --from-telegram`. See [LARGE_FILES.md](LARGE_FILES.md).
