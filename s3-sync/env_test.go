package main

import (
	"strings"
	"testing"
	"time"
)

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func baseEnv() map[string]string {
	return map[string]string{"S3_BUCKET": "b", "S3_ACCESS_KEY_ID": "k", "S3_SECRET_ACCESS_KEY": "s"}
}

func TestLoadEnvDefaults(t *testing.T) {
	e, err := LoadEnv(envOf(baseEnv()))
	if err != nil {
		t.Fatal(err)
	}
	if e.Endpoint != "https://s3.amazonaws.com" || e.Region != "us-east-1" || !e.Prune || e.PathStyle || e.AllowUnencrypted {
		t.Errorf("defaults = %+v", e)
	}
	if e.Retention != (Retention{Days: 7, Weeks: 4, Months: 6}) {
		t.Errorf("retention = %+v", e.Retention)
	}
	if e.SyncTimeout != time.Hour {
		t.Errorf("sync timeout = %v, want 1h", e.SyncTimeout)
	}
	if e.Location() != "s3://b" {
		t.Errorf("location = %q", e.Location())
	}
}

func TestLoadEnvErrors(t *testing.T) {
	cases := map[string]map[string]string{
		"S3_BUCKET":        {"S3_BUCKET": ""},
		"S3_ACCESS_KEY_ID": {"S3_SECRET_ACCESS_KEY": ""},
		"S3_ENDPOINT":      {"S3_ENDPOINT": "minio:9000"},
		"S3_PRUNE":         {"S3_PRUNE": "yes"},
		"S3_KEEP_DAYS":     {"S3_KEEP_DAYS": "seven"},
	}
	for want, override := range cases {
		m := baseEnv()
		for k, v := range override {
			m[k] = v
		}
		if _, err := LoadEnv(envOf(m)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%v: err = %v, want one naming %s", override, err, want)
		}
	}
}

func TestLoadEnvValues(t *testing.T) {
	m := baseEnv()
	m["S3_ENDPOINT"] = "http://s3:9000"
	m["S3_PREFIX"] = "/platform-test/"
	m["S3_FORCE_PATH_STYLE"] = "TRUE"
	m["S3_PRUNE"] = "FALSE"
	m["S3_KEEP_DAYS"] = "14"
	e, err := LoadEnv(envOf(m))
	if err != nil {
		t.Fatal(err)
	}
	if !e.PathStyle || e.Prune || e.Retention.Days != 14 || e.Location() != "s3://b/platform-test" {
		t.Errorf("env = %+v location %q", e, e.Location())
	}
}

func TestLoadEnvSyncTimeout(t *testing.T) {
	m := baseEnv()
	m["S3_SYNC_TIMEOUT"] = "90"
	e, err := LoadEnv(envOf(m))
	if err != nil || e.SyncTimeout != 90*time.Second {
		t.Errorf("S3_SYNC_TIMEOUT=90: %v, err %v", e.SyncTimeout, err)
	}
	// The values scripts/s3-env.sh accepts: 1 to 9 digits, above 0, leading zeros allowed.
	for v, want := range map[string]time.Duration{"0005": 5 * time.Second, "999999999": 999999999 * time.Second} {
		m["S3_SYNC_TIMEOUT"] = v
		e, err := LoadEnv(envOf(m))
		if err != nil || e.SyncTimeout != want {
			t.Errorf("S3_SYNC_TIMEOUT=%q: %v, err %v; want %v", v, e.SyncTimeout, err, want)
		}
	}
	for _, bad := range []string{"0", "abc", "-5", "-1", "+5", " 5", "1.5", "1000000000"} {
		m["S3_SYNC_TIMEOUT"] = bad
		_, err := LoadEnv(envOf(m))
		want := `S3_SYNC_TIMEOUT must be a whole number of seconds from 1 to 999999999 (got "` + bad + `")`
		if err == nil || err.Error() != want {
			t.Errorf("S3_SYNC_TIMEOUT=%q: err = %v, want %s", bad, err, want)
		}
	}
}
