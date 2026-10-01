package main

import (
	"context"
	"fmt"
	"io"
	"sort"
	"time"
)

// Settings is what a sync needs besides the storage.
type Settings struct {
	Location         string // s3://bucket[/prefix], for messages
	Prefix           string
	Retention        Retention
	Prune            bool
	AllowUnencrypted bool
}

// Result counts one sync's work. OK is false when an eligible upload failed, the bucket
// could not be listed or last/ could not be read. Databases is the number of live databases
// (see LiveDatabases), -1 when last/ was not read. Objects is the bucket's stamped dumps
// after the sync, and Newest what the status file reports (see NewestLive); both are nil
// when the bucket could not be listed after the sync.
type Result struct {
	Uploaded, Present, Failed, Pruned int
	OK                                bool
	Databases                         int
	Objects                           []RemoteObject
	Newest                            []RemoteObject
}

// RunSync uploads the dumps of dir the bucket lacks, prunes the bucket, and lists it
// again for the status file.
func RunSync(ctx context.Context, st Storage, s Settings, dir string, now time.Time, out, errOut io.Writer) Result {
	res := Result{OK: true, Databases: -1}
	files, warnings, err := Eligible(dir, s.AllowUnencrypted)
	if err != nil {
		fmt.Fprintf(errOut, "⚠️ off-site: cannot read %s (%v).\n", dir, err)
		res.OK = false
		return res
	}
	for _, w := range warnings {
		fmt.Fprintln(errOut, w)
	}
	prune := s.Prune
	live, err := LiveDatabases(dir)
	if err == nil {
		res.Databases = len(live)
	}
	switch {
	case err != nil:
		fmt.Fprintf(errOut, "⚠️ off-site: cannot read %s/last (%v); nothing pruned.\n", dir, err)
		prune = false
		res.OK = false
	case prune && len(live) == 0:
		// An empty or wrong folder is never "every database was dropped": on a new server
		// that is restoring, pruning would delete the very copies being restored.
		fmt.Fprintf(errOut, "⚠️ off-site prune skipped: no dump in %s/last (a new or wrong folder?). Nothing deleted.\n", dir)
		prune = false
	case len(live) == 0:
		// Not a failure (a new deployment before its first dump); backupgram_offsite_databases
		// reads 0 and its alert catches a wrong folder.
		fmt.Fprintf(errOut, "⚠️ off-site: no dump in %s/last (a new or wrong folder?).\n", dir)
	}
	listing, err := st.List(ctx, ListPrefix(s.Prefix))
	if err != nil {
		fmt.Fprintf(errOut, "⚠️ off-site: cannot list %s (%v). It will be retried on the next run.\n", s.Location, err)
		res.OK = false
		return res
	}
	remote := map[string]int64{}
	for _, o := range listing {
		remote[o.Key] = o.Size
	}

	uploads, present := PlanUploads(files, remote, s.Prefix, prune, newKeeper(s.Retention, now, live, files, stampedObjects(s.Prefix, listing)))
	res.Present = present
	for _, u := range uploads {
		if err := putVerified(ctx, st, u); err != nil {
			fmt.Fprintf(errOut, "⚠️ %s: off-site upload failed (%v). It will be retried on the next run.\n", u.File.DB, err)
			res.Failed++
			res.OK = false
			continue
		}
		fmt.Fprintf(out, "☁️ %s: uploaded %s (%s)\n", u.File.DB, u.Key, humanSize(u.File.Size))
		res.Uploaded++
		remote[u.Key] = u.File.Size
	}

	if prune {
		current := stampedObjects(s.Prefix, infos(remote))
		for _, key := range PlanPrune(current, newKeeper(s.Retention, now, live, nil, current)) {
			if err := st.Remove(ctx, key); err != nil {
				fmt.Fprintf(errOut, "⚠️ off-site prune: could not delete %s (%v).\n", key, err)
				continue
			}
			fmt.Fprintf(out, "🗑️ off-site: removed %s\n", key)
			res.Pruned++
		}
	}

	if final, err := st.List(ctx, ListPrefix(s.Prefix)); err != nil {
		fmt.Fprintf(errOut, "⚠️ off-site: cannot list %s after the sync (%v).\n", s.Location, err)
		res.OK = false
	} else {
		res.Objects = stampedObjects(s.Prefix, final)
		res.Newest = NewestLive(live, res.Objects)
	}
	fmt.Fprintf(out, "☁️ Off-site %s: %d uploaded, %d already there, %d failed, %d pruned.\n",
		s.Location, res.Uploaded, res.Present, res.Failed, res.Pruned)
	return res
}

// putVerified uploads one dump and checks the bucket holds its full size.
func putVerified(ctx context.Context, st Storage, u Upload) error {
	if err := st.Put(ctx, u.Key, u.File.Path, u.File.Size); err != nil {
		return err
	}
	size, err := st.Stat(ctx, u.Key)
	if err != nil {
		return fmt.Errorf("size check: %w", err)
	}
	if size != u.File.Size {
		return fmt.Errorf("size check: bucket has %d bytes, local file %d", size, u.File.Size)
	}
	return nil
}

// infos turns the key→size map back into a sorted listing.
func infos(remote map[string]int64) []ObjectInfo {
	out := make([]ObjectInfo, 0, len(remote))
	for k, v := range remote {
		out = append(out, ObjectInfo{Key: k, Size: v})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out
}
