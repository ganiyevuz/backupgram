package main

import "testing"

func TestHumanBytes(t *testing.T) {
	tests := []struct {
		in   int64
		want string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{52428800, "50.0 MB"},
		{2147483648, "2.0 GB"},
	}
	for _, tt := range tests {
		if got := humanBytes(tt.in); got != tt.want {
			t.Errorf("humanBytes(%d) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestProgressBar(t *testing.T) {
	tests := []struct {
		pct, width int
		want       string
	}{
		{0, 4, "░░░░"},
		{50, 4, "██░░"},
		{100, 4, "████"},
		{150, 4, "████"}, // clamped: never exceeds width
	}
	for _, tt := range tests {
		if got := progressBar(tt.pct, tt.width); got != tt.want {
			t.Errorf("progressBar(%d, %d) = %q, want %q", tt.pct, tt.width, got, tt.want)
		}
	}
}