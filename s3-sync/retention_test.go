package main

import (
	"testing"
	"time"
)

func TestKeep(t *testing.T) {
	r := Retention{Days: 7, Weeks: 4, Months: 3}
	cases := []struct {
		label      string
		now, stamp time.Time
		keep       bool
		reason     string
	}{
		{"age 7: daily", at(2026, 11, 24, 12), at(2026, 11, 17, 12), true, "daily"},
		{"age 8, a Monday: expires", at(2026, 11, 24, 12), at(2026, 11, 16, 12), false, "expires"},
		{"Sunday, age 29: weekly", at(2026, 11, 23, 12), at(2026, 10, 25, 12), true, "weekly"},
		{"Sunday, age 36: expires", at(2026, 11, 23, 12), at(2026, 10, 18, 12), false, "expires"},
		{"the 1st, age 94: monthly", at(2027, 1, 3, 12), at(2026, 10, 1, 12), true, "monthly"},
		{"the 1st, age 95: expires", at(2027, 1, 4, 12), at(2026, 10, 1, 12), false, "expires"},
		{"a stamp in the future: daily", at(2026, 11, 24, 12), at(2026, 11, 25, 12), true, "daily"},
	}
	for _, c := range cases {
		keep, reason := r.Keep(c.stamp, c.now)
		if keep != c.keep || reason != c.reason {
			t.Errorf("%s: Keep = %v, %q; want %v, %q", c.label, keep, reason, c.keep, c.reason)
		}
	}
}
