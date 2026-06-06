package supervisor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMain doubles this test binary as a stub scheduler subprocess.
// When the first argument contains the sentinel prefix "STUB_MARKER:", the
// binary appends "launch\n" to the given file and sleeps, mimicking go-cron.
// Otherwise it runs the normal test suite.
func TestMain(m *testing.M) {
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "STUB_MARKER:") {
			marker := strings.TrimPrefix(arg, "STUB_MARKER:")
			f, err := os.OpenFile(marker, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			if err != nil {
				os.Exit(1)
			}
			f.WriteString("launch\n")
			f.Close()
			time.Sleep(30 * time.Second) // stay alive until killed
			os.Exit(0)
		}
	}
	os.Exit(m.Run())
}

// writeStubScheduler returns the path to the current test binary (already
// trusted & warm on macOS) and a fresh marker file path.  The binary acts as
// a stub scheduler when invoked with a "STUB_MARKER:<path>" argument
// (see TestMain above).
func writeStubScheduler(t *testing.T) (bin, marker string) {
	t.Helper()
	dir := t.TempDir()
	marker = filepath.Join(dir, "launches.log")

	// Re-use the already-compiled, already-trusted test binary as the stub.
	// This avoids macOS Gatekeeper cold-scan latency for newly created executables.
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bin = self
	return bin, marker
}

func countLines(t *testing.T, p string) int {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return 0 // stub hasn't written the marker yet
		}
		t.Fatalf("read marker %s: %v", p, err)
	}
	n := 0
	for _, c := range b {
		if c == '\n' {
			n++
		}
	}
	return n
}

func TestSupervisorStartAndRestart(t *testing.T) {
	bin, marker := writeStubScheduler(t)
	sup := NewSupervisor(bin, []string{"STUB_MARKER:" + marker})
	if err := sup.Start(); err != nil {
		t.Fatal(err)
	}
	defer sup.Stop()
	time.Sleep(200 * time.Millisecond)
	if got := countLines(t, marker); got != 1 {
		t.Fatalf("launches=%d want 1", got)
	}
	if err := sup.Restart([]string{"STUB_MARKER:" + marker}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if got := countLines(t, marker); got != 2 {
		t.Fatalf("launches=%d want 2 after restart", got)
	}
}

func TestSupervisorStopIdempotentish(t *testing.T) {
	bin, marker := writeStubScheduler(t)
	sup := NewSupervisor(bin, []string{"STUB_MARKER:" + marker})
	if err := sup.Start(); err != nil {
		t.Fatal(err)
	}
	sup.Stop()
	sup.Stop() // second stop must not panic (cmd is nil now)
}
