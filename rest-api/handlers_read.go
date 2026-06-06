package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
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
	writeJSON(w, 200, resp)
}

func (a *App) handleListBackups(w http.ResponseWriter, r *http.Request) {
	type entry struct {
		Slot  string `json:"slot"`
		Name  string `json:"name"`
		Size  int64  `json:"size"`
		Mtime int64  `json:"mtime"`
	}
	out := []entry{}
	for slot := range validSlots {
		dir := filepath.Join(a.BackupDir, slot)
		items, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, it := range items {
			if it.IsDir() {
				continue
			}
			info, err := it.Info()
			if err != nil {
				continue
			}
			out = append(out, entry{slot, it.Name(), info.Size(), info.ModTime().Unix()})
		}
	}
	writeJSON(w, 200, map[string]any{"backups": out})
}

func getenvOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
