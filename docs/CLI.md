# CLI Commands

The image ships five commands as symlinks in `/usr/local/bin`. Run them inside a
running container with `docker exec`:

```sh
docker exec -it <container> <command>
```

- [`backup`](#backup--trigger-a-manual-backup)
- [`restore`](#restore--restore-from-a-backup)
- [`list`](#list--list-all-backups)
- [`status`](#status--system-status-overview)
- [`help`](#help--show-available-commands)
- [The off-site uploader](#the-off-site-uploader)

---

## `backup` — Trigger a manual backup

Runs a full backup cycle immediately: dump each database (encrypting as it
streams, if enabled), verify, rotate, send to Telegram, and clean old files.

```sh
docker exec -it my-backup backup
```

```
Checking database connectivity (timeout: 30s)...
Database is reachable.
Disk space OK (45032MB available).
Creating dump of mydb from postgres...
Backup created: /backups/last/mydb-20260416-143000.sql.gz (42M, 44040192 bytes, 8s)
Backup sent to Telegram chat 123456789.
----------------------------------------
Backup completed in 12s: 1 succeeded, 0 failed, 0 skipped
----------------------------------------
```

### Exit codes

- `0` — every database was dumped.
- `1` — a database failed (the others still ran) or the run aborted (server
  unreachable, low disk space, discovery failed or found nothing). The summary
  lists the failures (`❌ Failed: <dbs>`), and each failed database keeps its
  previous dump.
- `75` — another run holds `${BACKUP_DIR}/.lock`; nothing was started or changed.
  The lock serialises runs of the **same configuration** — the scheduled run and a
  manual `docker exec … backup`, or two containers running the same settings on one
  volume. Use one `BACKUP_DIR` per server/configuration: with different servers or
  retention settings in one folder, every-file retention and dropped-database pruning
  would act on each other's files.

Failure lines go to **stderr**: each per-database `❌ …` line and the
`❌ Failed: <dbs>` summary line. `backup > backup.log` therefore misses them;
capture both streams (`backup > backup.log 2>&1`). The rest of the output,
including `Backup completed in …`, goes to stdout.

The `error` hook does not run for a failed database, so alert on the exit code or
on the [metrics](MONITORING.md).

With `S3_BUCKET` set, every run that reaches the dumps ends with an [off-site
sync](OFFSITE.md); a run that stops before them does not sync. A problem there
(`⚠️ …` lines, `backupgram_offsite_sync_success 0`) never changes the exit code.

---

## `restore` — Restore from a backup

Without arguments, shows an interactive picker. With a file path, restores
directly; `--from-telegram` and `--from-s3` fetch the backup from Telegram or the
off-site bucket. Auto-detects format (`.sql.gz`, `.sql.gz.gpg`, directory, tar.gz) and
handles GPG decryption automatically. The target database name is taken from the
file name (trailing `.gpg`, `.gz`, `.tar`, `.sql`, `.dump` and the date or
`-latest` are stripped) unless you pass it.

Restores stream: the backup is piped into `psql` or `pg_restore`, and an encrypted one is
decrypted on the way, never to disk, with the key passed through a temporary passphrase
file, never on a command line. The exceptions are local unencrypted custom-format and tar
files and directory dumps, which `pg_restore` reads itself. In a streamed restore:

- A wrong `BACKUP_ENCRYPTION_KEY` or a damaged file exits `1` with `❌ Could not read
  the backup (wrong BACKUP_ENCRYPTION_KEY or a damaged file).` Damage is caught in
  encrypted dumps (gpg's integrity check) and in gzip SQL dumps (`.sql.gz`, gzip's
  checksum), encrypted or not.
- A restore that stops before it has read the whole stream (`pg_restore` refusing the
  archive, a lost connection) exits `1` with `❌ The restore stopped before it read the
  whole backup (see the errors above).` A tar archive is always read to its end
  (`pg_restore` never reads its tail), so a tar dump that `pg_restore` refuses ends with
  `⚠️ pg_restore completed with warnings.` instead.
- A wrong key fails before anything is restored; a damaged file can fail part-way. In
  each case, a target database the restore created is dropped again, and an existing one
  gets `⚠️ '<db>' may be partially restored: drop it before retrying.`

Other damage shows only as `pg_restore` / `psql` errors in the output: in an
unencrypted custom-format dump read from a local file, an unencrypted tar dump, or an
unencrypted plain `.sql` dump. (An unencrypted custom-format object from the bucket that
`pg_restore` rejects before its end fails with the stopped-early line.)

```sh
# Interactive mode -- pick from a numbered list
docker exec -it my-backup restore

# Direct restore from a specific file
docker exec -it my-backup restore /backups/last/mydb-latest.sql.gz

# Restore into a different database
docker exec -it my-backup restore /backups/daily/mydb-20260416.sql.gz mydb_staging
```

### Restore from Telegram

Disaster recovery for when local backups are gone:

```sh
# The restore id is shown in each backup message's caption: "🔖 Restore ID: 4521"
docker exec -it my-backup restore --from-telegram 4521

# Pick a specific chat (for multi-chat delivery) and/or target database
docker exec -it my-backup restore --from-telegram 4521 --chat -1001234567890 mydb_restored
```

Requires `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` / `TELEGRAM_BOT_TOKEN`. The
backup is downloaded over MTProto (up to 2 GB), then restored through the normal
decrypt / auto-detect pipeline.

### Restore from the off-site bucket

Disaster recovery from an [S3 bucket](OFFSITE.md) (needs `S3_BUCKET` and its
credentials, and `BACKUP_ENCRYPTION_KEY` for `.gpg` dumps):

```sh
# The newest off-site dump of a database
docker exec -it my-backup restore --from-s3 mydb

# ... into a different database
docker exec -it my-backup restore --from-s3 mydb mydb_restored

# One object, by its key (an argument with a / is a key)
docker exec -it my-backup restore --from-s3 shop-prod/mydb/mydb-20260416-020000.sql.gz.gpg
```

The object streams from the bucket through `gpg` into the restore: nothing in clear
text is written to disk. Exit `1` when the database or key is not found in the bucket
(`❌ <name>: not found in s3://<bucket>/<prefix>.`, nothing restored) or when the
stream fails (`❌ Could not read the backup (download interrupted, wrong
BACKUP_ENCRYPTION_KEY, or a damaged object).`) or stops before its end (`❌ The
restore stopped before it read the whole backup (see the errors above).`); the rules
are those of a streamed restore above. A damaged object is caught when it is encrypted
(gpg's integrity check) or a `.sql.gz` (gzip's checksum), and an unencrypted
custom-format one when `pg_restore` rejects it before its end; damage in an unencrypted
tar or plain `.sql` object shows only as `pg_restore` / `psql` errors in the output. A
wrong key fails before anything is restored, but a download cut off part-way may
already have restored part of the dump:
a target database the restore created is then dropped again, and an existing one is
left with `⚠️ '<db>' may be partially restored: drop it before retrying.` Drop it, or
restore under another name, before you retry.

### Interactive mode output

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

---

## `list` — List all backups

Shows all backup files grouped by rotation slot with sizes, dates, and
indicators for `[latest]` and `[encrypted]` files. Dot files (an in-progress
`.part` dump, `.lock`, the metrics file) are not listed.

```sh
# List all backups
docker exec -it my-backup list

# Filter by database name
docker exec -it my-backup list mydb

# Preview what the retention policy would delete (dry run)
docker exec -it my-backup list --cleanup-preview

# What the off-site bucket holds (every database, or one)
docker exec -it my-backup list --s3
docker exec -it my-backup list --s3 mydb
```

### List output

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

### Off-site list output

`list --s3` prints one box per database with each object's size, dump time, the
retention tier that keeps it (`daily`, `weekly` or `monthly`) and its key, in key
order. `expires` means past every tier: the next sync deletes it unless it is the
newest copy of a database that still has a dump in `last/` (and nothing is deleted
with `S3_PRUNE=FALSE`). An object that is not a stamped dump at
`<S3_PREFIX>/<db>/<file>` shows `-` for the dump time and the tier; `list --s3 <db>`
leaves such objects out. It needs
`S3_BUCKET` and its credentials, and no database access, so it also runs in the
uploader. Exit `1` when the bucket cannot be listed.

```
╔══════════════════════════════════════╗
║  OFF-SITE mydb
╠══════════════════════════════════════╣
║  41.0M   2026-04-12 02:00:00  weekly   shop-prod/mydb/mydb-20260412-020000.sql.gz.gpg
║  42.0M   2026-04-16 02:00:00  daily    shop-prod/mydb/mydb-20260416-020000.sql.gz.gpg
╚══════════════════════════════════════╝

2 off-site dump(s) in s3://my-backups/shop-prod
```

### Cleanup preview output

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

---

## `status` — System status overview

Shows current configuration, last backup result, backup inventory counts, disk
usage, and lock status at a glance.

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

---

## `help` — Show available commands

Prints a quick reference of all commands, usage examples, and key environment
variables.

```sh
docker exec -it my-backup help
```

---

## The off-site uploader

With `BACKUPGRAM_MODE=s3-sync` the container is a separate [off-site
uploader](OFFSITE.md#b-a-separate-uploader-container): go-cron runs
`/scripts/s3-sync.sh` on `S3_SCHEDULE`, and `list --s3` works in it. `backup` and
`restore` need database access, which the uploader does not have. Each run is one sync:

- `0` — the sync finished without a failed upload, or another sync was still running
  (`⏳ Another off-site sync is running. Not started.`; nothing was started).
- `1` — a sync failed (an upload, the listing, or the bucket was unreachable), or an
  S3 setting is missing or bad. go-cron then answers `503`, so the container shows
  unhealthy until the next good sync.
