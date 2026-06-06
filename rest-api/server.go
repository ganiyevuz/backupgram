package main

import (
	"encoding/json"
	"net/http"
)

// App holds server dependencies.
type App struct {
	Token           string
	BackupDir       string
	Jobs            *JobManager
	RestartSchedule func(newSchedule string) error
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	status := 500
	if ae, ok := err.(*apiError); ok {
		status = ae.Status
	}
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

// Router builds the mux: /healthz is open; everything else is auth-wrapped.
// NOTE: file, job, and config routes are registered by later tasks.
func (a *App) Router() http.Handler {
	protected := http.NewServeMux()
	protected.HandleFunc("GET /status", a.handleStatus)
	protected.HandleFunc("GET /backups", a.handleListBackups)

	root := http.NewServeMux()
	root.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	root.Handle("/", authMiddleware(a.Token, protected))
	return root
}
