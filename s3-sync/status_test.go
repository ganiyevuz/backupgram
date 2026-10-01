package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestWriteStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status")
	newest := []RemoteObject{
		obj("alpha", at(2026, 11, 23, 4)),
		obj("db", at(2026, 11, 23, 4)),
		{DB: "zeta"}, // live, nothing in the bucket
	}
	if err := WriteStatus(path, true, at(2026, 11, 23, 5), 3, newest); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "result ok 1795410000\n" +
		"databases 3\n" +
		"newest alpha 1795406400 10 p/alpha/alpha-20261123-040000.dump.gpg\n" +
		"newest db 1795406400 10 p/db/db-20261123-040000.dump.gpg\n" +
		"newest zeta 0 0 -\n"
	if string(raw) != want {
		t.Errorf("status =\n%s\nwant\n%s", raw, want)
	}
	if err := WriteStatus(path, false, at(2026, 11, 23, 5), 0, nil); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(path)
	if string(raw) != "result failed 1795410000\ndatabases 0\n" {
		t.Errorf("failed status = %q", raw)
	}
	if err := WriteStatus(path, false, at(2026, 11, 23, 5), -1, nil); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(path)
	if string(raw) != "result failed 1795410000\n" {
		t.Errorf("status with an unknown count = %q, want no databases line", raw)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temp file left behind: %v", err)
	}
}

func TestNewestLive(t *testing.T) {
	objects := []RemoteObject{
		obj("db", at(2026, 11, 22, 4)),
		obj("db", at(2026, 11, 23, 4)),
		obj("db", at(2026, 11, 21, 4)),
		obj("gone", at(2026, 11, 23, 4)), // in the bucket, not live: no line
	}
	got := NewestLive(map[string]bool{"db": true, "alpha": true}, objects)
	want := []RemoteObject{{DB: "alpha"}, obj("db", at(2026, 11, 23, 4))}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("newest = %+v, want %+v", got, want)
	}
	if got := NewestLive(nil, objects); len(got) != 0 {
		t.Errorf("no live database: %+v", got)
	}
}
