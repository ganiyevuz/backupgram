package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// WriteStatus writes the sync's status file through a temp file and a rename:
//
//	result <ok|failed> <unix time finished>
//	newest <db> <stamp unix time> <bytes> <key>   (one per database in the bucket)
func WriteStatus(path string, ok bool, finished time.Time, objects []RemoteObject) error {
	result := "failed"
	if ok {
		result = "ok"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "result %s %d\n", result, finished.Unix())
	for _, o := range newestPerDB(objects) {
		fmt.Fprintf(&b, "newest %s %d %d %s\n", o.DB, o.Stamp.Unix(), o.Size, o.Key)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// newestPerDB is each database's newest object, sorted by database.
func newestPerDB(objects []RemoteObject) []RemoteObject {
	byDB := map[string]RemoteObject{}
	for _, o := range objects {
		if cur, ok := byDB[o.DB]; !ok || o.Stamp.After(cur.Stamp) {
			byDB[o.DB] = o
		}
	}
	out := make([]RemoteObject, 0, len(byDB))
	for _, o := range byDB {
		out = append(out, o)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DB < out[j].DB })
	return out
}
