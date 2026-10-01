package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func runWith(t *testing.T, st *fakeStorage, env map[string]string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	open := func(Env) (Storage, error) { return st, nil }
	now := func() time.Time { return at(2026, 11, 24, 12) }
	code := run(context.Background(), args, envOf(env), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestRunUsage(t *testing.T) {
	if code, _, _ := runWith(t, newFake(), baseEnv()); code != 2 {
		t.Errorf("no command: exit %d, want 2", code)
	}
	if code, _, _ := runWith(t, newFake(), baseEnv(), "frobnicate"); code != 2 {
		t.Errorf("unknown command: exit %d, want 2", code)
	}
	if code, _, errOut := runWith(t, newFake(), map[string]string{}, "ls"); code != 2 || !strings.Contains(errOut, "S3_BUCKET") {
		t.Errorf("missing settings: exit %d, stderr %q", code, errOut)
	}
	if code, _, _ := runWith(t, newFake(), baseEnv(), "sync"); code != 2 {
		t.Errorf("sync without --dir: exit %d, want 2", code)
	}
}

func TestRunSyncCommand(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	status := filepath.Join(t.TempDir(), "status")
	st := newFake()
	env := baseEnv()
	env["S3_PREFIX"] = "p"
	code, out, _ := runWith(t, st, env, "sync", "--dir", dir, "--status", status)
	if code != 0 || !strings.Contains(out, "1 uploaded") {
		t.Fatalf("sync: exit %d out %s", code, out)
	}
	raw, err := os.ReadFile(status)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), "result ok ") || !strings.Contains(string(raw), "\nnewest db ") {
		t.Errorf("status after a good sync = %q", raw)
	}

	st.putErr["p/db/db-20261124-040000.dump.gpg"] = context.DeadlineExceeded
	writeFile(t, filepath.Join(dir, "last", "db-20261124-040000.dump.gpg"), 10)
	if code, _, _ := runWith(t, st, env, "sync", "--dir", dir, "--status", status); code != 1 {
		t.Errorf("a failed upload: exit %d, want 1", code)
	}
	raw, err = os.ReadFile(status)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), "result failed ") {
		t.Errorf("status after a failed sync = %q", raw)
	}
}

// A stalled endpoint must not hold the backup's lock: the sync stops at S3_SYNC_TIMEOUT and
// reads as failed.
func TestRunSyncStopsAtTheTimeLimit(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261123-040000.dump.gpg"), 10)
	status := filepath.Join(t.TempDir(), "status")
	st := newFake()
	st.listHook = func(ctx context.Context, _ int) error { // a server that never answers
		<-ctx.Done()
		return ctx.Err()
	}
	env := baseEnv()
	env["S3_SYNC_TIMEOUT"] = "1"
	start := time.Now()
	code, _, errOut := runWith(t, st, env, "sync", "--dir", dir, "--status", status)
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("the sync took %v with S3_SYNC_TIMEOUT=1", elapsed)
	}
	if code != 1 {
		t.Errorf("a sync stopped by the time limit: exit %d, want 1", code)
	}
	if !strings.Contains(errOut, "⚠️ off-site: the sync stopped after 1s (S3_SYNC_TIMEOUT). It will be retried on the next run.") {
		t.Errorf("stderr = %s", errOut)
	}
	raw, err := os.ReadFile(status)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), "result failed ") {
		t.Errorf("status after a stopped sync = %q", raw)
	}
}

func TestRunListGetLatest(t *testing.T) {
	st := newFake()
	st.objects["p/db/db-20261123-040000.dump.gpg"] = []byte("newest")
	st.objects["p/db/db-20261001-040000.dump.gpg"] = []byte("old")
	st.objects["p/other/other-20261110-040000.dump.gpg"] = []byte("x")
	st.objects["p/readme.txt"] = []byte("r")
	// Stamped names outside <prefix>/<db>/<name> are not this deployment's dumps.
	st.objects["p/db/sub/db-20261124-040000.dump.gpg"] = []byte("deep")   // newer than every real db dump
	st.objects["p/wrongdb/db-20261122-040000.dump.gpg"] = []byte("wrong") // name says db, folder says wrongdb
	env := baseEnv()
	env["S3_PREFIX"] = "p"

	code, out, _ := runWith(t, st, env, "ls")
	want := "p/db/db-20261001-040000.dump.gpg\t3\t3\t2026-10-01 04:00:00\tmonthly\n" +
		"p/db/db-20261123-040000.dump.gpg\t6\t6\t2026-11-23 04:00:00\tdaily\n" +
		"p/db/sub/db-20261124-040000.dump.gpg\t4\t4\t-\t-\n" +
		"p/other/other-20261110-040000.dump.gpg\t1\t1\t2026-11-10 04:00:00\texpires\n" +
		"p/readme.txt\t1\t1\t-\t-\n" +
		"p/wrongdb/db-20261122-040000.dump.gpg\t5\t5\t-\t-\n"
	if code != 0 || out != want {
		t.Errorf("ls: exit %d\n%s\nwant\n%s", code, out, want)
	}
	wantDB := "p/db/db-20261001-040000.dump.gpg\t3\t3\t2026-10-01 04:00:00\tmonthly\n" +
		"p/db/db-20261123-040000.dump.gpg\t6\t6\t2026-11-23 04:00:00\tdaily\n"
	if _, out, _ := runWith(t, st, env, "ls", "--db", "db"); out != wantDB {
		t.Errorf("ls --db db = %q, want %q", out, wantDB)
	}
	if _, out, _ := runWith(t, st, env, "ls", "--db", "other"); out != "p/other/other-20261110-040000.dump.gpg\t1\t1\t2026-11-10 04:00:00\texpires\n" {
		t.Errorf("ls --db other = %q", out)
	}
	if code, out, _ := runWith(t, st, env, "get", "p/db/db-20261123-040000.dump.gpg"); code != 0 || out != "newest" {
		t.Errorf("get: exit %d out %q", code, out)
	}
	if code, _, errOut := runWith(t, st, env, "get", "p/db/missing.dump.gpg"); code != 1 || !strings.Contains(errOut, "cannot read p/db/missing.dump.gpg") {
		t.Errorf("get missing: exit %d stderr %q", code, errOut)
	}
	if code, out, _ := runWith(t, st, env, "latest", "db"); code != 0 || out != "p/db/db-20261123-040000.dump.gpg\n" {
		t.Errorf("latest: exit %d out %q", code, out)
	}
	if code, out, _ := runWith(t, st, env, "latest", "nosuch"); code != 1 || out != "" {
		t.Errorf("latest of nothing: exit %d out %q", code, out)
	}
}
