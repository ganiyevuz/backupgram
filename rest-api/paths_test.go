package main

import (
	"path/filepath"
	"testing"
)

func TestResolveBackupPathOK(t *testing.T) {
	dir := t.TempDir()
	got, err := resolveBackupPath(dir, "last", "app1-20260606.sql.gz")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "last", "app1-20260606.sql.gz")
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestResolveBackupPathRejectsBadSlot(t *testing.T) {
	if _, err := resolveBackupPath(t.TempDir(), "etc", "passwd"); err == nil {
		t.Fatal("expected error for invalid slot")
	}
}

func TestResolveBackupPathRejectsTraversal(t *testing.T) {
	for _, name := range []string{"../../etc/passwd", "..", ".", "", "   ", "/", "a/b", "/etc/passwd", "a/../../b"} {
		if _, err := resolveBackupPath(t.TempDir(), "last", name); err == nil {
			t.Errorf("expected error for name %q", name)
		}
	}
}
