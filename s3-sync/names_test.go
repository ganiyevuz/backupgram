package main

import "testing"

func TestParseStamped(t *testing.T) {
	cases := []struct {
		name string
		db   string
		ok   bool
	}{
		{"db-20261001-040000.dump.gpg", "db", true},
		{"pharmacy_alpha-20261001-040001.dump.gpg", "pharmacy_alpha", true},
		{"keep-20260101-20261001-040000.sql.gz", "keep-20260101", true},
		{"cluster-20261001-040000.sql.gz.gpg", "cluster", true},
		{"db-latest.dump.gpg", "", false},
		{"db-20261301-040000.dump.gpg", "", false},
		{"db-20261001-040000", "", false},
		{"notes.txt", "", false},
	}
	for _, c := range cases {
		db, stamp, ok := ParseStamped(c.name)
		if ok != c.ok || db != c.db {
			t.Errorf("ParseStamped(%q) = %q, %v; want %q, %v", c.name, db, ok, c.db, c.ok)
		}
		if ok && c.name == "db-20261001-040000.dump.gpg" && !stamp.Equal(at(2026, 10, 1, 4)) {
			t.Errorf("stamp = %v, want 2026-10-01 04:00", stamp)
		}
	}
}

func TestObjectKey(t *testing.T) {
	cases := map[string]string{
		"":              "db/db-20261001-040000.dump.gpg",
		"platform-test": "platform-test/db/db-20261001-040000.dump.gpg",
		"/a/b/":         "a/b/db/db-20261001-040000.dump.gpg",
	}
	for prefix, want := range cases {
		if got := ObjectKey(prefix, "db", "db-20261001-040000.dump.gpg"); got != want {
			t.Errorf("ObjectKey(%q) = %q, want %q", prefix, got, want)
		}
	}
	if got := ListPrefix("/a/b/"); got != "a/b/" {
		t.Errorf("ListPrefix = %q, want a/b/", got)
	}
	if got := ListPrefix(""); got != "" {
		t.Errorf("ListPrefix(\"\") = %q, want empty", got)
	}
	if got := baseName("a/b/db-1.dump"); got != "db-1.dump" {
		t.Errorf("baseName = %q", got)
	}
}

func TestHumanSize(t *testing.T) {
	cases := map[int64]string{512: "512", 2048: "2.0K", 5 * 1024 * 1024: "5.0M", 3 << 30: "3.0G"}
	for n, want := range cases {
		if got := humanSize(n); got != want {
			t.Errorf("humanSize(%d) = %q, want %q", n, got, want)
		}
	}
}
