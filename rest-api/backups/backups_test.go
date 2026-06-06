package backups

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveBackupPathOK(t *testing.T) {
	dir := t.TempDir()
	got, err := ResolveBackupPath(dir, "last", "app1-20260606.sql.gz")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "last", "app1-20260606.sql.gz")
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestResolveBackupPathRejectsBadSlot(t *testing.T) {
	if _, err := ResolveBackupPath(t.TempDir(), "etc", "passwd"); err == nil {
		t.Fatal("expected error for invalid slot")
	}
}

func TestResolveBackupPathRejectsTraversal(t *testing.T) {
	for _, name := range []string{"../../etc/passwd", "..", ".", "", "   ", "/", "a/b", "/etc/passwd", "a/../../b"} {
		if _, err := ResolveBackupPath(t.TempDir(), "last", name); err == nil {
			t.Errorf("expected error for name %q", name)
		}
	}
}

func TestListReturnsEntries(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "last"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "last", "app1-1.sql.gz"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := List(dir)
	if len(out) != 1 {
		t.Fatalf("len=%d want 1: %v", len(out), out)
	}
	if out[0].Slot != "last" || out[0].Name != "app1-1.sql.gz" {
		t.Errorf("unexpected entry: %+v", out[0])
	}
}

func TestListEmptyIsNonNilEmpty(t *testing.T) {
	out := List(t.TempDir())
	if out == nil {
		t.Fatal("List must return a non-nil slice")
	}
	if len(out) != 0 {
		t.Errorf("len=%d want 0", len(out))
	}
}
