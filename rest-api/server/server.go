package server

import (
	"crypto/subtle"
	"net/http"

	"pgbackupapi/handlers"
	"pgbackupapi/httpx"
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

// Router wires the HTTP routes. /healthz is open; all else requires the token.
// NOTE: file, job, and config routes are registered by later tasks.
func Router(token string, h *handlers.Handlers) http.Handler {
	protected := http.NewServeMux()
	protected.HandleFunc("GET /status", h.Status)
	protected.HandleFunc("GET /backups", h.ListBackups)

	root := http.NewServeMux()
	root.HandleFunc("GET /healthz", h.Healthz)
	root.Handle("/", authMiddleware(token, protected))
	return root
}
