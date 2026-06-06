package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestApp(t *testing.T) *App {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("BACKUP_DIR", dir)
	for _, slot := range []string{"last", "daily", "weekly", "monthly"} {
		os.MkdirAll(filepath.Join(dir, slot), 0o755)
	}
	jm := NewJobManager(func(name string, args []string) (string, int, error) { return "ran", 0, nil })
	t.Cleanup(jm.Stop)
	return &App{Token: "secret", BackupDir: dir, Jobs: jm, RestartSchedule: func(string) error { return nil }}
}

func do(app *App, method, path, body string) *httptest.ResponseRecorder {
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	app.Router().ServeHTTP(rec, req)
	return rec
}

func TestHealthzNoAuth(t *testing.T) {
	app := newTestApp(t)
	req := httptest.NewRequest("GET", "/healthz", nil) // no token
	rec := httptest.NewRecorder()
	app.Router().ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("healthz code=%d want 200", rec.Code)
	}
}

func TestStatusRequiresAuth(t *testing.T) {
	app := newTestApp(t)
	req := httptest.NewRequest("GET", "/status", nil)
	rec := httptest.NewRecorder()
	app.Router().ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("status code=%d want 401", rec.Code)
	}
}

func TestBackupsList(t *testing.T) {
	app := newTestApp(t)
	os.WriteFile(filepath.Join(app.BackupDir, "last", "app1-1.sql.gz"), []byte("x"), 0o644)
	rec := do(app, "GET", "/backups", "")
	if rec.Code != 200 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
	var resp struct {
		Backups []map[string]any `json:"backups"`
	}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if len(resp.Backups) != 1 || resp.Backups[0]["name"] != "app1-1.sql.gz" {
		t.Errorf("unexpected backups: %v", resp.Backups)
	}
}
