package handlers

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func newFileH(t *testing.T) *Handlers {
	t.Helper()
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "last"), 0o755)
	return &Handlers{BackupDir: dir}
}

func TestDownloadStreamsFile(t *testing.T) {
	h := newFileH(t)
	os.WriteFile(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz"), []byte("DUMP"), 0o644)
	req := httptest.NewRequest("GET", "/backups/last/app1-1.sql.gz", nil)
	req.SetPathValue("slot", "last")
	req.SetPathValue("name", "app1-1.sql.gz")
	rec := httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code != 200 || rec.Body.String() != "DUMP" {
		t.Fatalf("code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestDownloadMissing404(t *testing.T) {
	h := newFileH(t)
	req := httptest.NewRequest("GET", "/backups/last/nope.sql.gz", nil)
	req.SetPathValue("slot", "last")
	req.SetPathValue("name", "nope.sql.gz")
	rec := httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code != 404 {
		t.Fatalf("code=%d want 404", rec.Code)
	}
}

func TestDownloadTraversalRejected(t *testing.T) {
	h := newFileH(t)
	req := httptest.NewRequest("GET", "/backups/last/x", nil)
	req.SetPathValue("slot", "last")
	req.SetPathValue("name", "../../etc/passwd")
	rec := httptest.NewRecorder()
	h.Download(rec, req)
	if rec.Code == 200 {
		t.Fatalf("traversal must not succeed (code=%d)", rec.Code)
	}
}

func TestDeleteRequiresConfirm(t *testing.T) {
	h := newFileH(t)
	os.WriteFile(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz"), []byte("x"), 0o644)
	// no confirm -> 400
	req := httptest.NewRequest("DELETE", "/backups/last/app1-1.sql.gz", nil)
	req.SetPathValue("slot", "last")
	req.SetPathValue("name", "app1-1.sql.gz")
	rec := httptest.NewRecorder()
	h.Delete(rec, req)
	if rec.Code != 400 {
		t.Fatalf("no-confirm code=%d want 400", rec.Code)
	}
	// confirm -> 200 + removed
	req = httptest.NewRequest("DELETE", "/backups/last/app1-1.sql.gz?confirm=true", nil)
	req.SetPathValue("slot", "last")
	req.SetPathValue("name", "app1-1.sql.gz")
	rec = httptest.NewRecorder()
	h.Delete(rec, req)
	if rec.Code != 200 {
		t.Fatalf("delete code=%d want 200 body=%s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(filepath.Join(h.BackupDir, "last", "app1-1.sql.gz")); !os.IsNotExist(err) {
		t.Error("file should be deleted")
	}
}
