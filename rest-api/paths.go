package main

import (
	"path/filepath"
	"strings"
)

var validSlots = map[string]bool{"last": true, "daily": true, "weekly": true, "monthly": true}

// resolveBackupPath returns a safe absolute path inside backupDir/slot, or an
// error. It whitelists the slot, reduces name with filepath.Base, and verifies
// the result stays within the slot directory (defense against traversal).
func resolveBackupPath(backupDir, slot, name string) (string, error) {
	if !validSlots[slot] {
		return "", &apiError{Status: 404, Msg: "unknown slot: " + slot}
	}
	base := filepath.Base(name)
	if base != name || base == "." || base == ".." || base == "/" || strings.TrimSpace(base) == "" {
		return "", &apiError{Status: 400, Msg: "invalid backup name"}
	}
	slotDir := filepath.Join(backupDir, slot)
	full := filepath.Join(slotDir, base)
	if !strings.HasPrefix(full, slotDir+string(filepath.Separator)) {
		return "", &apiError{Status: 400, Msg: "invalid backup path"}
	}
	return full, nil
}
