# Architecture

This image is a pure-Bash backup runner baked into a PostgreSQL base image —
there is no application runtime. A cron scheduler (`go-cron`) invokes
`backup.sh` on a schedule; the script dumps each database (encrypting as it
streams), verifies the result, rotates it, delivers it to Telegram, prunes old
files, and writes Prometheus metrics.

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
    subgraph sys["backupgram (this image)"]
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
    runner -->|"metrics (textfile or /metrics)"| prom["Prometheus<br/><i>+ Grafana dashboard, alert rules</i>"]
```

---

## Containers & processes (C4 L2)

```mermaid
flowchart TB
    subgraph container["Container"]
        init["init.sh<br/><i>ENTRYPOINT</i>"]
        env["env.sh<br/><i>config validation + var resolution</i>"]
        cron["go-cron<br/><i>scheduler + healthcheck HTTP server</i>"]
        api["backupgram-api<br/><i>Go: REST API and/or GET /metrics;<br/>supervises go-cron</i>"]
        backup["backup.sh<br/><i>core backup cycle</i>"]
        lib["scripts/lib/*.sh<br/><i>layout, dump, discover,<br/>rls_guard, metrics</i>"]
        restore["restore.sh<br/><i>restore tooling</i>"]
        hooks["hooks/ (run-parts)<br/><i>pre-backup | post-backup | error</i>"]
        tgupload["tg-upload<br/><i>Go/MTProto binary, &le;2GB</i>"]
    end

    init -->|"VALIDATE_ON_START"| env
    init -->|"exec (default)"| cron
    init -->|"exec when REST_API_ENABLE or METRICS_ENABLE"| api
    api -->|supervises| cron
    cron -->|"per SCHEDULE"| backup
    backup -->|source| env
    backup -->|source| lib
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
  ├─ REST_API_ENABLE=TRUE or METRICS_ENABLE=TRUE:  exec backupgram-api   # supervises go-cron
  └─ otherwise:                                    exec go-cron -s "$SCHEDULE" -- /backup.sh
```

`go-cron` (from prodrigestivill/go-cron, downloaded in the Dockerfile) owns the
schedule and serves the healthcheck on `HEALTHCHECK_PORT`. It invokes
`backup.sh` once per `SCHEDULE`. With the REST API or metrics on,
`backupgram-api` is PID 1 and runs go-cron as a child; it serves `/healthz`,
plus `/metrics` when `METRICS_ENABLE=TRUE` and the token-protected REST routes
when `REST_API_ENABLE=TRUE` (see [MONITORING.md](MONITORING.md) and
[REST_API.md](REST_API.md)).

`backup.sh` sources its helpers from `scripts/lib/`: `layout.sh` (folders, links,
retention), `dump.sh` (format detection, streaming dump, verification),
`discover.sh` (database discovery), `rls_guard.sh` (row-level security checks) and
`metrics.sh` (Prometheus output).

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
    start([go-cron fires]) --> lock{"BACKUP_DIR/.lock<br/>held by another run?"}
    lock -->|yes| busy(["exit 75<br/>nothing is touched"])
    lock -->|no| setup["setup<br/>BACKUP_GID, remove stale .part files"]
    setup --> pre[run pre-backup hook]
    pre --> ready{pg_isready?}
    ready -->|no| abort
    ready -->|yes| disc["discovery<br/>include, exclude, CONNECT check"]
    disc -->|"nothing left"| abort
    disc --> disk{disk space OK?}
    disk -->|no| abort
    disk -->|yes| guard

    subgraph perdb["per database"]
        guard["RLS guard<br/>(BACKUP_RLS_GUARD)"] --> dump["dump into last/.name.part<br/>(piped through GPG when encrypted)"]
        dump --> accept["size check + full verify"]
        accept --> rename["rename into last/,<br/>link into daily / weekly / monthly"]
        rename --> send[send to Telegram]
        guard -->|fail| keep
        dump -->|fail| keep
        accept -->|fail| keep["remove .part,<br/>keep the previous dump,<br/>count the database as failed"]
    end

    send --> dropped["dropped databases leave last/<br/>(snapshot layout)"]
    keep --> dropped
    dropped --> retention["retention<br/>(skipped if nothing was backed up)"]
    retention --> metrics[write metrics]
    metrics --> status["write /tmp/backup_status"]
    status --> summary[summary + Telegram message]
    summary --> post[run post-backup hook]
    post --> result{any database failed?}
    result -->|no| ok([exit 0])
    result -->|yes| fail([exit 1])
    abort["abort: write metrics<br/>(run marked failed)"] --> fail
```

`backup.sh` starts with `set -Eeo pipefail` and traps `ERR` to fire the `error`
hook. A failing database does not stop the run: the others still dump, and the
run ends with exit code `1`. The lock is `${BACKUP_DIR}/.lock`, so containers
sharing a backup volume also run one at a time; a busy run prints one line and
exits `75` without changing anything. Every file of a run carries the run's start
time.

