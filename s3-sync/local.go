package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// LocalFile is a stamped dump in the backup folder.
type LocalFile struct {
	Name, Path, DB string
	Stamp          time.Time
	Size           int64
}

// Eligible lists the stamped dumps in last/ and daily/ that may go off-site, once per
// name. Dot files (an in-flight .part) and unstamped names (-latest links included) are
// skipped silently; directory dumps, and files without .gpg unless allowUnencrypted, are
// skipped with a warning.
func Eligible(dir string, allowUnencrypted bool) ([]LocalFile, []string, error) {
	var files []LocalFile
	var warnings []string
	seen := map[string]bool{}
	for _, slot := range []string{"last", "daily"} {
		entries, err := os.ReadDir(filepath.Join(dir, slot))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, nil, err
		}
		for _, e := range entries {
			name := e.Name()
			if strings.HasPrefix(name, ".") || seen[name] {
				continue
			}
			db, stamp, ok := ParseStamped(name)
			if !ok {
				continue
			}
			seen[name] = true
			path := filepath.Join(dir, slot, name)
			info, err := os.Stat(path)
			if err != nil {
				return nil, nil, err
			}
			switch {
			case info.IsDir():
				warnings = append(warnings, fmt.Sprintf("⚠️ %s: directory dumps are not uploaded.", name))
			case !info.Mode().IsRegular():
			case !strings.HasSuffix(name, ".gpg") && !allowUnencrypted:
				warnings = append(warnings, fmt.Sprintf("⚠️ %s: not encrypted; not uploaded (S3_ALLOW_UNENCRYPTED=FALSE).", name))
			default:
				files = append(files, LocalFile{Name: name, Path: path, DB: db, Stamp: stamp, Size: info.Size()})
			}
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	return files, warnings, nil
}

// LiveDatabases names the databases with a stamped entry in last/ — the backup keeps only
// existing databases there — whose newest off-site dump is never pruned.
func LiveDatabases(dir string) (map[string]bool, error) {
	live := map[string]bool{}
	entries, err := os.ReadDir(filepath.Join(dir, "last"))
	if errors.Is(err, fs.ErrNotExist) {
		return live, nil
	}
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if db, _, ok := ParseStamped(e.Name()); ok {
			live[db] = true
		}
	}
	return live, nil
}
