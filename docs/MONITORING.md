# Monitoring

backupgram can write Prometheus metrics after every run — they are opt-in
(`METRICS_TEXTFILE_DIR` and/or `METRICS_ENABLE=TRUE`) — and ships a Grafana dashboard
and alert rules. The metrics come from the files on disk plus the run's results, so
they survive restarts. With the textfile collector the file stays on disk, so the
timestamps stop advancing when the container is dead and the "too old" alert catches
it. With HTTP scraping a dead `backupgram-api` makes the series go stale instead (the
"too old" expression then returns nothing), which `BackupgramScrapeDown` catches.

## Two ways to collect them

**node-exporter textfile collector (no network needed).** Mount a folder that
node-exporter's `--collector.textfile.directory` also reads, and point backupgram at it:

```yaml
services:
  backup:
    image: ganiyevuz/backupgram:18-alpine
    environment:
      METRICS_TEXTFILE_DIR: /textfile
      PROJECT_NAME: shop          # becomes the project label and the file name backupgram-shop.prom
    volumes:
      - textfile:/textfile
  node-exporter:
    image: prom/node-exporter
    command: ["--collector.textfile.directory=/textfile"]
    volumes:
      - textfile:/textfile:ro
volumes:
  textfile:
```

**HTTP `/metrics`.** `METRICS_ENABLE=TRUE` makes `backupgram-api` serve
`GET /metrics` on `REST_API_PORT` (8081), without authentication, like `/healthz`.
The REST API itself stays off unless `REST_API_ENABLE=TRUE`: with only
`METRICS_ENABLE=TRUE` the server answers `/healthz` and `/metrics` and nothing else,
and needs no token.

```yaml
scrape_configs:
  - job_name: backupgram
    static_configs:
      - targets: ["backup:8081"]
```

> **Keep the port internal.** `/metrics` has no authentication and lists your
> database names and backup results. Do not publish `REST_API_PORT` to the internet:
> leave it on the Compose network Prometheus shares, bind it to loopback, or restrict
> it with a firewall or reverse proxy.

The two ways can be combined. `METRICS_ENABLE=TRUE` writes the metrics to
`${BACKUP_DIR}/.metrics.prom` (served as `/metrics`; an empty response until the
first run has finished); `METRICS_TEXTFILE_DIR` writes
`backupgram.prom` — or `backupgram-<project>.prom` when `PROJECT_NAME` is set — into
the folder you give it. Both are replaced atomically, so a scrape never sees a
half-written file.

## Metrics

Every series carries `project` (from `PROJECT_NAME`).

| Metric | Labels | Meaning |
|---|---|---|
| `backupgram_backup_last_timestamp_seconds` | `database` | When the newest dump in `last/` was written |
| `backupgram_backup_last_size_bytes` | `database` | Its size |
| `backupgram_backup_success` | `database` | 1/0 for the database in the most recent run |
| `backupgram_backup_duration_seconds` | `database` | How long its dump took in the most recent run |
| `backupgram_run_timestamp_seconds` | – | When the most recent run finished |
| `backupgram_run_duration_seconds` | – | How long it took |
| `backupgram_run_success` | – | 1 when the run exited 0 |
| `backupgram_run_databases` | `result` (`ok`/`failed`/`skipped`) | Counts of the most recent run |
| `backupgram_backup_files` | `slot` | Backups kept per folder |
| `backupgram_disk_available_bytes` | – | Free space on `BACKUP_DIR` |

A run that stops before any database is dumped (server unreachable, discovery found
nothing, low disk space) still writes the metrics, with `backupgram_run_success 0`
and no per-database success series.

### Off-site metrics