> Commands whose failure `backup.sh` handles itself run inside `if` / `||`
> conditions, where `set -e` does not apply, so each command in those pipelines is
> checked explicitly.

---

## Rotation model

Each run writes each database's dump into `last/` (first as a hidden
`.<name>.part` file, renamed into place once verified), then **hard-links** it into
`daily/`, `weekly/`, and `monthly/`. The hard link means the same inode is
shared — no extra disk is consumed. `*-latest` pointers are created per slot
(symlink / hardlink / none via `BACKUP_LATEST_TYPE`). `BACKUP_LAYOUT` picks how the
other folders are named and filled.

**`period`** (default) — one file per day, ISO week and month, replaced by each run
of that period:

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

**`snapshot`** — the same timestamped name in every folder; `weekly/` only gets
the Sunday run and `monthly/` the run on the 1st; `last/` holds exactly the newest
dump of each database that still exists:

```
/backups/
  last/
    mydb-20260416-020000.sql.gz       # newest dump per existing database
  daily/
    mydb-20260416-020000.sql.gz       # every run  (hard link)
  weekly/
    mydb-20260412-020000.sql.gz       # the Sunday run
  monthly/
    mydb-20260401-020000.sql.gz       # the run on the 1st
```

A dropped database's dump and its `-latest` entry leave `last/`; its
`daily/`, `weekly/` and `monthly/` copies stay until retention removes them.

Retention cleanup runs once per run, after the loop over every database, and
covers every backup file of each folder, not just this run's databases; each folder
is pruned independently using its own `BACKUP_KEEP_*` threshold (see
[CONFIGURATION.md → Layouts](CONFIGURATION.md#layouts) and
[Retention Math](CONFIGURATION.md#retention-math)). It is skipped when no database
was backed up in the run.

> Directory-format dumps (`-Fd`) cannot be hard-linked, so they are `cp -r`'d and
> `tar.gz`'d for Telegram. Because of hard links + symlinks, `BACKUP_DIR` **must**
> be a POSIX filesystem — VFAT, exFAT, and SMB/CIFS are not supported.

---

## Format branches

The same format-specific logic appears in both `backup.sh` (`scripts/lib/dump.sh`:
dump, verification, encryption suffix) and `restore.sh` (decrypt → un-tar →
dispatch by extension). Keep them in sync. The format is read once from
`POSTGRES_EXTRA_OPTS` (`-Fc`, `-Ft`, `-Fd`, `-Z…`).

Encryption streams: `pg_dump` (or `pg_dumpall | gzip`) is piped into `gpg`, which
writes the `.part` file, so no unencrypted dump touches the disk. Every stage of each
pipe must succeed for the dump to be accepted.

| Format | Produced by | Verified by (before the rename) | Restored via |
|---|---|---|---|
| gzip SQL (`.sql.gz`) | `pg_dump` (default `-Z1`) | `gunzip -c >/dev/null` | `gunzip \| psql` |
| plain SQL, uncompressed (`-Z0`) or another codec | `pg_dump` | size check only (encrypted: decrypt to `/dev/null`) | `psql` |
| custom (`-Fc`) or tar (`-Ft`) | `pg_dump -Fc` / `-Ft` | `pg_restore -f /dev/null` (encrypted: `gpg --decrypt \| pg_restore -f /dev/null`) | `pg_restore` |
| directory (`-Fd`) | `pg_dump -Fd` into a `.part` directory | `pg_restore -f /dev/null` | `pg_restore` |
| cluster | `pg_dumpall \| gzip` (`POSTGRES_CLUSTER=TRUE`) | `gunzip -c >/dev/null` | `psql -d postgres` |
| GPG (`.gpg`) | wraps any of the above except directory | through the decryption pipe | streamed into the restore; a tar-archived directory decrypts to a temp file |

Directory-format dumps are never encrypted. A wrong key or a damaged encrypted
file makes `restore` exit `1` with
`❌ Could not read the backup (wrong BACKUP_ENCRYPTION_KEY or a damaged file).`

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
- MTProto upload uses your `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`, or the image's
  built-in shared default app when they are unset (`env.sh` resolves it from the
  root-only `/etc/backupgram/default-telegram-api`, baked from a build secret and
  kept out of the container's env). With `TELEGRAM_USE_DEFAULT_API=FALSE` and no
  creds, oversized files are reported with a text alert instead.
- Multi-chat: `TELEGRAM_CHAT_ID` accepts a comma-separated list — the file is
  uploaded once and the resulting `file_id` is reused per chat.
- Each delivered backup carries a `🔖 Restore ID` in its caption, consumed by
  `restore --from-telegram`. See [LARGE_FILES.md](LARGE_FILES.md).
