package main

import (
	"reflect"
	"testing"
	"time"
)

var policy = Retention{Days: 7, Weeks: 4, Months: 3}

func obj(db string, stamp time.Time) RemoteObject {
	name := db + "-" + stamp.Format("20060102-150405") + ".dump.gpg"
	return RemoteObject{Key: ObjectKey("p", db, name), Size: 10, DB: db, Stamp: stamp}
}

func TestPlanUploads(t *testing.T) {
	now := at(2026, 11, 24, 12)
	fresh := LocalFile{Name: "db-20261123-040000.dump.gpg", Path: "/x/a", DB: "db", Stamp: at(2026, 11, 23, 4), Size: 10}
	same := LocalFile{Name: "db-20261122-040000.dump.gpg", Path: "/x/b", DB: "db", Stamp: at(2026, 11, 22, 4), Size: 10}
	resized := LocalFile{Name: "db-20261121-040000.dump.gpg", Path: "/x/c", DB: "db", Stamp: at(2026, 11, 21, 4), Size: 12}
	expired := LocalFile{Name: "db-20261010-040000.dump.gpg", Path: "/x/d", DB: "db", Stamp: at(2026, 10, 10, 4), Size: 10}
	files := []LocalFile{fresh, same, resized, expired}
	remote := map[string]int64{
		ObjectKey("p", "db", same.Name):    10,
		ObjectKey("p", "db", resized.Name): 11, // an interrupted or replaced upload
	}
	k := newKeeper(policy, now, map[string]bool{"db": true}, files, nil)

	uploads, present := PlanUploads(files, remote, "p", true, k)
	var keys []string
	for _, u := range uploads {
		keys = append(keys, u.Key)
	}
	want := []string{ObjectKey("p", "db", fresh.Name), ObjectKey("p", "db", resized.Name)}
	if !reflect.DeepEqual(keys, want) || present != 1 {
		t.Errorf("prune on: uploads %v present %d; want %v present 1", keys, present, want)
	}

	uploads, _ = PlanUploads(files, remote, "p", false, k)
	if len(uploads) != 3 {
		t.Errorf("prune off: %d uploads, want 3 (the expired one too)", len(uploads))
	}
}

func TestPlanPrune(t *testing.T) {
	now := at(2026, 11, 24, 12)
	objects := []RemoteObject{
		obj("db", at(2026, 11, 23, 4)),   // daily
		obj("db", at(2026, 11, 1, 4)),    // a Sunday and the 1st: weekly
		obj("db", at(2026, 11, 10, 4)),   // a Tuesday, age 14: expires
		obj("stale", at(2026, 9, 10, 4)), // a live database's only copy: kept
		obj("stale", at(2026, 9, 9, 4)),  // an older copy of it: expires
		obj("gone", at(2026, 9, 10, 4)),  // a dropped database (not in last/): expires
	}
	live := map[string]bool{"db": true, "stale": true}
	got := PlanPrune(objects, newKeeper(policy, now, live, nil, objects))
	want := []string{
		ObjectKey("p", "db", "db-20261110-040000.dump.gpg"),
		ObjectKey("p", "gone", "gone-20260910-040000.dump.gpg"),
		ObjectKey("p", "stale", "stale-20260909-040000.dump.gpg"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("prune = %v\nwant    %v", got, want)
	}
}

func TestStampedObjects(t *testing.T) {
	list := []ObjectInfo{{Key: "p/db/db-20261001-040000.dump.gpg", Size: 3}, {Key: "p/readme.txt", Size: 1}}
	got := stampedObjects(list)
	if len(got) != 1 || got[0].DB != "db" || got[0].Size != 3 {
		t.Errorf("stampedObjects = %+v", got)
	}
}
