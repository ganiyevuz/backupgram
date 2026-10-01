package main

import (
	"sort"
	"time"
)

// RemoteObject is a stamped dump in the bucket.
type RemoteObject struct {
	Key   string
	Size  int64
	DB    string
	Stamp time.Time
}

// Upload is a local dump to put at Key.
type Upload struct {
	File LocalFile
	Key  string
}

// stampedObjects keeps the listed objects whose names are stamped dumps at the correct key path:
// <prefix>/<db>/<name> (where name parses as stamped). Objects at wrong paths are excluded.
func stampedObjects(prefix string, list []ObjectInfo) []RemoteObject {
	var out []RemoteObject
	for _, o := range list {
		if db, stamp, ok := ParseStamped(baseName(o.Key)); ok {
			if o.Key == ObjectKey(prefix, db, baseName(o.Key)) {
				out = append(out, RemoteObject{Key: o.Key, Size: o.Size, DB: db, Stamp: stamp})
			}
		}
	}
	return out
}

// keeper decides what stays in the bucket: the retention tiers, plus the newest dump of
// every live database (one that still has a stamped file in local last/).
type keeper struct {
	r      Retention
	now    time.Time
	live   map[string]bool
	newest map[string]time.Time
}

// newKeeper builds a keeper whose "newest" per database spans the given local files and
// remote objects.
func newKeeper(r Retention, now time.Time, live map[string]bool, files []LocalFile, objects []RemoteObject) keeper {
	newest := map[string]time.Time{}
	note := func(db string, stamp time.Time) {
		if cur, ok := newest[db]; !ok || stamp.After(cur) {
			newest[db] = stamp
		}
	}
	for _, f := range files {
		note(f.DB, f.Stamp)
	}
	for _, o := range objects {
		note(o.DB, o.Stamp)
	}
	return keeper{r: r, now: now, live: live, newest: newest}
}

func (k keeper) keeps(db string, stamp time.Time) bool {
	if ok, _ := k.r.Keep(stamp, k.now); ok {
		return true
	}
	return k.live[db] && !stamp.Before(k.newest[db])
}

// PlanUploads returns the local dumps whose key is missing from the bucket or holds a
// different size, and how many are already there. With pruning on, a dump the policy
// would delete straight away is not uploaded.
func PlanUploads(files []LocalFile, remote map[string]int64, prefix string, prune bool, k keeper) ([]Upload, int) {
	var uploads []Upload
	present := 0
	for _, f := range files {
		key := ObjectKey(prefix, f.DB, f.Name)
		if size, ok := remote[key]; ok && size == f.Size {
			present++
			continue
		}
		if prune && !k.keeps(f.DB, f.Stamp) {
			continue
		}
		uploads = append(uploads, Upload{File: f, Key: key})
	}
	return uploads, present
}

// PlanPrune returns, sorted, the keys of stamped objects the policy no longer keeps.
func PlanPrune(objects []RemoteObject, k keeper) []string {
	var keys []string
	for _, o := range objects {
		if !k.keeps(o.DB, o.Stamp) {
			keys = append(keys, o.Key)
		}
	}
	sort.Strings(keys)
	return keys
}
