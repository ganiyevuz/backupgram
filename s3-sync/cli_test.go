package main

import (
	"bytes"
	"context"
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
	st.putErr["p/db/db-20261124-040000.dump.gpg"] = context.DeadlineExceeded
	writeFile(t, filepath.Join(dir, "last", "db-20261124-040000.dump.gpg"), 10)
	if code, _, _ := runWith(t, st, env, "sync", "--dir", dir); code != 1 {
		t.Errorf("a failed upload: exit %d, want 1", code)
	}
}

func TestRunListGetLatest(t *testing.T) {
	st := newFake()
	st.objects["p/db/db-20261123-040000.dump.gpg"] = []byte("newest")
	st.objects["p/db/db-20261001-040000.dump.gpg"] = []byte("old")
	st.objects["p/other/other-20261110-040000.dump.gpg"] = []byte("x")
	st.objects["p/readme.txt"] = []byte("r")
	env := baseEnv()
	env["S3_PREFIX"] = "p"

	code, out, _ := runWith(t, st, env, "ls")
	want := "p/db/db-20261001-040000.dump.gpg\t3\t3\t2026-10-01 04:00:00\tmonthly\n" +
		"p/db/db-20261123-040000.dump.gpg\t6\t6\t2026-11-23 04:00:00\tdaily\n" +
		"p/other/other-20261110-040000.dump.gpg\t1\t1\t2026-11-10 04:00:00\texpires\n" +
		"p/readme.txt\t1\t1\t-\t-\n"
	if code != 0 || out != want {
		t.Errorf("ls: exit %d\n%s\nwant\n%s", code, out, want)
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
