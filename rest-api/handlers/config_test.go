package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"pgbackupapi/config"
)

func newConfigH(t *testing.T) *Handlers {
	t.Helper()
	t.Setenv("BACKUP_DIR", t.TempDir()) // config reads BACKUP_DIR for the override file
	return &Handlers{RestartSchedule: func(string) error { return nil }}
}

func patchReq(h *Handlers, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.PatchConfig(rec, httptest.NewRequest("PATCH", "/config", strings.NewReader(body)))
	return rec
}

func TestGetConfigMasksSecret(t *testing.T) {
	h := newConfigH(t)
	if _, err := config.ApplyPatch(map[string]string{"TELEGRAM_BOT_TOKEN": "tok"}); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	h.GetConfig(rec, httptest.NewRequest("GET", "/config", nil))
	if rec.Code != 200 {
		t.Fatalf("code=%d", rec.Code)
	}
	var resp struct {
		Config map[string]map[string]any `json:"config"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if _, leaked := resp.Config["TELEGRAM_BOT_TOKEN"]["value"]; leaked {
		t.Error("secret value leaked in GET /config")
	}
	if resp.Config["TELEGRAM_BOT_TOKEN"]["set"] != true {
		t.Error("secret should report set=true")
	}
}

func TestPatchBlockedKey(t *testing.T) {
	h := newConfigH(t)
	if rec := patchReq(h, `{"POSTGRES_PASSWORD":"x"}`); rec.Code != 403 {
		t.Fatalf("code=%d want 403", rec.Code)
	}
}

func TestPatchScheduleRestarts(t *testing.T) {
	h := newConfigH(t)
	var n int32
	h.RestartSchedule = func(s string) error { atomic.AddInt32(&n, 1); return nil }
	if rec := patchReq(h, `{"SCHEDULE":"@hourly"}`); rec.Code != 200 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
	if atomic.LoadInt32(&n) != 1 {
		t.Errorf("restarts=%d want 1", n)
	}
}

func TestPatchEmpty400(t *testing.T) {
	h := newConfigH(t)
	if rec := patchReq(h, `{}`); rec.Code != 400 {
		t.Fatalf("code=%d want 400", rec.Code)
	}
}

func TestPatchAllOrNothing(t *testing.T) {
	h := newConfigH(t)
	// one valid, one invalid -> nothing should be written
	if rec := patchReq(h, `{"BACKUP_KEEP_DAYS":"5","TELEGRAM_NOTIFY_ON":"bogus"}`); rec.Code != 400 {
		t.Fatalf("code=%d want 400", rec.Code)
	}
	cfg, _ := config.Effective()
	if cfg["BACKUP_KEEP_DAYS"].(map[string]any)["source"] == "override" {
		t.Error("partial write happened; PATCH must be all-or-nothing")
	}
}

func TestDeleteConfigKey(t *testing.T) {
	h := newConfigH(t)
	if _, err := config.ApplyPatch(map[string]string{"BACKUP_KEEP_DAYS": "9"}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("DELETE", "/config/BACKUP_KEEP_DAYS", nil)
	req.SetPathValue("key", "BACKUP_KEEP_DAYS")
	rec := httptest.NewRecorder()
	h.DeleteConfig(rec, req)
	if rec.Code != 200 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
}

func TestDeleteConfigNotSet404(t *testing.T) {
	h := newConfigH(t)
	req := httptest.NewRequest("DELETE", "/config/BACKUP_KEEP_DAYS", nil)
	req.SetPathValue("key", "BACKUP_KEEP_DAYS")
	rec := httptest.NewRecorder()
	h.DeleteConfig(rec, req)
	if rec.Code != 404 {
		t.Fatalf("code=%d want 404", rec.Code)
	}
}

func TestDeleteConfigBlockedKey403(t *testing.T) {
	h := newConfigH(t)
	req := httptest.NewRequest("DELETE", "/config/POSTGRES_PASSWORD", nil)
	req.SetPathValue("key", "POSTGRES_PASSWORD")
	rec := httptest.NewRecorder()
	h.DeleteConfig(rec, req)
	if rec.Code != 403 {
		t.Fatalf("code=%d want 403 (blocked key)", rec.Code)
	}
}
