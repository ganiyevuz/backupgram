package handlers

import (
	"mime"
	"net/http"
	"os"

	"backupgram/backups"
	"backupgram/httpx"
)

func (h *Handlers) Download(w http.ResponseWriter, r *http.Request) {
	full, err := backups.ResolveBackupPath(h.BackupDir, r.PathValue("slot"), r.PathValue("name"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	f, err := os.Open(full)
	if err != nil {
		httpx.WriteError(w, &httpx.Error{Status: 404, Msg: "backup not found"})
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		httpx.WriteError(w, &httpx.Error{Status: 404, Msg: "backup not found"})
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	if cd := mime.FormatMediaType("attachment", map[string]string{"filename": r.PathValue("name")}); cd != "" {
		w.Header().Set("Content-Disposition", cd)
	}
	http.ServeContent(w, r, r.PathValue("name"), fi.ModTime(), f)
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("confirm") != "true" {
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "destructive op requires ?confirm=true"})
		return
	}
	full, err := backups.ResolveBackupPath(h.BackupDir, r.PathValue("slot"), r.PathValue("name"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	if err := os.Remove(full); err != nil {
		if os.IsNotExist(err) {
			httpx.WriteError(w, &httpx.Error{Status: 404, Msg: "backup not found"})
		} else {
			httpx.WriteError(w, &httpx.Error{Status: 500, Msg: "failed to delete backup"})
		}
		return
	}
	httpx.WriteJSON(w, 200, map[string]string{"deleted": r.PathValue("name")})
}
