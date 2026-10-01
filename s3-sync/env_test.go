package main

import (
	"strings"
	"testing"
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
