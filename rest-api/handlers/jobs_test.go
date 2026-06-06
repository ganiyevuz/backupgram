package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"pgbackupapi/jobs"
)

func newJobsH(t *testing.T) *Handlers {
	t.Helper()
	jm := jobs.NewJobManager(func(name string, args []string) (string, int, error) { return "ok", 0, nil })
	t.Cleanup(jm.Stop)
	return &Handlers{BackupDir: t.TempDir(), Jobs: jm}
}

func TestBackupReturns202(t *testing.T) {
	h := newJobsH(t)
	rec := httptest.NewRecorder()
	h.Backup(rec, httptest.NewRequest("POST", "/backup", nil))
	if rec.Code != 202 {
		t.Fatalf("code=%d want 202 body=%s", rec.Code, rec.Body)
	}
	var resp struct {
		JobID string `json:"job_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.JobID == "" {
		t.Fatal("missing job_id")
	}
}

func restoreReq(h *Handlers, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.Restore(rec, httptest.NewRequest("POST", "/restore", strings.NewReader(body)))
	return rec
}

func TestRestoreValidation(t *testing.T) {
	h := newJobsH(t)
	for _, b := range []string{
		`{"file":"last/x.sql.gz","target_db":"d"}`,                                        // no confirm
		`{"file":"last/x.sql.gz","confirm":true}`,                                         // no target
		`{"file":"last/x.sql.gz","telegram_message_id":5,"target_db":"d","confirm":true}`, // both sources
		`{"target_db":"d","confirm":true}`,                                                // neither source
		`{"file":"badformat","target_db":"d","confirm":true}`,                             // bad file form
		`{"telegram_message_id":-1,"target_db":"d","confirm":true}`,                       // non-positive tg id
		`{"file":"last/x.sql.gz","target_db":"-flag","confirm":true}`,                     // flag-smuggling target_db
		`{"file":"last/x.sql.gz","target_db":"bad name","confirm":true}`,                  // invalid chars in target_db
		`not json`, // bad body
	} {
		if rec := restoreReq(h, b); rec.Code != 400 {
			t.Errorf("body %q -> code %d want 400", b, rec.Code)
		}
	}
}

func TestRestoreFromFile202(t *testing.T) {
	h := newJobsH(t)
	// 202 even though the file doesn't exist: the handler validates path shape + enqueues;
	// existence is the restore job's concern at run time, not the handler's.
	if rec := restoreReq(h, `{"file":"last/app1-1.sql.gz","target_db":"app1_r","confirm":true}`); rec.Code != 202 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
}

func TestRestoreFromTelegram202(t *testing.T) {
	h := newJobsH(t)
	if rec := restoreReq(h, `{"telegram_message_id":1234,"target_db":"app1_r","confirm":true}`); rec.Code != 202 {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body)
	}
}

func TestGetJobNotFound(t *testing.T) {
	h := newJobsH(t)
	req := httptest.NewRequest("GET", "/jobs/nope", nil)
	req.SetPathValue("id", "nope")
	rec := httptest.NewRecorder()
	h.GetJob(rec, req)
	if rec.Code != 404 {
		t.Fatalf("code=%d want 404", rec.Code)
	}
}
