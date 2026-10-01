package main

import "time"

// Retention is the off-site keep policy, in the same tiers as the local folders.
type Retention struct {
	Days, Weeks, Months int
}

// Keep reports whether a dump taken at stamp is kept at now, and under which tier:
// every dump for Days days ("daily"), a Sunday's for 7×Weeks+1 days ("weekly"), the
// 1st's for 31×Months+1 days ("monthly"); otherwise "expires". Ages count whole days,
// rounded down, as `find -mtime` counts them for the local folders.
func (r Retention) Keep(stamp, now time.Time) (bool, string) {
	age := int(now.Sub(stamp) / (24 * time.Hour))
	switch {
	case age <= r.Days:
		return true, "daily"
	case stamp.Weekday() == time.Sunday && age <= 7*r.Weeks+1:
		return true, "weekly"
	case stamp.Day() == 1 && age <= 31*r.Months+1:
		return true, "monthly"
	}
	return false, "expires"
}
