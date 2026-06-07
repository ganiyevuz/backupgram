package backups

import (
	"os"
	"path/filepath"
	"strings"

	"backupgram/httpx"
)

var ValidSlots = map[string]bool{"last": true, "daily": true, "weekly": true, "monthly": true}

// ResolveBackupPath returns a safe absolute path inside backupDir/slot, or an
// error. It whitelists the slot, reduces name with filepath.Base, and verifies
// the result stays within the slot directory (defense against traversal).
func ResolveBackupPath(backupDir, slot, name string) (string, error) {
	if !ValidSlots[slot] {
		return "", &httpx.Error{Status: 404, Msg: "unknown slot: " + slot}
	}
	base := filepath.Base(name)
	if base != name || base == "." || base == ".." || base == "/" || strings.TrimSpace(base) == "" {
		return "", &httpx.Error{Status: 400, Msg: "invalid backup name"}
	}
	slotDir := filepath.Join(backupDir, slot)
	full := filepath.Join(slotDir, base)
	if !strings.HasPrefix(full, slotDir+string(filepath.Separator)) {
		return "", &httpx.Error{Status: 400, Msg: "invalid backup path"}
	}
	return full, nil
}

type Entry struct {
	Slot  string `json:"slot"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
}

// List returns all backup files across the valid slots (empty slice, never nil).
func List(backupDir string) []Entry {
	out := []Entry{}
	for slot := range ValidSlots {
		items, err := os.ReadDir(filepath.Join(backupDir, slot))
		if err != nil {
			continue
		}
		for _, it := range items {
			if it.IsDir() {
				continue
			}
			info, err := it.Info()
			if err != nil {
				continue
			}
			out = append(out, Entry{slot, it.Name(), info.Size(), info.ModTime().Unix()})
		}
	}
	return out
}
