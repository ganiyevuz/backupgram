package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"backupgram/handlers"
	"backupgram/jobs"
)

func newTestHandlers(t *testing.T) *handlers.Handlers {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("BACKUP_DIR", dir)
	for _, slot := range []string{"last", "daily", "weekly", "monthly"} {
		if err := os.MkdirAll(filepath.Join(dir, slot), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	jm := jobs.NewJobManager(func(name string, args []string) (string, int, error) { return "ran", 0, nil })
	t.Cleanup(jm.Stop)
	return &handlers.Handlers{BackupDir: dir, Jobs: jm, RestartSchedule: func(string) error { return nil }}
}

func do(t *testing.T, h *handlers.Handlers, method, path, token, body string) *httptest.ResponseRecorder {
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	Router("secret", h).ServeHTTP(rec, req)
	return rec
}

func TestHealthzNoAuth(t *testing.T) {
	h := newTestHandlers(t)
	rec := do(t, h, "GET", "/healthz", "", "")
	if rec.Code != 200 {
		t.Fatalf("healthz code=%d want 200", rec.Code)
	}
}

func TestStatusRequiresAuth(t *testing.T) {
	h := newTestHandlers(t)
	rec := do(t, h, "GET", "/status", "", "")
	if rec.Code != 401 {
		t.Fatalf("status code=%d want 401", rec.Code)
	}
}

func TestStatusWrongTokenSameLength(t *testing.T) {
	// "wrongx" is the same length as "secret"; exercises ConstantTimeCompare path.
	h := newTestHandlers(t)
	rec := do(t, h, "GET", "/status", "wrongx", "")
	if rec.Code != 401 {
		t.Fatalf("status code=%d want 401", rec.Code)
	}
}

func TestStatusGoodToken(t *testing.T) {
	h := newTestHandlers(t)
	rec := do(t, h, "GET", "/status", "secret", "")
	if rec.Code != 200 {
		t.Fatalf("status code=%d want 200", rec.Code)
	}
}

func TestBackupsList(t *testing.T) {
	h := newTestHandlers(t)
	if err := os.WriteFile(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := do(t, h, "GET", "/backups", "secret", "")
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

func TestAuthEmptyTokenPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic for empty token")
		}
	}()
	authMiddleware("", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
}

func TestDownloadRoute(t *testing.T) {
	h := newTestHandlers(t)
	if err := os.WriteFile(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz"), []byte("FILEDATA"), 0o644); err != nil {
		t.Fatal(err)
	}

	// with valid token -> 200, body matches file
	rec := do(t, h, "GET", "/backups/last/app1-1.sql.gz", "secret", "")
	if rec.Code != 200 {
		t.Fatalf("download code=%d want 200 body=%s", rec.Code, rec.Body)
	}
	if rec.Body.String() != "FILEDATA" {
		t.Fatalf("body=%q want %q", rec.Body.String(), "FILEDATA")
	}

	// without token -> 401
	rec = do(t, h, "GET", "/backups/last/app1-1.sql.gz", "", "")
	if rec.Code != 401 {
		t.Fatalf("no-auth code=%d want 401", rec.Code)
	}
}

func TestDeleteRequiresAuth(t *testing.T) {
	h := newTestHandlers(t)
	rec := do(t, h, "DELETE", "/backups/last/whatever.sql.gz", "", "")
	if rec.Code != 401 {
		t.Fatalf("no-auth code=%d want 401", rec.Code)
	}
}

func TestConfigRouteAuth(t *testing.T) {
	t.Setenv("BACKUP_DIR", t.TempDir())
	h := newTestHandlers(t)

	// with valid token -> 200
	rec := do(t, h, "GET", "/config", "secret", "")
	if rec.Code != 200 {
		t.Fatalf("GET /config with token: code=%d want 200 body=%s", rec.Code, rec.Body)
	}

	// without token -> 401
	rec = do(t, h, "GET", "/config", "", "")
	if rec.Code != 401 {
		t.Fatalf("GET /config without token: code=%d want 401", rec.Code)
	}
}

func TestBackupRouteAndJobQuery(t *testing.T) {
	h := newTestHandlers(t)

	// POST /backup -> 202 + job_id
	rec := do(t, h, "POST", "/backup", "secret", "")
	if rec.Code != 202 {
		t.Fatalf("POST /backup code=%d want 202 body=%s", rec.Code, rec.Body)
	}
	var backupResp struct {
		JobID string `json:"job_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &backupResp); err != nil {
		t.Fatal(err)
	}
	if backupResp.JobID == "" {
		t.Fatal("POST /backup: missing job_id in response")
	}

	// GET /jobs/{id} -> 200 (proves {id} path param plumbing)
	rec = do(t, h, "GET", "/jobs/"+backupResp.JobID, "secret", "")
	if rec.Code != 200 {
		t.Fatalf("GET /jobs/%s code=%d want 200 body=%s", backupResp.JobID, rec.Code, rec.Body)
	}
}
