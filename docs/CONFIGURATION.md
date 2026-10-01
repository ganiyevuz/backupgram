# Configuration Reference

Every setting is an environment variable passed to the container. Credentials
can also be supplied as Docker secrets via the `*_FILE` variants, which take
precedence over the plain variable.

- [Database Connection](#database-connection)
- [Backup Schedule and Retention](#backup-schedule-and-retention)
- [Layouts](#layouts)
- [Encryption](#encryption)
- [Row-level security guard](#row-level-security-guard)
- [Telegram Notifications](#telegram-notifications)
- [Webhooks](#webhooks)
- [Health and Advanced](#health-and-advanced)
- [REST API and metrics](#rest-api-and-metrics)
- [Off-site copies (S3)](#off-site-copies-s3)
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
| `POSTGRES_DB_AUTODISCOVER` | `FALSE` | When `TRUE`, back up every non-template database the server reports (minus `postgres` and `POSTGRES_DB_EXCLUDE`); `POSTGRES_DB` becomes optional. Ignored in cluster mode. |
| `POSTGRES_DB_EXCLUDE` | `""` | Comma-separated database names to skip when auto-discover is on. |
| `POSTGRES_DB_INCLUDE` | `""` | Comma-separated glob patterns (e.g. `control,pharmacy_*`); with auto-discover on, only matching names are backed up (then `POSTGRES_DB_EXCLUDE` applies). Databases the login may not `CONNECT` to are skipped and logged. |
| `POSTGRES_EXTRA_OPTS` | `-Z1` | Extra flags passed to `pg_dump` / `pg_dumpall` (word-split, so `-Z0 -Fd` works) |
| `POSTGRES_CLUSTER` | `FALSE` | Set `TRUE` to use `pg_dumpall` for a full cluster dump |
| `POSTGRES_EXCLUDE_TABLES` | `""` | Comma-separated tables to exclude from the dump |
| `POSTGRES_CONNECT_TIMEOUT` | `30` | Seconds to wait for the `pg_isready` connectivity check |

> **Auto-discover rule:** all non-template databases that allow connections,
> minus the built-in `postgres` maintenance database, keeping only names that
> match a `POSTGRES_DB_INCLUDE` glob (all names when it is empty), minus anything
> listed in `POSTGRES_DB_EXCLUDE`. `template0`/`template1` are always excluded. A
> database the login has no `CONNECT` privilege on is skipped and logged
> (`⏭️ <db> skipped: no CONNECT privilege`) instead of failing its dump; skipped
> databases are counted in the run summary. The list is resolved fresh on every
> run, so databases created later are picked up automatically. If
> `POSTGRES_CLUSTER=TRUE`, cluster mode wins and auto-discover is ignored (with a
> log note). An empty discovered set aborts the run. `POSTGRES_DB_INCLUDE` and
> `POSTGRES_DB_EXCLUDE` are ignored (with a log note) when auto-discover is off.
> The patterns are matched in Bash, never put into SQL.

> The local `pg_dump` client major version must match the server. Pick the image
> tag accordingly (e.g. `:16` against a PostgreSQL 16 server).

---

## Backup Schedule and Retention

| Variable | Default | Description |
|---|---|---|
| `SCHEDULE` | `@daily` | Cron expression ([syntax reference](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules)) |
| `BACKUP_ON_START` | `FALSE` | Run a backup immediately on container start |
| `VALIDATE_ON_START` | `TRUE` | Validate configuration on startup (runs `env.sh` standalone) |
| `BACKUP_DIR` | `/backups` | Directory inside the container to store backups. Use one per server/configuration: retention and dropped-database pruning act on every file in it. |
| `BACKUP_SUFFIX` | `.sql.gz` | Filename suffix for backup files |
| `BACKUP_LATEST_TYPE` | `symlink` | How to create the `latest` pointer: `symlink`, `hardlink`, or `none` |
| `BACKUP_KEEP_DAYS` | `7` | Days to retain daily backups |
| `BACKUP_KEEP_WEEKS` | `4` | Weeks to retain weekly backups |
| `BACKUP_KEEP_MONTHS` | `6` | Months to retain monthly backups |
| `BACKUP_KEEP_MINS` | `1440` | Minutes to retain backups in the `last` folder (`period` layout only) |
| `BACKUP_LAYOUT` | `period` | `period` or `snapshot`: how the `daily`/`weekly`/`monthly` folders are named and filled. See [Layouts](#layouts). |
| `BACKUP_MIN_BYTES` | `0` | Reject a dump smaller than this many bytes: the run logs it, counts the database as failed, and keeps the previous dump. An empty dump is always rejected. |
| `BACKUP_GID` | `""` | Group ID for the backup folders and files. When set: `BACKUP_DIR`, `last`, `daily`, `weekly` and `monthly` get this group and mode `2750` (setgid), and files are created `0640`. |

See [Retention Math](#retention-math) for how weeks/months convert to the day
counts used by `find -mtime`.

`env.sh` validates the newer settings at startup and exits `1` on a bad value:
`BACKUP_LAYOUT` must be `period` or `snapshot`, `BACKUP_GID` and
`BACKUP_MIN_BYTES` unsigned integers, `BACKUP_RLS_GUARD` and `METRICS_ENABLE`
`TRUE` or `FALSE`, and `METRICS_TEXTFILE_DIR` a writable directory.

---

## Layouts

Every run has one timestamp (`YYYYMMDD-HHMMSS`, the run's start time) that every
file of the run carries. Each database's dump is written to `last/`, then linked
into the other folders according to `BACKUP_LAYOUT`. Directory-format dumps
(`-Fd`) cannot be hard-linked and are copied instead.

### `period` (default)

One file per day, ISO week and month, replaced by every run of that period:

```
/backups/
  last/     mydb-20260416-020000.sql.gz    # every run, pruned after BACKUP_KEEP_MINS
  daily/    mydb-20260416.sql.gz           # the day's last run
  weekly/   mydb-202616.sql.gz             # the ISO week's last run
  monthly/  mydb-202604.sql.gz             # the month's last run
```

`*-latest` pointers follow `BACKUP_LATEST_TYPE`. A database that is dropped keeps
its files here until retention removes them (its `-latest` pointer stays too).

### `snapshot`

Every folder uses the same timestamped name, and only runs on the right day are
kept in `weekly/` and `monthly/`:

```
/backups/
  last/     mydb-20260416-020000.sql.gz    # exactly the newest dump of each existing database
  daily/    mydb-20260416-020000.sql.gz    # every run (hard link)
  weekly/   mydb-20260412-020000.sql.gz    # the run on a Sunday
  monthly/  mydb-20260401-020000.sql.gz    # the run on the 1st of the month
```

- Sunday and the 1st are taken from the container's clock (`TZ`) when the run
  starts. A `SCHEDULE` that never runs on a Sunday or on the 1st leaves `weekly/` or
  `monthly/` empty.
- `last/` holds one dump per database: once the new one is in place, the
  database's older dumps leave `last/`. `BACKUP_KEEP_MINS` is not used.
- **A dropped database's dump leaves `last/`.** After the loop the run lists the
  server's databases; a `last/` dump whose database is gone is removed together
  with its `last/<db>-latest…` entry, logged as `🗑️ <db> no longer exists`. Its
  `daily/`, `weekly/` and `monthly/` copies stay and age out with retention. If the
  listing fails or is empty, nothing is removed. Not applied in cluster mode.
- `*-latest` pointers still follow `BACKUP_LATEST_TYPE` (`none` for no pointers).

### Retention

After the loop, once per run, each folder is cleaned of every backup file older
than its threshold: `daily` by `BACKUP_KEEP_DAYS`, `weekly` by
`BACKUP_KEEP_WEEKS*7+1` days, `monthly` by `BACKUP_KEEP_MONTHS*31+1` days, and
`last` by `BACKUP_KEEP_MINS` (`period` layout only). Dot files, `*-latest`
pointers and any other folder (such as a `manual/` folder you create) are never
touched. A database that **failed in this run** keeps every copy it has (names
starting `<db>-<digit>`, in every folder): they are its last good dumps, so a
database that fails night after night never loses them — they stay, and take up
disk, until it backs up again. A database that is not in the run at all (dropped,
or removed from `POSTGRES_DB`) ages out normally. See [Retention Math](#retention-math).

---

## Encryption

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ENCRYPTION_KEY` | `""` | GPG passphrase for AES-256 encryption. Leave empty to disable. When set, an extra `.gpg` suffix is appended and the file is symmetrically encrypted. Must be a single line: a key containing a newline is refused at startup (gpg reads only the first line of the passphrase file). |

The dump is piped straight into GPG, so nothing unencrypted is ever written to
disk. The key reaches GPG through a temporary passphrase file (mode `0600`,
removed when the run ends), never on a command line, so it does not show up in
`ps`. The finished file is read back through the decryption pipe and verified
before it replaces the previous dump. `restore` uses the same passphrase file and
streams the decryption into the restore.

> Directory-format dumps (`-Fd`) are **never encrypted**, even when a key is set:
> they stay a plain directory with no `.gpg` suffix.

---

## Row-level security guard

| Variable | Default | Description |
|---|---|---|
| `BACKUP_RLS_GUARD` | `FALSE` | Set `TRUE` to check every database's row-level security before its dump. Not applied in cluster mode. |

With `pg_dump --enable-row-security`, the policies decide what the dumping login
can read, and a table no policy opens to it is dumped short, or empty, without any
error. The guard runs two checks as the login (`current_user`) in each database:

1. **Unread tables** — a table with row-level security enabled that has no
   permissive `SELECT` (or `ALL`) policy with `USING (true)` applying to the login,
   whether the policy is for `PUBLIC`, for the login, or for a role the login has
   `USAGE` of.
2. **Restricted tables** — a table with row-level security and a restrictive
   `SELECT` (or `ALL`) policy whose `USING` is not `true`, applying to `PUBLIC` or
   to any role the login is a member of (deliberately broader, so the guard errs
   towards failing).

If either check finds a table, or a check cannot run, the database **fails**: no
dump is written, the previous dump stays in `last/`, the error line names the
tables, and the run exits `1` (the other databases still run):

```
❌ pharmacy_alpha: row-level security without a full-read policy for svc_backup: public.orders. Previous dump kept.
```

Use it for a login **without `BYPASSRLS`** that dumps with
`--enable-row-security` in `POSTGRES_EXTRA_OPTS`. The checks do not look at
`BYPASSRLS`, so leave it off for a superuser or `BYPASSRLS` login. It is off by
default because some setups rely on row-level security to dump a deliberate
subset. The guard judges the **login**: `pg_dump --role=…` in
`POSTGRES_EXTRA_OPTS` makes the dump run as another role, which the guard does not
check.

---

## Telegram Notifications

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | `""` | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | `""` | Chat ID(s) — comma-separated for multiple destinations (get it from [@userinfobot](https://t.me/userinfobot)) |
| `TELEGRAM_API_ID` | `""` | Your Telegram app `api_id` ([my.telegram.org](https://my.telegram.org/apps)) for MTProto upload of backups up to 2 GB. Optional — the image ships a shared default app used when unset (see below); set your own to be independent |
| `TELEGRAM_API_HASH` | `""` | Your Telegram app `api_hash`, paired with `TELEGRAM_API_ID` |
| `TELEGRAM_USE_DEFAULT_API` | `TRUE` | When `TRUE`, large-file upload falls back to the image's built-in shared Telegram app if you set no `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`. Only identifies the app to Telegram — your bot token and backups stay private. Set `FALSE` to require your own |
| `TELEGRAM_THREAD_ID` | `""` | Message thread ID for supergroup topics (applied only when a single chat is configured) |
| `TELEGRAM_UPLOAD_METHOD` | `smart` | Backup-file transport: `smart` (auto by size), `botapi` (always Bot API via `curl`), or `mtproto` (always the bundled binary; uses your `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` or the shared default) |
| `TELEGRAM_NOTIFY_ON` | `all` | When to send notifications: `all`, `failure`, `success`, `none` |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | Bot API base URL. A custom (self-hosted) URL bypasses the 50 MB document limit check |
| `PROJECT_NAME` | `""` | Label included in Telegram captions and alerts |

Backup files under 50 MB are sent as documents via the Bot API. Larger files
(up to 2 GB) are uploaded over MTProto by the bundled `tg-upload` binary. This
works out of the box using a shared Telegram app baked into the image, so no
registration is needed. The shared app only identifies the app to Telegram —
your bot token authenticates and backups go to your own chat, so your data is
unaffected. Set your own `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` to be fully
independent, or `TELEGRAM_USE_DEFAULT_API=FALSE` to disable the shared default
(large files are then reported with a text alert unless you supply your own).
See [LARGE_FILES.md](LARGE_FILES.md).

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

The image's `HEALTHCHECK` (`/scripts/healthcheck.sh`) reports the container
unhealthy when `go-cron` does not answer (`go-cron is not responding`), when the
last scheduled run exited non-zero (`last backup run exited <N>`), when the last
backup failed, or when it is older than `BACKUP_MAX_AGE_HOURS`. A scheduled run
that exits `75` because another run held the lock (a manual `backup` or a REST API
run) does not count as a failure.

---

## REST API and metrics

| Variable | Default | Description |
|---|---|---|
| `REST_API_ENABLE` | `FALSE` | Set `TRUE` to run the HTTP control API (the bundled `backupgram-api` becomes PID 1 and supervises `go-cron`). |
| `REST_API_PORT` | `8081` | Port the API and `/metrics` listen on (separate from the `8080` healthcheck). |
| `REST_API_TOKEN` | `""` | Admin bearer token. **Required** when the API is enabled. |
| `REST_API_TOKEN_FILE` | `""` | Docker-secret path for the token (takes precedence over `REST_API_TOKEN`). |
| `METRICS_ENABLE` | `FALSE` | Set `TRUE` to write `${BACKUP_DIR}/.metrics.prom` after each run and serve it at `GET /metrics` on `REST_API_PORT`. Works without `REST_API_ENABLE` (only `/healthz` and `/metrics` are served). |
| `METRICS_TEXTFILE_DIR` | `""` | Also write `backupgram[-<project>].prom` into this folder after each run, for node-exporter's textfile collector. Must be a writable directory. |

`GET /metrics` needs **no token** and lists database names and backup results, so
keep `REST_API_PORT` on an internal network. See [MONITORING.md](MONITORING.md)
for the metrics, the dashboard and the alert rules, and [REST_API.md](REST_API.md)
for endpoints, the runtime-config whitelist, and the security model.

---

## Off-site copies (S3)

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET` | `""` | Enables off-site copies: every backup run that reaches the dumps ends with a sync of the bucket (a separate uploader instead syncs on its own schedule, whatever the backup runs do). Required when `BACKUPGRAM_MODE=s3-sync`. |
| `S3_ENDPOINT` | `https://s3.amazonaws.com` | Scheme, host and optional port of any S3-compatible endpoint (`https://host:port`), no path. `http://` is allowed, for a private network. |
| `S3_REGION` | `us-east-1` | Region of the bucket |
| `S3_ACCESS_KEY_ID` / `S3_ACCESS_KEY_ID_FILE` | `""` | Required when `S3_BUCKET` is set; the `_FILE` variant wins |
| `S3_SECRET_ACCESS_KEY` / `S3_SECRET_ACCESS_KEY_FILE` | `""` | Required when `S3_BUCKET` is set; the `_FILE` variant wins; never logged |
| `S3_PREFIX` | `""` | Key prefix: dumps go to `<S3_PREFIX>/<db>/<file>`. Use one per server. |
| `S3_FORCE_PATH_STYLE` | `FALSE` | `TRUE` for path-style addressing (most self-hosted S3 servers) |
| `S3_KEEP_DAYS` / `S3_KEEP_WEEKS` / `S3_KEEP_MONTHS` | `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` | Remote retention tiers; empty inherits the container's `BACKUP_KEEP_*` |
| `S3_PRUNE` | `TRUE` | `FALSE` = upload only, never delete from the bucket |
| `S3_ALLOW_UNENCRYPTED` | `FALSE` | `TRUE` also uploads dumps without a `.gpg` suffix |
| `S3_SYNC_TIMEOUT` | `3600` | Time limit of one sync, in whole seconds from 1 to 999999999; a sync that reaches it stops, counts as failed and is retried on the next run. Raise it when large dumps go over a slow link. A sync stopped by the limit, or in the uploader by `docker stop`, tries to abort its unfinished upload, which a stalled endpoint may not answer and a sync killed outright cannot do (in backup mode `docker stop` waits for the running backup up to the stop timeout, then kills a sync still running): set the bucket's lifecycle rule "abort incomplete multipart uploads after N days" ([OFFSITE.md](OFFSITE.md#providers)). With the sync at the end of each backup run, keep it below the `SCHEDULE` interval minus the time the dumps take: a run still holding the lock at the next tick makes that tick skip (it exits `75` and dumps nothing). |
| `S3_SCHEDULE` | `*/15 * * * *` | Cron expression of the uploader (`BACKUPGRAM_MODE=s3-sync` only) |
| `BACKUPGRAM_MODE` | `backup` | `backup` (the backup service) or `s3-sync` (a separate uploader container) |

`env.sh` (`VALIDATE_ON_START`) and the uploader's startup check validate these and
refuse to start on a bad value (`❌ …`, exit `1`): `S3_FORCE_PATH_STYLE`, `S3_PRUNE`
and `S3_ALLOW_UNENCRYPTED` must be `TRUE` or `FALSE`, `S3_KEEP_*` whole numbers,
`S3_SYNC_TIMEOUT` a whole number of seconds from 1 to 999999999 (at most 9 digits),
`S3_ENDPOINT` must start with `http://` or `https://`, and with `S3_BUCKET` set both
credentials must resolve to non-empty values. A setting that breaks after startup (an
unreadable secret file after a rotation) only turns the off-site copies off: the local
backups and restores go on, each run warns and records a failed sync, and
`BackupgramOffsiteSyncFailed` fires. None of these settings is in the REST API's
runtime-config whitelist, and empty `S3_KEEP_*` inherit the `BACKUP_KEEP_*` the
container was started with, never a value changed through the REST API. The two
deployments (at the end of a backup run, or a separate uploader), the retention
rules and the disaster-recovery steps are in [OFFSITE.md](OFFSITE.md).

---

## Docker Secrets

For any credential, a `*_FILE` variant pointing at a file (typically a mounted
Docker secret) takes precedence over the plain variable:

- `POSTGRES_USER_FILE`, `POSTGRES_PASSWORD_FILE`, `POSTGRES_DB_FILE`, `POSTGRES_PASSFILE_STORE`
- `TELEGRAM_BOT_TOKEN_FILE`, `TELEGRAM_CHAT_ID_FILE`, `TELEGRAM_API_ID_FILE`, `TELEGRAM_API_HASH_FILE`
- `S3_ACCESS_KEY_ID_FILE`, `S3_SECRET_ACCESS_KEY_FILE`

---

## Retention Math

`env.sh` converts the human-friendly `BACKUP_KEEP_*` values into the day counts
that `find -mtime` uses during cleanup:

```sh
KEEP_WEEKS=$((BACKUP_KEEP_WEEKS  * 7  + 1))   # e.g. 4 weeks  -> 29 days
KEEP_MONTHS=$((BACKUP_KEEP_MONTHS * 31 + 1))  # e.g. 6 months -> 187 days
```

`last/` is pruned by minutes (`BACKUP_KEEP_MINS`, `period` layout only),
`daily/` by `BACKUP_KEEP_DAYS`, and `weekly/`/`monthly/` by the computed day
counts above. Retention runs once per run, after every database has been dumped,
over every backup file of each folder, so a dropped or renamed database's copies
age out too; the copies of a database that failed in the run are left alone. It is
skipped when no database was backed up in the run
(`⚠️ No database was backed up this run; retention skipped.`), so a total outage
never erodes the last good copies. Use `list --cleanup-preview` to see exactly
what the current policy would delete.
