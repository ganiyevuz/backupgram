package main

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Env is the S3_* configuration. scripts/s3-env.sh resolves the *_FILE secrets and the
// defaults before s3-sync runs; LoadEnv applies the same defaults for direct use.
type Env struct {
	Bucket, Endpoint, Region, AccessKey, SecretKey, Prefix string
	PathStyle, Prune, AllowUnencrypted                     bool
	Retention                                              Retention
	SyncTimeout                                            time.Duration // the time limit of one sync
}

// LoadEnv reads and checks the S3_* variables.
func LoadEnv(getenv func(string) string) (Env, error) {
	or := func(k, def string) string {
		if v := getenv(k); v != "" {
			return v
		}
		return def
	}
	e := Env{
		Bucket:    getenv("S3_BUCKET"),
		Endpoint:  or("S3_ENDPOINT", "https://s3.amazonaws.com"),
		Region:    or("S3_REGION", "us-east-1"),
		AccessKey: getenv("S3_ACCESS_KEY_ID"),
		SecretKey: getenv("S3_SECRET_ACCESS_KEY"),
		Prefix:    getenv("S3_PREFIX"),
	}
	if e.Bucket == "" {
		return Env{}, errors.New("S3_BUCKET is not set")
	}
	if e.AccessKey == "" || e.SecretKey == "" {
		return Env{}, errors.New("S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are required")
	}
	if u, err := url.Parse(e.Endpoint); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return Env{}, fmt.Errorf("S3_ENDPOINT must be http(s)://host[:port] (got %q)", e.Endpoint)
	}
	var err error
	if e.PathStyle, err = boolVar(getenv, "S3_FORCE_PATH_STYLE", false); err != nil {
		return Env{}, err
	}
	if e.Prune, err = boolVar(getenv, "S3_PRUNE", true); err != nil {
		return Env{}, err
	}
	if e.AllowUnencrypted, err = boolVar(getenv, "S3_ALLOW_UNENCRYPTED", false); err != nil {
		return Env{}, err
	}
	if e.Retention.Days, err = intVar(getenv, "S3_KEEP_DAYS", 7); err != nil {
		return Env{}, err
	}
	if e.Retention.Weeks, err = intVar(getenv, "S3_KEEP_WEEKS", 4); err != nil {
		return Env{}, err
	}
	if e.Retention.Months, err = intVar(getenv, "S3_KEEP_MONTHS", 6); err != nil {
		return Env{}, err
	}
	if e.SyncTimeout, err = secondsVar(getenv, "S3_SYNC_TIMEOUT", 3600); err != nil {
		return Env{}, err
	}
	return e, nil
}

// Location is s3://bucket[/prefix], for messages.
func (e Env) Location() string {
	if p := strings.Trim(e.Prefix, "/"); p != "" {
		return "s3://" + e.Bucket + "/" + p
	}
	return "s3://" + e.Bucket
}

func boolVar(getenv func(string) string, k string, def bool) (bool, error) {
	switch v := getenv(k); v {
	case "":
		return def, nil
	case "TRUE":
		return true, nil
	case "FALSE":
		return false, nil
	default:
		return false, fmt.Errorf("%s must be TRUE or FALSE (got %q)", k, v)
	}
}

func intVar(getenv func(string) string, k string, def int) (int, error) {
	v := getenv(k)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s must be a whole number (got %q)", k, v)
	}
	return n, nil
}

// secondsPattern is the form of a time limit in seconds: 1 to 9 ASCII digits (at most
// 999999999), the same values scripts/s3-env.sh accepts.
var secondsPattern = regexp.MustCompile(`^[0-9]{1,9}$`)

func secondsVar(getenv func(string) string, k string, def int64) (time.Duration, error) {
	v := getenv(k)
	if v == "" {
		return time.Duration(def) * time.Second, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if !secondsPattern.MatchString(v) || err != nil || n <= 0 {
		return 0, fmt.Errorf("%s must be a whole number of seconds from 1 to 999999999 (got %q)", k, v)
	}
	return time.Duration(n) * time.Second, nil
}
