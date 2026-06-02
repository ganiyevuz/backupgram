package main

import (
	"strings"
	"testing"
	"time"

	"github.com/gotd/td/telegram/uploader"
)

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

func TestFormatDuration(t *testing.T) {
	tests := []struct {
		in   time.Duration
		want string
	}{
		{0, "0s"},
		{45 * time.Second, "45s"},
		{185 * time.Second, "3m05s"},
		{3725 * time.Second, "1h02m"},
	}
	for _, tt := range tests {
		if got := formatDuration(tt.in); got != tt.want {
			t.Errorf("formatDuration(%s) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestTransferRate(t *testing.T) {
	// 200 of 1000 bytes in 10s → 20 B/s, 800 bytes remaining → 40s ETA.
	bps, eta, ok := transferRate(200, 1000, 10*time.Second)
	if !ok || bps != 20 || eta != 40*time.Second {
		t.Errorf("transferRate(200,1000,10s) = (%v, %v, %v), want (20, 40s, true)", bps, eta, ok)
	}
	// Complete → ETA zero.
	if _, eta, ok := transferRate(1000, 1000, 10*time.Second); !ok || eta != 0 {
		t.Errorf("at 100%% want eta=0, ok=true; got eta=%v ok=%v", eta, ok)
	}
	// No elapsed / no bytes → not computable.
	if _, _, ok := transferRate(0, 1000, 10*time.Second); ok {
		t.Error("expected ok=false when nothing uploaded")
	}
	if _, _, ok := transferRate(100, 1000, 0); ok {
		t.Error("expected ok=false when elapsed is zero")
	}
}

// state is a helper to build a ProgressState at a given fraction of total.
func state(uploaded, total int64) uploader.ProgressState {
	return uploader.ProgressState{Name: "db.sql.gz", Uploaded: uploaded, Total: total}
}

func TestProgressNextUnknownSize(t *testing.T) {
	p := &progressLogger{lastPct: -1}
	if _, ok := p.next(uploader.ProgressState{Total: -1, Uploaded: 5}, time.Second); ok {
		t.Error("expected no output when total size is unknown")
	}
}

func TestProgressNextNonTTY(t *testing.T) {
	p := &progressLogger{tty: false, lastPct: -1}

	if _, ok := p.next(state(0, 1000), time.Second); ok {
		t.Error("0%: expected no output")
	}
	line, ok := p.next(state(100, 1000), 10*time.Second) // 10%
	if !ok {
		t.Fatal("10%: expected output")
	}
	if strings.Contains(line, "\r") || !strings.HasSuffix(line, "\n") {
		t.Errorf("non-TTY line must be a plain newline-terminated line, got %q", line)
	}
	if !strings.Contains(line, "/s") || !strings.Contains(line, "ETA") {
		t.Errorf("line must include speed and ETA, got %q", line)
	}
	if _, ok := p.next(state(150, 1000), 11*time.Second); ok { // 15%, same bucket
		t.Error("15%: expected no output within the same 10% bucket")
	}
	if _, ok := p.next(state(200, 1000), 12*time.Second); !ok { // 20%, next bucket
		t.Error("20%: expected output in the next 10% bucket")
	}
}

func TestProgressNextTTY(t *testing.T) {
	p := &progressLogger{tty: true, lastPct: -1}

	line, ok := p.next(state(10, 1000), time.Second) // 1%
	if !ok {
		t.Fatal("1%: expected output")
	}
	if !strings.HasPrefix(line, "\r") || !strings.Contains(line, "\033[K") || strings.HasSuffix(line, "\n") {
		t.Errorf("TTY line must start with CR, clear to EOL, and not end in newline mid-upload, got %q", line)
	}
	if _, ok := p.next(state(10, 1000), 2*time.Second); ok { // unchanged percent
		t.Error("expected no output when percent is unchanged")
	}
	final, ok := p.next(state(1000, 1000), 10*time.Second) // 100%
	if !ok || !strings.HasSuffix(final, "\n") {
		t.Errorf("TTY final line must end with a newline, got %q", final)
	}
}
