# REST API Control Surface

The image ships an optional HTTP API that lets you trigger backups, inspect
state, download or delete backup files, initiate restores, and change a
whitelisted subset of runtime settings — all over plain HTTP with a bearer
token. When disabled (the default) nothing changes: `go-cron` is PID 1 exactly
as before.

- [Enabling the API](#enabling-the-api)
- [Authentication](#authentication)
- [TLS / reverse-proxy warning](#tls--reverse-proxy-warning)
- [Endpoints](#endpoints)
- [Async jobs](#async-jobs)
- [Runtime config](#runtime-config)
- [curl examples](#curl-examples)

---

## Enabling the API

Set `REST_API_ENABLE=TRUE` and supply a token. When enabled, the bundled
`backupgram-api` binary becomes PID 1 and supervises `go-cron`; the cron
schedule and the `8080` healthcheck endpoint are unchanged.

```yaml
services:
  backup:
    image: ganiyevuz/backupgram:17
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      SCHEDULE: "@daily"
      TELEGRAM_BOT_TOKEN: "${TELEGRAM_BOT_TOKEN}"
      TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
      # --- REST API ---
      REST_API_ENABLE: "TRUE"
      REST_API_TOKEN: "${REST_API_TOKEN}"   # required; see also REST_API_TOKEN_FILE
    ports:
      - "127.0.0.1:8081:8081"              # bind to loopback; use a reverse proxy for remote access
    volumes:
      - backups:/backups
```

See [`examples/docker-compose.rest-api.yml`](https://github.com/ganiyevuz/backupgram/blob/main/examples/docker-compose.rest-api.yml)
for a ready-to-run compose file.

| Variable | Default | Description |
|---|---|---|
| `REST_API_ENABLE` | `FALSE` | Set `TRUE` to enable. |
| `REST_API_PORT` | `8081` | Listening port (separate from the `8080` healthcheck). |
| `REST_API_TOKEN` | `""` | Admin bearer token. **Required** when the API is enabled. |
| `REST_API_TOKEN_FILE` | `""` | Docker-secret path for the token (takes precedence over `REST_API_TOKEN`). |

---

## Authentication

Every request (except `GET /healthz`) must include:

```
Authorization: Bearer <token>
```

A missing or wrong token returns `401 Unauthorized`. The token is set once at
startup via `REST_API_TOKEN` (or its `_FILE` Docker-secret variant).

`GET /healthz` is intentionally open so load-balancers and orchestrators can
probe liveness without a credential.

---

## TLS / reverse-proxy warning

**The API has no built-in TLS.** It speaks plain HTTP. Do not expose port
`8081` to the public internet without fronting it with a TLS-terminating
reverse proxy (nginx, Caddy, Traefik, etc.).

The example compose file binds the port to `127.0.0.1` (`127.0.0.1:8081:8081`)
so it is only reachable on the host loopback by default. If you need remote
access, place a proxy in front and let the proxy handle TLS — never bind
directly to `0.0.0.0` in a production deployment.

---

## Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/healthz` | none | Liveness probe → `{"status":"ok"}` |
| `GET` | `/status` | bearer | Config summary + last backup result |
| `GET` | `/backups` | bearer | Inventory: `[{slot, name, size, mtime}, …]` |
| `GET` | `/backups/{slot}/{name}` | bearer | Download a dump file |
| `DELETE` | `/backups/{slot}/{name}?confirm=true` | bearer | Delete a backup (`confirm=true` required) |
| `POST` | `/backup` | bearer | Trigger a backup → `202 {"job_id":"…"}` |
| `POST` | `/restore` | bearer | Restore a backup → `202 {"job_id":"…"}` |
| `GET` | `/jobs` | bearer | List all async job states |
| `GET` | `/jobs/{id}` | bearer | State of one job (`queued/running/succeeded/failed`) |
| `GET` | `/config` | bearer | Effective runtime config (secrets masked) |
| `PATCH` | `/config` | bearer | Update whitelisted keys; all-or-nothing |
| `DELETE` | `/config/{key}` | bearer | Clear one override (revert to base env) |

### `POST /restore` body

```json
{
  "file": "last/mydb-20260416-143000.sql.gz",
  "target_db": "mydb",
  "confirm": true
}
```

Or, for a Telegram-sourced restore:

```json
{
  "telegram_message_id": 4521,
  "target_db": "mydb_restored",
  "confirm": true
}
```

Rules:
- Exactly one of `file` or `telegram_message_id` must be set.
- `target_db` must match `^[A-Za-z_][A-Za-z0-9_]{0,62}$`.
- `confirm: true` is required (guards against accidental restores).

---

## Async jobs

`POST /backup` and `POST /restore` return `202 Accepted` immediately with a job
id. Poll `GET /jobs/{id}` until the state is terminal:

| State | Meaning |
|---|---|
| `queued` | Accepted, not yet started |
| `running` | In progress |
| `succeeded` | Completed without error |
| `failed` | Completed with an error (check `state`, `error`, and `log_tail`) |

```json
{
  "id": "a1b2c3d4e5f6a7b8",
  "type": "backup",
  "state": "succeeded",
  "queued_at": 1780735738,
  "started_at": 1780735738,
  "finished_at": 1780735739,
  "exit_code": 0,
  "log_tail": ["...up to last 50 lines of combined output..."],
  "error": ""
}
```

`GET /jobs` returns the full list (most recent first). Job history is kept
in-memory and cleared on container restart.

---

## Runtime config

`GET /config` returns the effective value of every mutable key. Non-secret
keys appear as `{"value":"...","source":"base|override"}`. Secret (write-only)
keys are masked — the `value` field is omitted entirely and only `set` and
`source` are returned: `{"set":true,"source":"base"}` if configured,
`{"set":false,"source":"base"}` if not set.

`PATCH /config` accepts a JSON object of `{KEY: value}` pairs. The update is
atomic (all-or-nothing): if any key is blocked the entire request is rejected
with `403`. A `SCHEDULE` change takes effect immediately by restarting
`go-cron` with the new expression. Overrides are written to
`${BACKUP_DIR}/.api-overrides.env` and survive container restarts (as long as
the volume is mounted).

`DELETE /config/{key}` removes one override, reverting that key to whatever
the base environment provides.

### Whitelisted mutable keys

| Key | Masked in GET? |
|---|---|
| `SCHEDULE` | no |
| `BACKUP_KEEP_MINS` | no |
| `BACKUP_KEEP_DAYS` | no |
| `BACKUP_KEEP_WEEKS` | no |
| `BACKUP_KEEP_MONTHS` | no |
| `POSTGRES_DB` | no |
| `POSTGRES_DB_AUTODISCOVER` | no |
| `POSTGRES_DB_EXCLUDE` | no |
| `POSTGRES_EXTRA_OPTS` | no |
| `POSTGRES_EXCLUDE_TABLES` | no |
| `TELEGRAM_CHAT_ID` | no |
| `TELEGRAM_THREAD_ID` | no |
| `TELEGRAM_NOTIFY_ON` | no |
| `TELEGRAM_API_URL` | no |
| `BACKUP_MIN_DISK_SPACE` | no |
| `BACKUP_MAX_AGE_HOURS` | no |
| `WEBHOOK_EXTRA_ARGS` | no |
| `TELEGRAM_BOT_TOKEN` | **yes** (write-only) |
| `TELEGRAM_API_ID` | **yes** (write-only) |
| `TELEGRAM_API_HASH` | **yes** (write-only) |
| `WEBHOOK_URL` | **yes** (write-only) |

### Blocked keys (always 403)

Connection credentials (`POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`,
all `*_FILE` variants), `BACKUP_DIR`, `BACKUP_ENCRYPTION_KEY`, all
`REST_API_*` keys, `POSTGRES_CLUSTER`, and any startup-only variable are
blocked. Attempting to `PATCH` them returns `403 Forbidden`.

### `*_FILE` precedence caveat

A Docker-secret file (`*_FILE`) always wins over an API override of the same
credential. For example, if `TELEGRAM_BOT_TOKEN_FILE` is mounted, a `PATCH`
to `TELEGRAM_BOT_TOKEN` is accepted and persisted, but the running value is
still read from the secret file. Avoid managing the same credential by both
paths.

---

## curl examples

### Liveness

```sh
curl http://localhost:8081/healthz
# {"status":"ok"}
```

### Status

```sh
curl -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/status
```

### Trigger a backup and poll until done

```sh
# Start a backup
JOB=$(curl -s -X POST \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/backup | jq -r .job_id)

# Poll
until [ "$(curl -s -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/jobs/$JOB | jq -r .state)" != "running" ]; do
  sleep 2
done

curl -s -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/jobs/$JOB | jq .
```

### List backups and download one

```sh
# List
curl -s -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/backups | jq .

# Download daily/mydb-20260416.sql.gz
curl -OJ -H "Authorization: Bearer $REST_API_TOKEN" \
  "http://localhost:8081/backups/daily/mydb-20260416.sql.gz"
```

### Delete a backup

```sh
curl -X DELETE \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  "http://localhost:8081/backups/last/mydb-20260416-143000.sql.gz?confirm=true"
```

### Restore from a stored file

```sh
curl -s -X POST \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file":"last/mydb-20260416-143000.sql.gz","target_db":"mydb","confirm":true}' \
  http://localhost:8081/restore | jq .
```

### Restore from a Telegram message id

```sh
curl -s -X POST \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"telegram_message_id":4521,"target_db":"mydb_restored","confirm":true}' \
  http://localhost:8081/restore | jq .
```

### Read, update, and clear config

```sh
# Read effective config
curl -s -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/config | jq .

# Change schedule and retention
curl -s -X PATCH \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"SCHEDULE":"0 3 * * *","BACKUP_KEEP_DAYS":"14"}' \
  http://localhost:8081/config | jq .

# Revert SCHEDULE override (go back to the base env value)
curl -X DELETE \
  -H "Authorization: Bearer $REST_API_TOKEN" \
  http://localhost:8081/config/SCHEDULE
```