With [off-site copies](OFFSITE.md) enabled (`S3_BUCKET`), five more series describe
the bucket. They come from the status file of the last sync, so they show what the
bucket holds, not what the local folder holds (except `backupgram_offsite_databases`,
which counts what the sync found to copy). The per-database series cover the
databases with a dump in local `last/`, as the local `backupgram_backup_last_*` series
do: a database that is gone from `last/` (dropped, excluded, no longer
`CONNECT`-able) drops out even while its copies age out of the bucket, and a database
with no copy in the bucket (unencrypted dumps while `S3_ALLOW_UNENCRYPTED=FALSE`,
directory dumps) shows timestamp `0` and size `0`.

| Metric | Labels | Meaning |
|---|---|---|
| `backupgram_offsite_last_timestamp_seconds` | `database` | When the newest dump of the database in the bucket was taken (Unix time) |
| `backupgram_offsite_last_size_bytes` | `database` | Its size |
| `backupgram_offsite_sync_success` | – | 1 when the last sync succeeded, 0 when an upload or the listing failed |
| `backupgram_offsite_sync_timestamp_seconds` | – | When the last sync finished |
| `backupgram_offsite_databases` | – | Databases with a dump in local `last/`, which the sync copies; `0` means an empty or wrong folder |

- **Backup service with `S3_BUCKET`:** the series are appended to the run's metrics,
  in both `.metrics.prom` (`GET /metrics`) and the textfile.
- **Uploader (`BACKUPGRAM_MODE=s3-sync`):** it has no HTTP endpoint. It writes only the
  five off-site series, after each sync, to `METRICS_TEXTFILE_DIR` as
  `backupgram-offsite.prom`, or `backupgram-offsite-<project>.prom` when `PROJECT_NAME`
  is set (beside the backup service's own `backupgram[-<project>].prom`). Without
  `METRICS_TEXTFILE_DIR` it writes none. Give it the same `PROJECT_NAME` as the backup
  service so the series carry the same `project` label.
- With both a backup service holding `S3_BUCKET` and an uploader on one folder, both
  export the same series: use one of the two.
- A sync whose final listing failed, or that ended without writing its status file
  (stopped, or the file could not be written), reports `backupgram_offsite_sync_success 0`
  and no per-database series until the next good sync.
- A sync that finds no dump in `last/` (a new deployment before its first dump, or an
  uploader mounted on the wrong volume) is not a failed sync: it reports
  `backupgram_offsite_databases 0` and no per-database series, and warns in its log.
- Before the container's first sync (a fresh container whose first run aborted before
  the dumps) there are no off-site series at all.

## Dashboard and alerts

- Import `monitoring/grafana/backupgram.json` in Grafana (Dashboards → Import) and pick
  your Prometheus data source.
- Load `monitoring/prometheus/backupgram-alerts.yml` with `rule_files:`. It defines
  `BackupgramBackupTooOld` (> 26 h), `BackupgramBackupMissedTwice` (> 50 h),
  `BackupgramBackupFailed` (a database failed in the last run), `BackupgramRunFailed`
  (the last run failed — this also covers a run that aborted before any database, which
  has no per-database series), `BackupgramBackupShrank` (below half the 8-day maximum),
  `BackupgramLowDisk` (< 1 GiB) and `BackupgramScrapeDown` (HTTP scraping only: the
  target is down for 10 minutes; change `job="backupgram"` in the rule to your scrape
  job name). The age thresholds assume a daily `SCHEDULE`.
- For [off-site copies](OFFSITE.md) the dashboard has a table, "Age of the newest
  off-site dump", and the rules add `BackupgramOffsiteTooOld` (the newest off-site dump
  of a database is older than 26 h: the local backup may be fine, the copy is not
  keeping up), `BackupgramOffsiteSyncFailed` (the last sync failed, for 30 minutes) and
  `BackupgramOffsiteNoDatabases` (the sync has found no dump in `last/` for 26 h,
  usually an uploader mounted on the wrong volume; a new deployment clears it with its
  first dump). They only fire when the off-site series exist, and the 26 h thresholds
  assume a daily backup. A live database that never reaches the bucket has timestamp
  `0`, so `BackupgramOffsiteTooOld` fires for it.
