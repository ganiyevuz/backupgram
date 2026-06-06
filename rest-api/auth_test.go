package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
}

func TestAuthMissingToken(t *testing.T) {
	h := authMiddleware("secret", okHandler())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/status", nil))
	if rec.Code != 401 {
		t.Fatalf("code=%d want 401", rec.Code)
	}
}

func TestAuthWrongToken(t *testing.T) {
	h := authMiddleware("secret", okHandler())
	req := httptest.NewRequest("GET", "/status", nil)
	req.Header.Set("Authorization", "Bearer nope")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("code=%d want 401", rec.Code)
	}
}

func TestAuthWrongTokenSameLength(t *testing.T) {
	// same length as "Bearer secret" but wrong, exercises ConstantTimeCompare path
	h := authMiddleware("secret", okHandler())
	req := httptest.NewRequest("GET", "/status", nil)
	req.Header.Set("Authorization", "Bearer xxxxxx")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("code=%d want 401", rec.Code)
	}
}

func TestAuthGoodToken(t *testing.T) {
	h := authMiddleware("secret", okHandler())
	req := httptest.NewRequest("GET", "/status", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("code=%d want 200", rec.Code)
	}
}
