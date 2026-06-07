package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"backupgram/jobs"
)

func newTestHandlers(t *testing.T) *Handlers {
	t.Helper()
	dir := t.TempDir()
	for _, slot := range []string{"last", "daily", "weekly", "monthly"} {
		if err := os.MkdirAll(filepath.Join(dir, slot), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	jm := jobs.NewJobManager(func(name string, args []string) (string, int, error) { return "ran", 0, nil })
	t.Cleanup(jm.Stop)
	return &Handlers{BackupDir: dir, Jobs: jm, RestartSchedule: func(string) error { return nil }}
}

func TestHealthz(t *testing.T) {
	h := newTestHandlers(t)
	rec := httptest.NewRecorder()
	h.Healthz(rec, httptest.NewRequest("GET", "/healthz", nil))
	if rec.Code != 200 {
		t.Fatalf("code=%d want 200", rec.Code)
	}
	var resp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["status"] != "ok" {
		t.Errorf("status=%q want ok", resp["status"])
	}
}

func TestListBackups(t *testing.T) {
	h := newTestHandlers(t)
	if err := os.WriteFile(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	h.ListBackups(rec, httptest.NewRequest("GET", "/backups", nil))
	if rec.Code != 200 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
	var resp struct {
		Backups []map[string]any `json:"backups"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Backups) != 1 || resp.Backups[0]["name"] != "app1-1.sql.gz" {
		t.Errorf("unexpected backups: %v", resp.Backups)
	}
}

func TestStatusReportsOverrideSchedule(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("BACKUP_DIR", dir)
	if err := os.WriteFile(
		filepath.Join(dir, ".api-overrides.json"),
		[]byte(`{"SCHEDULE":"0 3 * * *"}`), 0o600,
	); err != nil {
		t.Fatal(err)
	}
	h := newTestHandlers(t)
	rec := httptest.NewRecorder()
	h.Status(rec, httptest.NewRequest("GET", "/status", nil))
	if rec.Code != 200 {
		t.Fatalf("code=%d", rec.Code)
	}
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["schedule"] != "0 3 * * *" {
		t.Errorf("schedule=%v want override '0 3 * * *'", resp["schedule"])
	}
}
