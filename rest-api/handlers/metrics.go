package handlers

import (
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"

	"backupgram/httpx"
)

// MetricsFile is the file backup.sh writes in BACKUP_DIR when METRICS_ENABLE=TRUE.
const MetricsFile = ".metrics.prom"

// Metrics serves the metrics backup.sh wrote after its last run, in the Prometheus
// text exposition format. Before the first run there is no file yet: an empty 200
// keeps the scrape healthy.
func (h *Handlers) Metrics(w http.ResponseWriter, r *http.Request) {
	raw, err := os.ReadFile(filepath.Join(h.BackupDir, MetricsFile))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		httpx.WriteError(w, &httpx.Error{Status: 500, Msg: "could not read metrics"})
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}
