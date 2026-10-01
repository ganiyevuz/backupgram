package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func settings() Settings {
	return Settings{Location: "s3://b/p", Prefix: "p", Retention: policy, Prune: true}
}

func TestRunSyncUploadsWhatIsMissing(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	writeFile(t, filepath.Join(dir, "daily", "db-20261122-040000.dump.gpg"), 8)
	st := newFake()
	st.objects["p/db/db-20261122-040000.dump.gpg"] = make([]byte, 8)
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), dir, at(2026, 11, 24, 12), &out, &errOut)
	if !res.OK || res.Uploaded != 1 || res.Present != 1 || res.Failed != 0 {
		t.Fatalf("result %+v\nout %s\nerr %s", res, out.String(), errOut.String())
	}
	if !strings.Contains(out.String(), "☁️ db: uploaded p/db/db-20261123-040000.dump.gpg (10)") {
		t.Errorf("out = %s", out.String())
	}
	if !strings.Contains(out.String(), "☁️ Off-site s3://b/p: 1 uploaded, 1 already there, 0 failed, 0 pruned.") {
		t.Errorf("summary missing: %s", out.String())
	}
	if len(res.Objects) != 2 {
		t.Errorf("objects after sync = %+v", res.Objects)
	}
}

func TestRunSyncFailures(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "a-20261123-040000.dump.gpg"), 10)
	writeFile(t, filepath.Join(dir, "last", "b-20261123-040000.dump.gpg"), 10)
	writeFile(t, filepath.Join(dir, "last", "c-20261123-040000.dump.gpg"), 10)
	st := newFake()
	st.putErr["p/a/a-20261123-040000.dump.gpg"] = errors.New("connection reset")
	st.shortStat["p/b/b-20261123-040000.dump.gpg"] = true
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), dir, at(2026, 11, 24, 12), &out, &errOut)
	if res.OK || res.Failed != 2 || res.Uploaded != 1 {
		t.Fatalf("result %+v", res)
	}
	for _, want := range []string{
		"⚠️ a: off-site upload failed (connection reset). It will be retried on the next run.",
		"⚠️ b: off-site upload failed (size check: bucket has 9 bytes, local file 10). It will be retried on the next run.",
	} {
		if !strings.Contains(errOut.String(), want) {
			t.Errorf("stderr lacks %q:\n%s", want, errOut.String())
		}
	}
}

func TestRunSyncListFailure(t *testing.T) {
	st := newFake()
	st.listErr = errors.New("SignatureDoesNotMatch")
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), t.TempDir(), at(2026, 11, 24, 12), &out, &errOut)
	if res.OK {
		t.Fatal("a failed listing must fail the sync")
	}
	if !strings.Contains(errOut.String(), "⚠️ off-site: cannot list s3://b/p (SignatureDoesNotMatch). It will be retried on the next run.") {
		t.Errorf("stderr = %s", errOut.String())
	}
}

func TestRunSyncPrunes(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	st := newFake()
	st.objects["p/db/db-20261123-040000.dump.gpg"] = make([]byte, 10)
	st.objects["p/db/db-20261110-040000.dump.gpg"] = make([]byte, 10)     // expires
	st.objects["p/gone/gone-20260910-040000.dump.gpg"] = make([]byte, 10) // dropped: expires
	st.objects["p/db/db-20261109-040000.dump.gpg"] = make([]byte, 10)     // expires, but deleting is refused
	st.removeErr["p/db/db-20261109-040000.dump.gpg"] = errors.New("Access Denied")
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), dir, at(2026, 11, 24, 12), &out, &errOut)
	if !res.OK || res.Pruned != 2 {
		t.Fatalf("result %+v\nerr %s", res, errOut.String())
	}
	if _, ok := st.objects["p/db/db-20261110-040000.dump.gpg"]; ok {
		t.Error("an expired object survived")
	}
	if !strings.Contains(out.String(), "🗑️ off-site: removed p/gone/gone-20260910-040000.dump.gpg") {
		t.Errorf("out = %s", out.String())
	}
	if !strings.Contains(errOut.String(), "⚠️ off-site prune: could not delete p/db/db-20261109-040000.dump.gpg (Access Denied).") {
		t.Errorf("a refused delete must be a warning: %s", errOut.String())
	}

	s := settings()
	s.Prune = false
	st.objects["p/db/db-20261002-040000.dump.gpg"] = make([]byte, 10) // a Friday, age 53: expires
	res = RunSync(context.Background(), st, s, dir, at(2026, 11, 24, 12), &out, &errOut)
	if _, ok := st.objects["p/db/db-20261002-040000.dump.gpg"]; !ok || res.Pruned != 0 {
		t.Errorf("S3_PRUNE=FALSE pruned %d objects (the expired one kept: %v)", res.Pruned, ok)
	}
}

func TestRunSyncLeavesObjectsOutsideTheLayoutAlone(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	st := newFake()
	st.objects["p/db/db-20261110-040000.dump.gpg"] = make([]byte, 10) // in the layout, expires: pruned
	// Stamped, past retention (a Wednesday, age 83), but not at <prefix>/<db>/<name>: not ours to delete.
	st.objects["p/x/y/old-20260902-040000.dump.gpg"] = make([]byte, 10)
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), dir, at(2026, 11, 24, 12), &out, &errOut)
	if !res.OK || res.Pruned != 1 {
		t.Fatalf("result %+v\nerr %s", res, errOut.String())
	}
	if _, ok := st.objects["p/db/db-20261110-040000.dump.gpg"]; ok {
		t.Error("the expired in-layout object survived")
	}
	if _, ok := st.objects["p/x/y/old-20260902-040000.dump.gpg"]; !ok {
		t.Error("an object outside the layout was deleted")
	}
	if strings.Contains(out.String(), "old-20260902") {
		t.Errorf("out mentions the foreign object: %s", out.String())
	}
	if len(res.Objects) != 1 || res.Objects[0].Key != "p/db/db-20261123-040000.dump.gpg" {
		t.Errorf("objects after sync = %+v, want only the uploaded dump", res.Objects)
	}
}

func TestRunSyncStatusRoundTrip(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	st := newFake()
	var out, errOut bytes.Buffer
	res := RunSync(context.Background(), st, settings(), dir, at(2026, 11, 24, 12), &out, &errOut)
	path := filepath.Join(t.TempDir(), "status")
	if err := WriteStatus(path, res.OK, at(2026, 11, 24, 12), res.Objects); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "newest db ") || !strings.HasPrefix(string(raw), "result ok ") {
		t.Errorf("status = %s", raw)
	}
}
