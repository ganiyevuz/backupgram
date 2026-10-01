package main

import (
	"os"
	"testing"
	"time"
)

// Stamps are parsed in time.Local; pin it so the tests do not depend on the machine's zone.
func TestMain(m *testing.M) {
	time.Local = time.UTC
	os.Exit(m.Run())
}

func at(y int, mo time.Month, d, h int) time.Time {
	return time.Date(y, mo, d, h, 0, 0, 0, time.UTC)
}
