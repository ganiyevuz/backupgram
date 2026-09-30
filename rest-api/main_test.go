package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGocronArgs(t *testing.T) {
	t.Setenv("HEALTHCHECK_PORT", "8080")
	got := gocronArgs("@daily", false)
	want := []string{"-s", "@daily", "-p", "8080", "--", "/backup.sh"}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("arg[%d]=%q want %q (full %v)", i, got[i], want[i], got)
		}
	}
}

func TestGocronArgsBackupOnStart(t *testing.T) {
	t.Setenv("HEALTHCHECK_PORT", "9000")
	t.Setenv("BACKUP_ON_START", "TRUE")
	got := gocronArgs("@hourly", true)
	// must contain -i, and end with -- /backup.sh
	joined := ""
	for _, a := range got {
		joined += a + " "
	}
	if want := "-s @hourly -p 9000 -i -- /backup.sh "; joined != want {
		t.Fatalf("got %q want %q", joined, want)
	}
}

func TestGocronArgsNoInitNoIFlag(t *testing.T) {
	t.Setenv("HEALTHCHECK_PORT", "8080")
	t.Setenv("BACKUP_ON_START", "TRUE")
	got := gocronArgs("@hourly", false)
	// restart must never inject -i, even when BACKUP_ON_START=TRUE
	for _, a := range got {
		if a == "-i" {
			t.Fatalf("restart call must not contain -i flag; got %v", got)
		}
	}
}

func TestResolveTokenFilePrecedence(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "tok")
	os.WriteFile(f, []byte("filetoken\n"), 0o600)
	t.Setenv("REST_API_TOKEN", "envtoken")
	t.Setenv("REST_API_TOKEN_FILE", f)
	got, err := resolveToken()
	if err != nil || got != "filetoken" {
		t.Fatalf("got %q err %v want filetoken (file wins, trimmed)", got, err)
	}
}

func TestResolveTokenEnvFallback(t *testing.T) {
	t.Setenv("REST_API_TOKEN_FILE", "")
	t.Setenv("REST_API_TOKEN", "envtoken")
	got, err := resolveToken()
	if err != nil || got != "envtoken" {
		t.Fatalf("got %q err %v want envtoken", got, err)
	}
}

func TestResolveTokenFileUnreadableFailsClosed(t *testing.T) {
	t.Setenv("REST_API_TOKEN", "envtoken")
	t.Setenv("REST_API_TOKEN_FILE", filepath.Join(t.TempDir(), "does-not-exist"))
	if _, err := resolveToken(); err == nil {
		t.Fatal("expected error when REST_API_TOKEN_FILE is set but unreadable (must not fall back to env)")
	}
}

func TestStartupNothingEnabled(t *testing.T) {
	t.Setenv("REST_API_ENABLE", "FALSE")
	t.Setenv("METRICS_ENABLE", "FALSE")
	if _, err := startup(); err == nil {
		t.Fatal("expected an error when neither REST_API_ENABLE nor METRICS_ENABLE is TRUE")
	}
}

func TestStartupMetricsOnlyNeedsNoToken(t *testing.T) {
	t.Setenv("REST_API_ENABLE", "")
	t.Setenv("METRICS_ENABLE", "TRUE")
	t.Setenv("REST_API_TOKEN", "")
	t.Setenv("REST_API_TOKEN_FILE", "")
	m, err := startup()
	if err != nil || m.rest || !m.metrics || m.token != "" {
		t.Fatalf("got %+v err %v, want metrics only, no token", m, err)
	}
}

func TestStartupRESTNeedsToken(t *testing.T) {
	t.Setenv("REST_API_ENABLE", "TRUE")
	t.Setenv("METRICS_ENABLE", "")
	t.Setenv("REST_API_TOKEN", "")
	t.Setenv("REST_API_TOKEN_FILE", "")
	if _, err := startup(); err == nil {
		t.Fatal("expected an error: REST API without a token")
	}
	t.Setenv("REST_API_TOKEN", "tok")
	m, err := startup()
	if err != nil || !m.rest || m.metrics || m.token != "tok" {
		t.Fatalf("got %+v err %v, want rest with token tok", m, err)
	}
}
