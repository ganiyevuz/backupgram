package handlers

import (
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"pgbackupapi/backups"
	"pgbackupapi/httpx"
	"pgbackupapi/jobs"
)

// Handlers holds the dependencies the HTTP handlers need.
type Handlers struct {
	BackupDir       string
	Jobs            *jobs.JobManager
	RestartSchedule func(newSchedule string) error
}

func (h *Handlers) Healthz(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, 200, map[string]string{"status": "ok"})
}

func (h *Handlers) Status(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"schedule": getenvOr("SCHEDULE", "@daily"),
		"cluster":  os.Getenv("POSTGRES_CLUSTER") == "TRUE",
	}
	if raw, err := os.ReadFile("/tmp/backup_status"); err == nil {
		lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
		last := map[string]any{}
		if len(lines) > 0 {
			last["status"] = lines[0]
		}
		if len(lines) > 1 {
			if ts, err := strconv.ParseInt(strings.TrimSpace(lines[1]), 10, 64); err == nil {
				last["timestamp"] = ts
				last["age_seconds"] = time.Now().Unix() - ts
			}
		}
		resp["last_backup"] = last
	}
	httpx.WriteJSON(w, 200, resp)
}

func (h *Handlers) ListBackups(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, 200, map[string]any{"backups": backups.List(h.BackupDir)})
}

func getenvOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
