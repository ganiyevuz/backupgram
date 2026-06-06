package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pgbackupapi/httpx"
)

func withBackupDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	t.Setenv("BACKUP_DIR", d)
	return d
}

func TestShellSingleQuote(t *testing.T) {
	cases := map[string]string{
		"plain":     "'plain'",
		"a b":       "'a b'",
		"it's":      `'it'\''s'`,
		"$(rm -rf)": `'$(rm -rf)'`,
	}
	for in, want := range cases {
		if got := shellSingleQuote(in); got != want {
			t.Errorf("shellSingleQuote(%q)=%q want %q", in, got, want)
		}
	}
}

func TestValidatePatchRejectsUnknownKey(t *testing.T) {
	withBackupDir(t)
	err := ValidatePatch(map[string]string{"POSTGRES_PASSWORD": "x"})
	ae, ok := err.(*httpx.Error)
	if !ok || ae.Status != 403 {
		t.Fatalf("want 403 httpx.Error, got %v", err)
	}
}

func TestValidatePatchRejectsBadValue(t *testing.T) {
	withBackupDir(t)
	err := ValidatePatch(map[string]string{"BACKUP_KEEP_DAYS": "notanint"})
	ae, ok := err.(*httpx.Error)
	if !ok || ae.Status != 400 {
		t.Fatalf("want 400 httpx.Error, got %v", err)
	}
}

func TestValidatePatchRejectsNewline(t *testing.T) {
	withBackupDir(t)
	err := ValidatePatch(map[string]string{"POSTGRES_DB": "a\nb"})
	if ae, ok := err.(*httpx.Error); !ok || ae.Status != 400 {
		t.Fatalf("want 400 httpx.Error, got %v", err)
	}
}

func TestApplyPatchWritesBothFilesAndSchedFlag(t *testing.T) {
	dir := withBackupDir(t)
	changed, err := ApplyPatch(map[string]string{"SCHEDULE": "@hourly", "BACKUP_KEEP_DAYS": "14"})
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Error("schedule change should set scheduleChanged=true")
	}
	jsonRaw, _ := os.ReadFile(filepath.Join(dir, ".api-overrides.json"))
	if !strings.Contains(string(jsonRaw), `"BACKUP_KEEP_DAYS":"14"`) {
		t.Errorf("json missing key: %s", jsonRaw)
	}
	envRaw, _ := os.ReadFile(filepath.Join(dir, ".api-overrides.env"))
	if !strings.Contains(string(envRaw), "export BACKUP_KEEP_DAYS='14'") {
		t.Errorf("env missing export: %s", envRaw)
	}
	fi, _ := os.Stat(filepath.Join(dir, ".api-overrides.env"))
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("env mode = %v want 0600", fi.Mode().Perm())
	}
}

func TestEffectiveConfigMasksSecrets(t *testing.T) {
	withBackupDir(t)
	if _, err := ApplyPatch(map[string]string{"TELEGRAM_BOT_TOKEN": "supersecret"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := Effective()
	if err != nil {
		t.Fatal(err)
	}
	entry := cfg["TELEGRAM_BOT_TOKEN"].(map[string]any)
	if entry["set"] != true {
		t.Errorf("secret should report set=true, got %v", entry)
	}
	if _, leaked := entry["value"]; leaked {
		t.Error("secret value must never appear in Effective")
	}
	if entry["source"] != "override" {
		t.Errorf("source=%v want override", entry["source"])
	}
}

func TestClearOverrideReverts(t *testing.T) {
	withBackupDir(t)
	ApplyPatch(map[string]string{"BACKUP_KEEP_DAYS": "14"})
	existed, err := ClearOverride("BACKUP_KEEP_DAYS")
	if err != nil || !existed {
		t.Fatalf("clear failed: existed=%v err=%v", existed, err)
	}
	ov, _ := loadOverrides()
	if _, still := ov["BACKUP_KEEP_DAYS"]; still {
		t.Error("override not cleared")
	}
}

func TestValidatePatchUploadMethod(t *testing.T) {
	withBackupDir(t)
	if err := ValidatePatch(map[string]string{"TELEGRAM_UPLOAD_METHOD": "mtproto"}); err != nil {
		t.Fatalf("mtproto should be valid: %v", err)
	}
	if err := ValidatePatch(map[string]string{"TELEGRAM_UPLOAD_METHOD": "carrier-pigeon"}); err == nil {
		t.Fatal("invalid upload method must be rejected")
	}
}

func TestValidateCronEveryRequiresDuration(t *testing.T) {
	if validateCron("@every ") == nil {
		t.Error("@every with no duration must be rejected")
	}
	if validateCron("@every 1h") != nil {
		t.Error("@every 1h must be accepted")
	}
}
