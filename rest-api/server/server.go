package server

import (
	"crypto/subtle"
	"net/http"

	"backupgram/handlers"
	"backupgram/httpx"
)

func authMiddleware(token string, next http.Handler) http.Handler {
	if token == "" {
		panic("authMiddleware: token must not be empty")
	}
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			httpx.WriteError(w, &httpx.Error{Status: 401, Msg: "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Options selects the route groups the router serves.
type Options struct {
	Token   string // bearer token for the REST routes; required when REST is true
	REST    bool   // REST_API_ENABLE: the protected control routes
	Metrics bool   // METRICS_ENABLE: GET /metrics, open like /healthz
}

// Router wires the HTTP routes. /healthz is always open; /metrics is open when
// enabled; the REST routes require the token and exist only when REST is on.
func Router(opts Options, h *handlers.Handlers) http.Handler {
	root := http.NewServeMux()
	root.HandleFunc("GET /healthz", h.Healthz)
	if opts.Metrics {
		root.HandleFunc("GET /metrics", h.Metrics)
	}
	if opts.REST {
		protected := http.NewServeMux()
		protected.HandleFunc("GET /status", h.Status)
		protected.HandleFunc("GET /backups", h.ListBackups)
		protected.HandleFunc("GET /backups/{slot}/{name}", h.Download)
		protected.HandleFunc("DELETE /backups/{slot}/{name}", h.Delete)
		protected.HandleFunc("POST /backup", h.Backup)
		protected.HandleFunc("POST /restore", h.Restore)
		protected.HandleFunc("GET /jobs", h.ListJobs)
		protected.HandleFunc("GET /jobs/{id}", h.GetJob)
		protected.HandleFunc("GET /config", h.GetConfig)
		protected.HandleFunc("PATCH /config", h.PatchConfig)
		protected.HandleFunc("DELETE /config/{key}", h.DeleteConfig)
		root.Handle("/", authMiddleware(opts.Token, protected))
	}
	return root
}
