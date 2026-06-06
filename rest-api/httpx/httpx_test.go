package httpx

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"testing"
)

func TestWriteErrorMapsErrorStatus(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteError(rec, &Error{Status: 403, Msg: "nope"})
	if rec.Code != 403 {
		t.Fatalf("code=%d want 403", rec.Code)
	}
	var resp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["error"] != "nope" {
		t.Errorf("error=%q want nope", resp["error"])
	}
}

func TestWriteErrorNonErrorIs500(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteError(rec, errors.New("boom"))
	if rec.Code != 500 {
		t.Fatalf("code=%d want 500", rec.Code)
	}
}

func TestWriteJSONSetsContentTypeAndStatus(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteJSON(rec, 201, map[string]string{"k": "v"})
	if rec.Code != 201 {
		t.Fatalf("code=%d want 201", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type=%q want application/json", ct)
	}
	var resp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["k"] != "v" {
		t.Errorf("body=%v want {k:v}", resp)
	}
}
