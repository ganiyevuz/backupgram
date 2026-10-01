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
//	newest <db> <stamp unix time> <bytes> <key>   (one per entry of newest; "0 0 -" for an empty Key)
func WriteStatus(path string, ok bool, finished time.Time, newest []RemoteObject) error {
	result := "failed"
	if ok {
		result = "ok"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "result %s %d\n", result, finished.Unix())
	for _, o := range newest {
		if o.Key == "" {
			fmt.Fprintf(&b, "newest %s 0 0 -\n", o.DB)
			continue
		}
		fmt.Fprintf(&b, "newest %s %d %d %s\n", o.DB, o.Stamp.Unix(), o.Size, o.Key)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// NewestLive is, sorted by database, the newest object of each live database (one with a
// stamped dump in local last/), or only its name (an empty Key) when the bucket holds none of
// its dumps. A database that is not live is left out, as the local metrics leave it out.
func NewestLive(live map[string]bool, objects []RemoteObject) []RemoteObject {
	byDB := map[string]RemoteObject{}
	for db := range live {
		byDB[db] = RemoteObject{DB: db}
	}
	for _, o := range objects {
		if cur, ok := byDB[o.DB]; ok && (cur.Key == "" || o.Stamp.After(cur.Stamp)) {
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
