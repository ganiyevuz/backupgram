package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gotd/td/telegram/uploader"
)

// progressLogger reports upload progress to stderr. gotd fires Chunk once per
// uploaded part (thousands of times for a multi-GB file), so output is
// throttled. Behaviour is terminal-aware:
//   - interactive (stderr is a TTY): a single in-place bar redrawn with \r,
//     updated on every 1% change.
//   - non-interactive (cron → `docker logs`): one full, newline-terminated
//     line per 10% crossed, since `docker logs` cannot process \r.
//
// Each line also reports cumulative transfer speed and an ETA.
type progressLogger struct {
	tty     bool
	lastPct int       // last percentage acted on (-1 = none yet)
	start   time.Time // set on the first chunk (first uploaded byte)
}

// newProgressLogger detects whether stderr is a terminal (a character device)
// and configures the output mode accordingly. No external dependency needed.
func newProgressLogger() *progressLogger {
	fi, err := os.Stderr.Stat()
	tty := err == nil && fi.Mode()&os.ModeCharDevice != 0
	return &progressLogger{tty: tty, lastPct: -1}
}

// Chunk implements uploader.Progress.
func (p *progressLogger) Chunk(_ context.Context, s uploader.ProgressState) error {
	if p.start.IsZero() {
		p.start = time.Now()
	}
	if line, ok := p.next(s, time.Since(p.start)); ok {
		fmt.Fprint(os.Stderr, line)
	}
	return nil
}

// next decides what (if anything) to emit for the given upload state and
// elapsed time. It returns the exact string to write and ok=true, or ok=false
// when this update is throttled away. Kept separate from I/O and the clock so
// it can be unit-tested deterministically.
func (p *progressLogger) next(s uploader.ProgressState, elapsed time.Duration) (string, bool) {
	if s.Total <= 0 {
		return "", false // unknown size (streamed upload) — nothing meaningful to show
	}
	pct := int(s.Uploaded * 100 / s.Total)

	if p.tty {
		if pct == p.lastPct {
			return "", false
		}
		p.lastPct = pct
		// \r returns to column 0; \033[K erases stale chars from a longer prior line.
		line := "\r" + p.format(s, elapsed, pct) + "\033[K"
		if pct >= 100 {
			line += "\n" // finish the line once complete
		}
		return line, true
	}

	// Non-TTY: emit only when a new 10% bucket is reached.
	if pct/10 <= p.lastPct/10 {
		return "", false
	}
	p.lastPct = pct
	return p.format(s, elapsed, pct) + "\n", true
}

// format builds the human-readable status text (without line terminators).
func (p *progressLogger) format(s uploader.ProgressState, elapsed time.Duration, pct int) string {
	speed, eta := "--", "--"
	if bps, remaining, ok := transferRate(s.Uploaded, s.Total, elapsed); ok {
		speed = humanBytes(int64(bps)) + "/s"
		eta = formatDuration(remaining)
	}
	return fmt.Sprintf("tg-upload: %s [%s] %3d%% (%s / %s) %s ETA %s",
		s.Name, progressBar(pct, 20), pct, humanBytes(s.Uploaded), humanBytes(s.Total), speed, eta)
}

// transferRate returns the cumulative speed (bytes/sec) and the estimated time
// remaining. ok is false until there is enough data to compute a rate.
func transferRate(uploaded, total int64, elapsed time.Duration) (bytesPerSec float64, remaining time.Duration, ok bool) {
	if elapsed <= 0 || uploaded <= 0 {
		return 0, 0, false
	}
	bytesPerSec = float64(uploaded) / elapsed.Seconds()
	if uploaded >= total {
		return bytesPerSec, 0, true
	}
	remaining = time.Duration(float64(total-uploaded)/bytesPerSec) * time.Second
	return bytesPerSec, remaining, true
}

// progressBar renders a fixed-width textual bar, e.g. "████████░░░░░░░░░░░░".
func progressBar(pct, width int) string {
	filled := pct * width / 100
	if filled > width {
		filled = width
	}
	if filled < 0 {
		filled = 0
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

// humanBytes formats a byte count as a human-readable size (e.g. "1.5 GB").
func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}

// formatDuration renders a duration compactly, e.g. "45s", "3m05s", "1h02m".
func formatDuration(d time.Duration) string {
	d = d.Round(time.Second)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	default:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
}
