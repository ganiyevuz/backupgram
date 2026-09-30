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
