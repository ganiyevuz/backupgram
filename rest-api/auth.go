package main

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
)

// authMiddleware enforces a constant-time bearer-token check on the wrapped
// handler. It is self-contained (writes its own 401). The caller is responsible
// for leaving /healthz unwrapped.
func authMiddleware(token string, next http.Handler) http.Handler {
	if token == "" {
		panic("authMiddleware: token must not be empty")
	}
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}
