package handlers

import (
	"net/http"

	"pgbackupapi/config"
	"pgbackupapi/httpx"
)

func (h *Handlers) GetConfig(w http.ResponseWriter, r *http.Request) {
	cfg, err := config.Effective()
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"config": cfg})
}

func (h *Handlers) PatchConfig(w http.ResponseWriter, r *http.Request) {
	var patch map[string]string
	if err := httpx.DecodeJSON(r, &patch); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if len(patch) == 0 {
		httpx.WriteError(w, &httpx.Error{Status: 400, Msg: "empty patch"})
		return
	}
	scheduleChanged, err := config.ApplyPatch(patch) // validates (403/400) before writing
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	if scheduleChanged && h.RestartSchedule != nil {
		if err := h.RestartSchedule(patch[config.ScheduleKey]); err != nil {
			httpx.WriteError(w, &httpx.Error{Status: 500, Msg: "config saved but scheduler restart failed: " + err.Error()})
			return
		}
	}
	cfg, _ := config.Effective()
	httpx.WriteJSON(w, 200, map[string]any{"config": cfg})
}

func (h *Handlers) DeleteConfig(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	existed, err := config.ClearOverride(key)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	if !existed {
		httpx.WriteError(w, &httpx.Error{Status: 404, Msg: "no override set for " + key})
		return
	}
	if key == config.ScheduleKey && h.RestartSchedule != nil {
		if err := h.RestartSchedule(getenvOr("SCHEDULE", "@daily")); err != nil {
			httpx.WriteError(w, &httpx.Error{Status: 500, Msg: "override cleared but scheduler restart failed: " + err.Error()})
			return
		}
	}
	httpx.WriteJSON(w, 200, map[string]string{"cleared": key})
}
