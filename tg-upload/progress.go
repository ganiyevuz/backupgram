package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/gotd/td/telegram/uploader"
)

// progressLogger reports upload progress to stderr. gotd fires Chunk once per
// uploaded part (thousands of times for a multi-GB file), so output is
// throttled. Behaviour is terminal-aware:
//   - interactive (stderr is a TTY): a single in-place bar redrawn with \r,
//     updated on every 1% change.
//   - non-interactive (cron → `docker logs`): one full, newline-terminated
//     line per 10% crossed, since `docker logs` cannot process \r.
type progressLogger struct {
	tty     bool
	lastPct int // last percentage acted on (-1 = none yet)
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
	if line, ok := p.next(s); ok {
		fmt.Fprint(os.Stderr, line)
	}
	return nil
}

// next decides what (if anything) to emit for the given upload state. It
// returns the exact string to write and ok=true, or ok=false when this update
// is throttled away. Kept separate from I/O so it can be unit-tested.
func (p *progressLogger) next(s uploader.ProgressState) (string, bool) {
	if s.Total <= 0 {
		return "", false // unknown size (streamed upload) — nothing meaningful to show
	}
	pct := int(s.Uploaded * 100 / s.Total)
	bar := progressBar(pct, 20)

	if p.tty {
		if pct == p.lastPct {
			return "", false
		}
		p.lastPct = pct
		// \r returns to column 0; \033[K erases stale chars from a longer prior line.
		line := fmt.Sprintf("\rtg-upload: %s [%s] %3d%% (%s / %s)\033[K",
			s.Name, bar, pct, humanBytes(s.Uploaded), humanBytes(s.Total))
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
	return fmt.Sprintf("tg-upload: %s [%s] %3d%% (%s / %s)\n",
		s.Name, bar, pct, humanBytes(s.Uploaded), humanBytes(s.Total)), true
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