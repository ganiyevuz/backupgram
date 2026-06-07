package handlers

import (
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"backupgram/backups"
	"backupgram/httpx"
)

func (h *Handlers) Backup(w http.ResponseWriter, r *http.Request) {
	j := h.Jobs.Submit("backup", "/backup.sh", nil)
	httpx.WriteJSON(w, 202, map[string]string{"job_id": j.ID})
}

type restoreRequest struct {
	File              string `json:"file"`
	TelegramMessageID int64  `json:"telegram_message_id"`
	TargetDB          string `json:"target_db"`
	Confirm           bool   `json:"confirm"`
}

// targetDBPattern is a strict PostgreSQL unquoted-identifier rule. It rejects a
// leading '-' (flag smuggling) and any shell/argv-significant characters.
var targetDBPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,62}$`)

func (h *Handlers) Restore(w http.ResponseWriter, r *http.Request) {
	var req restoreRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if !req.Confirm {
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: `restore requires "confirm": true`})
		return
	}
	if req.TargetDB == "" {
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "restore requires target_db"})
		return
	}
	if !targetDBPattern.MatchString(req.TargetDB) {
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "invalid target_db: must match ^[A-Za-z_][A-Za-z0-9_]{0,62}$"})
		return
	}
	hasFile := req.File != ""
	hasTG := req.TelegramMessageID > 0
	if hasFile == hasTG { // both or neither
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "provide exactly one of file or telegram_message_id"})
		return
	}
	var args []string
	if hasFile {
		slot, name, ok := splitSlotName(req.File)
		if !ok {
			httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "file must be in the form slot/name"})
			return
		}
		full, err := backups.ResolveBackupPath(h.BackupDir, slot, name)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		args = []string{full, req.TargetDB}
	} else {
		args = []string{"--from-telegram", strconv.FormatInt(req.TelegramMessageID, 10), req.TargetDB}
	}
	j := h.Jobs.Submit("restore", "/restore.sh", args)
	httpx.WriteJSON(w, 202, map[string]string{"job_id": j.ID})
}

func (h *Handlers) ListJobs(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, 200, map[string]any{"jobs": h.Jobs.List()})
}

func (h *Handlers) GetJob(w http.ResponseWriter, r *http.Request) {
	j, ok := h.Jobs.Get(r.PathValue("id"))
	if !ok {
		httpx.WriteError(w, &httpx.Error{Status: 404, Msg: "job not found"})
		return
	}
	httpx.WriteJSON(w, 200, j)
}

// splitSlotName parses "slot/name" into its two non-empty parts.
func splitSlotName(p string) (slot, name string, ok bool) {
	parts := strings.SplitN(p, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}
