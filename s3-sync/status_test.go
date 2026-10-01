package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status")
	objects := []RemoteObject{
		obj("db", at(2026, 11, 22, 4)),
		obj("db", at(2026, 11, 23, 4)),
		obj("alpha", at(2026, 11, 23, 4)),
	}
	if err := WriteStatus(path, true, at(2026, 11, 23, 5), objects); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "result ok 1795410000\n" +
		"newest alpha 1795406400 10 p/alpha/alpha-20261123-040000.dump.gpg\n" +
		"newest db 1795406400 10 p/db/db-20261123-040000.dump.gpg\n"
	if string(raw) != want {
		t.Errorf("status =\n%s\nwant\n%s", raw, want)
	}
	if err := WriteStatus(path, false, at(2026, 11, 23, 5), nil); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(path)
	if string(raw) != "result failed 1795410000\n" {
		t.Errorf("failed status = %q", raw)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temp file left behind: %v", err)
	}
}
