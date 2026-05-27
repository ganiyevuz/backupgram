package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/gotd/td/telegram/uploader"
)

// progressLogger logs upload progress to stderr in whole lines suitable for
// container logs. gotd fires Chunk once per uploaded part (thousands of times
// for a multi-GB file), so output is throttled to one line per 10% crossed
// rather than a carriage-return progress bar, which `docker logs` would garble.
type progressLogger struct {
	lastStep int // highest 10%-bucket already logged (0 = none yet)
}

// Chunk implements uploader.Progress.
func (p *progressLogger) Chunk(_ context.Context, s uploader.ProgressState) error {
	if s.Total <= 0 {
		return nil // unknown size (streamed upload) — nothing meaningful to show
	}
	pct := int(s.Uploaded * 100 / s.Total)
	step := pct / 10
	if step <= p.lastStep {
		return nil
	}
	p.lastStep = step
	fmt.Fprintf(os.Stderr, "tg-upload: %s [%s] %3d%% (%s / %s)\n",
		s.Name, progressBar(pct, 20), pct, humanBytes(s.Uploaded), humanBytes(s.Total))
	return nil
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