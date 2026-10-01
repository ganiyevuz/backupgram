package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A backup folder with every kind of entry the uploader meets.
func sampleDir(t *testing.T) string {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "last", "db-20261001-040000.dump.gpg"), 10)
	writeFile(t, filepath.Join(dir, "last", ".db-20261001-050000.dump.gpg.part"), 5)
	writeFile(t, filepath.Join(dir, "last", "plain-20261001-040000.sql.gz"), 7)
	if err := os.MkdirAll(filepath.Join(dir, "last", "dirdb-20261001-040000.dump"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("db-20261001-040000.dump.gpg", filepath.Join(dir, "last", "db-latest.dump.gpg")); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "daily", "db-20261001-040000.dump.gpg"), 10)
	writeFile(t, filepath.Join(dir, "daily", "old-20260901-040000.dump.gpg"), 3)
	writeFile(t, filepath.Join(dir, "daily", "notes.txt"), 1)
	return dir
}

func names(files []LocalFile) []string {
	var out []string
	for _, f := range files {
		out = append(out, f.Name)
	}
	return out
}

func TestEligible(t *testing.T) {
	dir := sampleDir(t)
	files, warnings, err := Eligible(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"db-20261001-040000.dump.gpg", "old-20260901-040000.dump.gpg"}
	if got := names(files); !reflect.DeepEqual(got, want) {
		t.Errorf("eligible = %v, want %v", got, want)
	}
	joined := strings.Join(warnings, "\n")
	for _, w := range []string{
		"⚠️ dirdb-20261001-040000.dump: directory dumps are not uploaded.",
		"⚠️ plain-20261001-040000.sql.gz: not encrypted; not uploaded (S3_ALLOW_UNENCRYPTED=FALSE).",
	} {
		if !strings.Contains(joined, w) {
			t.Errorf("warnings lack %q:\n%s", w, joined)
		}
	}
	if strings.Contains(joined, ".part") {
		t.Errorf("a .part file was considered: %s", joined)
	}
	files, _, _ = Eligible(dir, true)
	if got := names(files); !reflect.DeepEqual(got, []string{"db-20261001-040000.dump.gpg", "old-20260901-040000.dump.gpg", "plain-20261001-040000.sql.gz"}) {
		t.Errorf("with unencrypted allowed: %v", got)
	}
	if files[0].DB != "db" || files[0].Size != 10 || !files[0].Stamp.Equal(at(2026, 10, 1, 4)) {
		t.Errorf("first file = %+v", files[0])
	}
}

func TestEligibleMissingFolders(t *testing.T) {
	files, warnings, err := Eligible(t.TempDir(), false)
	if err != nil || len(files) != 0 || len(warnings) != 0 {
		t.Errorf("empty dir: %v %v %v", files, warnings, err)
	}
}

func TestLiveDatabases(t *testing.T) {
	live, err := LiveDatabases(sampleDir(t))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"db": true, "plain": true, "dirdb": true}
	if !reflect.DeepEqual(live, want) {
		t.Errorf("live = %v, want %v", live, want)
	}
}
