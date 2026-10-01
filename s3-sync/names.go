package main

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// stampedName matches <db>-YYYYMMDD-HHMMSS<suffix>, the suffix starting with a dot. The
// database part is greedy, so a database whose own name looks like a stamp
// (keep-20260101) parses as that full name: the stamp is always the last one.
var stampedName = regexp.MustCompile(`^(.+)-([0-9]{8}-[0-9]{6})(\.[^/]+)$`)

// ParseStamped returns the database and the dump time (in the local time zone, as
// backupgram writes it) of a stamped backup name.
func ParseStamped(name string) (db string, stamp time.Time, ok bool) {
	m := stampedName.FindStringSubmatch(name)
	if m == nil {
		return "", time.Time{}, false
	}
	t, err := time.ParseInLocation("20060102-150405", m[2], time.Local)
	if err != nil {
		return "", time.Time{}, false
	}
	return m[1], t, true
}

// ObjectKey is where a dump lives in the bucket: <prefix>/<db>/<name>.
func ObjectKey(prefix, db, name string) string {
	if p := strings.Trim(prefix, "/"); p != "" {
		return p + "/" + db + "/" + name
	}
	return db + "/" + name
}

// ListPrefix is the listing prefix of everything stored under prefix.
func ListPrefix(prefix string) string {
	if p := strings.Trim(prefix, "/"); p != "" {
		return p + "/"
	}
	return ""
}

// baseName is the last path element of an object key.
func baseName(key string) string {
	return key[strings.LastIndex(key, "/")+1:]
}

// humanSize formats a byte count like du -h: 512, 2.0K, 5.0M, 3.0G.
func humanSize(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d", n)
	}
	f := float64(n)
	for _, suffix := range []string{"K", "M", "G", "T"} {
		f /= unit
		if f < unit {
			return fmt.Sprintf("%.1f%s", f, suffix)
		}
	}
	return fmt.Sprintf("%.1fP", f/unit)
}
