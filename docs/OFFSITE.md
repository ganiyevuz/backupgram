# Off-site copies (S3)

backupgram can keep a copy of every dump in an S3-compatible bucket, on another
server or at a provider, so that losing the backup server does not lose the
backups.

- [What it does](#what-it-does)
- [Two ways to run it](#two-ways-to-run-it)
- [Settings](#settings)
- [Rules for a safe setup](#rules-for-a-safe-setup)
- [Layouts](#layouts)
- [Retention and safety](#retention-and-safety)
- [Providers](#providers)
- [Failures and monitoring](#failures-and-monitoring)
- [Disaster recovery](#disaster-recovery)

---

## What it does

The local backup folder stays as it is: `last/`, `daily/`, `weekly/` and
`monthly/`, the `list`/`restore` commands and the Telegram delivery do not change.
The off-site copy is added on top, and only dumps leave the server:

- With `BACKUP_ENCRYPTION_KEY` set, dumps are encrypted before they touch the local
  disk, so the bucket only holds `.gpg` files and never sees clear text. Unencrypted
  dumps stay local unless you allow them (`S3_ALLOW_UNENCRYPTED`).
- Each dump is one object at `<S3_PREFIX>/<db>/<file name>` (without the prefix and
  its `/` when `S3_PREFIX` is empty), for example `shop-prod/mydb/mydb-20260416-020000.sql.gz.gpg`.
- A sync uploads what the bucket lacks, then prunes the bucket by tiers with the same
  day counts as the local folders ([Retention and safety](#retention-and-safety)). The
  upload is checked: the bucket must report the local size, or the upload counts as
  failed and is retried on the next sync. A key that exists with a different size (an
  interrupted or replaced upload) is uploaded again. Each sync has a time limit
  (`S3_SYNC_TIMEOUT`), so a stalled endpoint holds up the backups (their lock) for at
  most `S3_SYNC_TIMEOUT` (plus up to 5 seconds to abort an unfinished upload). A
  backlog goes up newest first, so the newest copy arrives before the time limit.
- `list --s3` and `restore --from-s3` read straight from the bucket.

Only an object at exactly `<S3_PREFIX>/<db>/<file>` with a stamped file name
(`<db>-YYYYMMDD-HHMMSS<suffix>`) counts as one of this deployment's dumps. Any other
object under the prefix is never pruned. `list --s3` still shows it, with `-` for the
tier.

---

## Two ways to run it

Both run the same code. Pick one per backup folder (see [rules](#rules-for-a-safe-setup)).

### a) At the end of a backup run

Set `S3_BUCKET` and the credentials on the backup service. After retention, every
run that reaches the dumps syncs the bucket; a run that stops before them (the
database unreachable, too little disk space) does not. The sync runs even when every
dump failed, so it can still upload dumps an earlier sync missed.

What `docker stop` does to a running backup, its sync included:

- With `go-cron` as PID 1 (the default), it waits for the backup up to the stop
  timeout (Docker's default 10 s, or the service's `stop_grace_period`), so raising the
  timeout lets a long backup finish.
- With `REST_API_ENABLE=TRUE` or `METRICS_ENABLE=TRUE`, `backupgram-api` is PID 1: it
  stops `go-cron` (killing it after 5 s) and exits, which ends the backup after about
  5 s, whatever the stop timeout.

Either way, a sync still running then is killed outright and cannot abort its
unfinished upload: the bucket's lifecycle rule cleans up after it
([Providers](#providers)).

```yaml
services:
  backup:
    image: ganiyevuz/backupgram:17-alpine
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      SCHEDULE: "@daily"
      BACKUP_ENCRYPTION_KEY: "${BACKUP_ENCRYPTION_KEY}"
      PROJECT_NAME: shop
      S3_BUCKET: my-backups
      S3_ENDPOINT: https://s3.eu-central-1.amazonaws.com
      S3_REGION: eu-central-1
      S3_PREFIX: shop-prod
      S3_ACCESS_KEY_ID_FILE: /run/secrets/s3_access_key_id
      S3_SECRET_ACCESS_KEY_FILE: /run/secrets/s3_secret_access_key
    secrets:
      - s3_access_key_id
      - s3_secret_access_key
    volumes:
      - backups:/backups

secrets:
  s3_access_key_id:
    file: ./secrets/s3_access_key_id
  s3_secret_access_key:
    file: ./secrets/s3_secret_access_key

volumes:
  backups:
```

### b) A separate uploader container

`BACKUPGRAM_MODE=s3-sync` starts the same image as an uploader: it runs one sync on
`S3_SCHEDULE` (default every 15 minutes) and does nothing else. It needs no
`POSTGRES_*` settings, no `BACKUP_ENCRYPTION_KEY` and no database network, and the
backup folder can be mounted read-only. The backup service stays as it was. The
uploader does not depend on the backup runs: it syncs what the folder holds on its own
schedule, also while backups fail or stop early.

```yaml
services:
  backup:                                  # unchanged: no S3_* settings
    image: ganiyevuz/backupgram:17-alpine
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      SCHEDULE: "@daily"
      BACKUP_ENCRYPTION_KEY: "${BACKUP_ENCRYPTION_KEY}"
      PROJECT_NAME: shop                   # the same PROJECT_NAME on both services
      TZ: Europe/Berlin
    volumes:
      - backups:/backups

  backup-offsite:
    image: ganiyevuz/backupgram:17-alpine
    environment:
      BACKUPGRAM_MODE: s3-sync
      S3_SCHEDULE: "*/15 * * * *"
      S3_BUCKET: my-backups
      S3_ENDPOINT: https://s3.eu-central-1.amazonaws.com
      S3_REGION: eu-central-1
      S3_PREFIX: shop-prod
      S3_ACCESS_KEY_ID_FILE: /run/secrets/s3_access_key_id
      S3_SECRET_ACCESS_KEY_FILE: /run/secrets/s3_secret_access_key
      S3_KEEP_DAYS: 7                      # the uploader does not see the backup service's BACKUP_KEEP_*
      S3_KEEP_WEEKS: 4
      S3_KEEP_MONTHS: 6
      PROJECT_NAME: shop
      METRICS_TEXTFILE_DIR: /textfile
      TZ: Europe/Berlin                    # the same TZ as the backup service
    secrets:
      - s3_access_key_id
      - s3_secret_access_key
    volumes:
      - backups:/backups:ro
      - textfile:/textfile

secrets:
  s3_access_key_id:
    file: ./secrets/s3_access_key_id
  s3_secret_access_key:
    file: ./secrets/s3_secret_access_key

volumes:
  backups:
  textfile:
```

The uploader validates only the S3 settings at start (`❌ …` and exit `1` on a bad
one, and `BACKUPGRAM_MODE=s3-sync requires S3_BUCKET.` without a bucket), and again
before each sync ([a setting that breaks later](#settings)). Its image
healthcheck is unchanged: after a sync that failed, `go-cron` answers `503` and the
container shows unhealthy (`last backup run exited 1`) until the next good sync.
Metrics go to `METRICS_TEXTFILE_DIR` only; without it the uploader writes none (see
[Failures and monitoring](#failures-and-monitoring)).

`docker stop` stops a running sync cleanly: the uploader runs `go-cron` under
`tini -s -g`, which passes the `SIGTERM` to the sync (`go-cron` alone never would).
The sync aborts its unfinished upload, records a failed sync in the metrics, and the
container exits well within Docker's 10 s stop timeout.

---

## Settings

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET` | `""` | Enables off-site copies. Required in uploader mode. |
| `S3_ENDPOINT` | `https://s3.amazonaws.com` | Scheme, host and optional port only (`https://host:port`), no path: the client ignores a path. `http://` is allowed, for a private network. |
| `S3_REGION` | `us-east-1` | Region the bucket lives in (signing region). |
| `S3_ACCESS_KEY_ID` / `S3_ACCESS_KEY_ID_FILE` | `""` | Required when `S3_BUCKET` is set. The `_FILE` variant (a Docker secret) takes precedence. |
| `S3_SECRET_ACCESS_KEY` / `S3_SECRET_ACCESS_KEY_FILE` | `""` | Required when `S3_BUCKET` is set. The `_FILE` variant takes precedence. Never logged and never on a command line: `s3-sync` reads it from its environment. |
| `S3_PREFIX` | `""` | Key prefix; leading and trailing `/` are trimmed. |
| `S3_FORCE_PATH_STYLE` | `FALSE` | `TRUE` for path-style addressing (`https://host/bucket/key`), which most self-hosted S3 servers need. |
| `S3_KEEP_DAYS` / `S3_KEEP_WEEKS` / `S3_KEEP_MONTHS` | `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` | Remote retention tiers. Empty means the container's own `BACKUP_KEEP_*` (the image defaults `7` / `4` / `6` unless you set them), as the container was started with: a `BACKUP_KEEP_*` changed through the REST API does not change them. |
| `S3_PRUNE` | `TRUE` | `FALSE` = upload only; backupgram never deletes from the bucket. |
| `S3_ALLOW_UNENCRYPTED` | `FALSE` | `TRUE` also uploads dumps without a `.gpg` suffix. |
| `S3_SYNC_TIMEOUT` | `3600` | Time limit of one sync, in whole seconds from 1 to 999999999. A sync that reaches it stops, counts as failed and is retried on the next run (`⚠️ off-site: the sync stopped after …`). Raise it when large dumps go over a slow link: a 10 GB dump at 20 Mbit/s takes more than an hour. A sync stopped by the limit, or in the uploader by `docker stop`, tries to abort its unfinished upload, which a stalled endpoint may not answer and a sync killed outright cannot do (in backup mode, one still running when `docker stop` ends the backup, see [At the end of a backup run](#a-at-the-end-of-a-backup-run)): set the bucket's lifecycle rule for incomplete multipart uploads ([Providers](#providers)). With the sync at the end of each backup run, keep it below the `SCHEDULE` interval minus the time the dumps take: a run still holding the lock at the next tick makes that tick skip (it exits `75` and dumps nothing). |
| `S3_SCHEDULE` | `*/15 * * * *` | Cron expression of the uploader. Uploader mode only. |
| `BACKUPGRAM_MODE` | `backup` | `backup` or `s3-sync` (the uploader). |

The settings are validated at startup, and a bad one stops the container from starting
(`❌ …` and exit `1`; in backup mode with `VALIDATE_ON_START=TRUE`, the default):
`S3_FORCE_PATH_STYLE`, `S3_PRUNE` and `S3_ALLOW_UNENCRYPTED` must be `TRUE` or
`FALSE`, `S3_KEEP_*` whole numbers, `S3_SYNC_TIMEOUT` a whole number of seconds
from 1 to 999999999 (at most 9 digits), `S3_ENDPOINT` must start with `http://` or
`https://`, `BACKUPGRAM_MODE` must be `backup` or `s3-sync`, and with `S3_BUCKET` set
both credentials must resolve to non-empty values (a `_FILE` that cannot be read is an
error too). None of these settings can be changed through the REST API.

A setting that breaks after startup (a secret file that becomes unreadable after a
rotation, say) turns the off-site copies off until it is fixed; the local backups go
on. A backup run prints `⚠️ <the problem>. Off-site copies are off until it is fixed.`
and `⚠️ off-site: skipped, an S3 setting is invalid (see above). The local backup is not affected.`,
records a failed sync (`BackupgramOffsiteSyncFailed` fires) and keeps its exit code.
Local restores and `list` work as before; `restore --from-s3` exits `1` with
`❌ restore --from-s3: an S3 setting is invalid (see above).` and `list --s3` with the
`❌` line. The uploader prints the `❌` line, records a failed sync and exits `1`.

---

## Rules for a safe setup

- **One deployment per backup folder.** With `S3_BUCKET` on the backup service *and*
  an uploader on the same folder, both sync, and both export the same
  `backupgram_offsite_*` series.
- **The uploader must be able to read the dumps.** With `BACKUP_GID` the folders are
  mode `2750` and the files `0640` for that group: give the uploader the group
  (`group_add: ["<BACKUP_GID>"]`) or run it as root. The image runs as root unless you
  set `user:`.
- **One `S3_PREFIX` per server**, as with one `BACKUP_DIR` per server. Pruning treats
  every database under the prefix as its own, so a second server writing under the
  same prefix would have its copies deleted once they age out.
- **The same `TZ` on the uploader and the backup service.** Dump names carry local
  time, and the sync reads them in its own time zone: a different `TZ` shifts the age
  of every dump and the Sunday and 1st tiers.
- **Set the retention on the uploader.** It does not see the backup service's
  `BACKUP_KEEP_*`; give it `S3_KEEP_*` (or `BACKUP_KEEP_*`) of its own.
- **Keep the encryption key elsewhere too.** The bucket holds only encrypted dumps; a
  copy of `BACKUP_ENCRYPTION_KEY` that is lost with the server makes them unreadable.

---

## Layouts

The sync looks at stamped regular files in `last/` and `daily/`, once per name. It
skips dot files (an in-flight `.part` is never uploaded), `*-latest` entries and
any name that is not `<db>-YYYYMMDD-HHMMSS<suffix>`.

- **`BACKUP_LAYOUT=snapshot`:** every dump in `last/` and `daily/` is stamped, so
  every dump goes up. The Sunday and 1st-of-the-month copies are the same stamped
  files, so they go up from `daily/` while they are there.
- **`period` (default):** only `last/` holds stamped names. `daily/` keeps
  `<db>-YYYYMMDD…` names, which the sync does not take. A dump leaves `last/` after
  `BACKUP_KEEP_MINS`, so `BACKUP_KEEP_MINS` must be longer than a full backup run (the
  inline sync runs after retention, at the end of the run) and longer than the
  uploader's `S3_SCHEDULE` interval. Otherwise dumps leave `last/` before a sync sees
  them and never go off-site. The defaults (1440 minutes, every 15 minutes) are fine.

Directory-format dumps (`-Fd`) are not uploaded (`⚠️ <name>: directory dumps are not uploaded.`).
Dumps without `.gpg` are not uploaded unless `S3_ALLOW_UNENCRYPTED=TRUE`
(`⚠️ <name>: not encrypted; not uploaded (S3_ALLOW_UNENCRYPTED=FALSE).`).

---

## Retention and safety

With `S3_PRUNE=TRUE` (the default) each sync deletes what the tiers no longer keep.
A dump is kept when its age, in whole days rounded down, is within one of:

| Tier | Which dumps | Kept for |
|---|---|---|
| daily | every dump | `S3_KEEP_DAYS` days |
| weekly | the stamp is a Sunday | `S3_KEEP_WEEKS * 7 + 1` days |
| monthly | the stamp is the 1st of a month | `S3_KEEP_MONTHS * 31 + 1` days |

These are the same day counts as the local folders ([Retention Math](CONFIGURATION.md#retention-math)),
but the tiers count every stamped dump, as the `snapshot` layout does on disk. With
the `period` layout the local folders keep one dump per day, ISO week and month, while
the bucket keeps every run's dump: with an hourly `SCHEDULE`, 24 a day for
`S3_KEEP_DAYS` days, and every run on a Sunday or the 1st for the longer tiers. Size
`S3_KEEP_*` (or the lifecycle rule) for that.

Safety rules on top:

- **The newest copy of a database that still has a dump in `last/` is never
  pruned**, even when every copy is past retention. A database that keeps failing
  therefore keeps its newest off-site copy, as it does locally.
- **A dropped database ages out.** Once it has no dump left in `last/`, its copies are
  pruned by the tiers like any other.
- **A folder with no dump in `last/` prunes nothing.** A new server, or an uploader
  mounted on the wrong (empty) volume, is never taken for "every database was
  dropped": the sync prints `⚠️ off-site prune skipped: no dump in <dir>/last (a new or wrong folder?). Nothing deleted.`
  and only uploads. Pruning resumes once `last/` holds a dump, which is why a
  recovering server keeps `S3_PRUNE=FALSE` until its restore is verified
  ([Disaster recovery](#disaster-recovery)). Such a folder is not a failed sync, but it
  shows: the sync warns on every run (with `S3_PRUNE=FALSE` too),
  `backupgram_offsite_databases` reads `0` and `BackupgramOffsiteNoDatabases` fires
  after 26 h; a new deployment clears it with its first dump.
- A dump the tiers would delete straight away is not uploaded in the first place.
- Objects that are not stamped dumps at `<S3_PREFIX>/<db>/<file>` are never touched.
- A delete the server refuses is a warning, never a failure.

**Upload only, for write-only credentials.** `S3_PRUNE=FALSE` makes backupgram never
delete: give it credentials that can list, read and put objects but not delete them,
turn on object lock in the bucket, and expire old objects with a bucket lifecycle rule.
Set the rule to expire no earlier than the local retention of the dumps the sync can
still see (`BACKUP_KEEP_DAYS` days for `daily/`): the sync uploads again a dump whose
key is gone while the local file is still there.

---

## Providers

Only the endpoint and the credentials differ. Take the exact endpoint from the
provider's console.

| Provider | `S3_ENDPOINT` | `S3_REGION` | `S3_FORCE_PATH_STYLE` |
|---|---|---|---|
| AWS S3 | default (`https://s3.amazonaws.com`) | the bucket's region | `FALSE` |
| Hetzner Object Storage | `https://<location>.your-objectstorage.com` | the location, e.g. `fsn1` | `FALSE` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | the bucket's region, e.g. `us-west-004` | `FALSE` |
| Wasabi | `https://s3.<region>.wasabisys.com` | the bucket's region | `FALSE` |
| Cloudflare R2 | `https://<account-id>.r2.cloudflarestorage.com` | `auto` | `FALSE` |
| Self-hosted on another machine | `http://<host>:<port>` or `https://…` | what the server is configured with | `TRUE` |

For a self-hosted server on the other machine use an S3 server such as
[RustFS](https://github.com/rustfs/rustfs), [Garage](https://garagehq.deuxfleurs.fr/)
or [SeaweedFS](https://github.com/seaweedfs/seaweedfs) (MinIO's community images are
no longer published). Create the bucket and an access key on it first; backupgram
does not create buckets. Use `http://` only on a private network and `https://`
across the internet. Garage's default region is `garage`.

**Abort incomplete multipart uploads.** A dump over 16 MiB goes up in parts. A sync
stopped by `S3_SYNC_TIMEOUT`, or in the uploader by `docker stop`, tries to abort its
unfinished upload, but a stalled endpoint (the usual reason the limit is reached) may
not answer that either, and a sync killed outright (`SIGKILL`, a crash, the host going
down, or in backup mode a sync still running when `docker stop` ends the backup) cannot
try. The parts then stay in the bucket, invisible to `list --s3` and billed until they
are removed. Always set the provider's lifecycle rule "abort incomplete multipart uploads
after N days" (1–7 days, for example).

An `https://` endpoint whose certificate comes from a private CA: mount the CA
certificate (PEM) in a folder and set `SSL_CERT_DIR` to that folder; `s3-sync` then
trusts it besides the public CAs. `SSL_CERT_FILE` works too, but replaces the public
CAs for every tool in the container (Telegram delivery included), so point it at a
bundle that holds both.

---

## Failures and monitoring

**A backup run's exit code never changes because of off-site problems.** A failed
upload, an unreachable endpoint or wrong credentials are reported in the log, in the
metrics and by two alerts; the dumps stay local and the next sync retries what is
missing.

Log lines (the failures go to stderr):

```
☁️ mydb: uploaded shop-prod/mydb/mydb-20260416-020000.sql.gz.gpg (42.0M)
🗑️ off-site: removed shop-prod/mydb/mydb-20260401-020000.sql.gz.gpg
☁️ Off-site s3://my-backups/shop-prod: 1 uploaded, 6 already there, 0 failed, 1 pruned.
⚠️ mydb: off-site upload failed (<reason>). It will be retried on the next run.
⚠️ off-site: cannot list s3://my-backups/shop-prod (<reason>). It will be retried on the next run.
⚠️ off-site prune: could not delete <key> (<reason>).
⚠️ off-site prune skipped: no dump in /backups/last (a new or wrong folder?). Nothing deleted.
⚠️ off-site: no dump in /backups/last (a new or wrong folder?).
⚠️ off-site: the sync stopped after 3600s (S3_SYNC_TIMEOUT). It will be retried on the next run.
⚠️ off-site: skipped, an S3 setting is invalid (see above). The local backup is not affected.
⚠️ Off-site sync did not complete; the next run retries.
```

A folder with no dump in `last/` gets the `prune skipped` line, or with
`S3_PRUNE=FALSE` the `no dump` line; neither fails the sync. The `skipped` line comes
from a run whose S3 settings broke after startup ([Settings](#settings)). The last line
is the backup run's note when the sync failed (not after a `skipped` line: the next run
skips too, until the setting is fixed). In uploader mode a run
that finds the previous one still running prints `⏳ Another off-site sync is running. Not started.`
and exits `0`; a sync that failed exits `1`, so the container shows unhealthy until
the next good sync.

Five metrics are added (`backupgram_offsite_last_timestamp_seconds`,
`backupgram_offsite_last_size_bytes`, `backupgram_offsite_sync_success`,
`backupgram_offsite_sync_timestamp_seconds`, `backupgram_offsite_databases`, details in
[MONITORING.md](MONITORING.md)), and the alert rules gain three:

- `BackupgramOffsiteTooOld`: the newest off-site dump of a database is older than 26 h
  (the local backup may be fine; the copy is not keeping up).
- `BackupgramOffsiteSyncFailed`: the last sync failed, for 30 minutes.
- `BackupgramOffsiteNoDatabases`: the sync has found no dump in `last/` for 26 h, so
  nothing reaches the bucket. Usually the uploader is mounted on the wrong volume (a
  compose project prefix, a mistyped bind-mount path).

The per-database series cover the databases with a dump in local `last/`, as the
local `backupgram_backup_last_*` series do. A database whose dumps never reach the
bucket (unencrypted while `S3_ALLOW_UNENCRYPTED=FALSE`, or directory dumps) shows
timestamp `0`, so `BackupgramOffsiteTooOld` fires for it instead of staying silent. A
database that is gone from `last/` (dropped, excluded, no longer `CONNECT`-able) drops
out of the series even while its copies age out of the bucket.

---

## Disaster recovery

The server is gone; the bucket and your `BACKUP_ENCRYPTION_KEY` remain.

1. On a new server, start the image with the database settings of the new PostgreSQL
   (`POSTGRES_*`), the S3 settings (`S3_BUCKET`, `S3_ENDPOINT`, credentials and the
   same `S3_PREFIX`), `BACKUP_ENCRYPTION_KEY` and **`S3_PRUNE=FALSE`**. Keep pruning
   off until the restore is verified, then remove `S3_PRUNE=FALSE`: the first dump of
   a still-empty database would become its protected newest copy, and the tiers could
   then delete the older copies you are about to restore. (Or do not start the
   scheduled service yet and restore through a one-off container, as below.)
2. See what the bucket holds. This works in any container with the S3 settings, the
   uploader included:

   ```sh
   docker exec -it my-backup list --s3          # every database
   docker exec -it my-backup list --s3 mydb     # one database
   ```

3. Restore the newest dump of a database, or one object by its key:

   ```sh
   docker exec -it my-backup restore --from-s3 mydb
   docker exec -it my-backup restore --from-s3 mydb mydb_restored
   docker exec -it my-backup restore --from-s3 shop-prod/mydb/mydb-20260416-020000.sql.gz.gpg
   ```

   An argument with a `/` is a key; anything else is a database name.

The restore streams the object from the bucket through `gpg` into `pg_restore` /
`psql`: nothing in clear text is written to disk. A database or key the bucket does
not hold exits `1` with `❌ <name>: not found in s3://<bucket>/<prefix>.`

A stream that fails exits `1` with `❌ Could not read the backup (download interrupted, wrong BACKUP_ENCRYPTION_KEY, or a damaged object).`
A damaged object is caught when it is encrypted (gpg's integrity check) or a `.sql.gz`
(gzip's checksum); a damaged unencrypted custom-format or plain `.sql` dump shows only
as `pg_restore` / `psql` errors in the output. A restore that stops before it has read
the whole object exits `1` with
`❌ The restore stopped before it read the whole backup (see the errors above).` A wrong
key fails before anything is restored, but a download cut off part-way (or a damaged
object) may already have restored part of the dump. If the restore created the target
database, it drops it again. An existing target is left as it is and gets
`⚠️ '<db>' may be partially restored: drop it before retrying.` Drop it (or restore
under another name) before you retry.

A restore needs database access, so run it in the backup service or in a one-off
container with the same settings (`docker compose run --rm --entrypoint restore backup --from-s3 mydb`),
not in the uploader, which has none. See [CLI.md](CLI.md#restore-from-the-off-site-bucket).
