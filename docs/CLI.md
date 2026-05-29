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

---

## `backup` — Trigger a manual backup

Runs a full backup cycle immediately: dump, verify, encrypt (if enabled),
rotate, send to Telegram, and clean old files.

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

---

## `restore` — Restore from a backup

Without arguments, shows an interactive picker. With a file path, restores
directly. Auto-detects format (`.sql.gz`, `.sql.gz.gpg`, directory, tar.gz) and
handles GPG decryption automatically.

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
indicators for `[latest]` and `[encrypted]` files.

```sh
# List all backups
docker exec -it my-backup list

# Filter by database name
docker exec -it my-backup list mydb

# Preview what the retention policy would delete (dry run)
docker exec -it my-backup list --cleanup-preview
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
