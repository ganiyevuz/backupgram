package main

import (
	"sync"
	"testing"
	"time"
)

func waitState(t *testing.T, jm *JobManager, id, state string) *Job {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if j, ok := jm.Get(id); ok && j.State == state {
			return j
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("job %s did not reach %s", id, state)
	return nil
}

func TestJobSuccess(t *testing.T) {
	jm := NewJobManager(func(name string, args []string) (string, int, error) {
		return "ok output", 0, nil
	})
	defer jm.Stop()
	j := jm.Submit("backup", "/backup.sh", nil)
	done := waitState(t, jm, j.ID, "succeeded")
	if done.ExitCode != 0 {
		t.Errorf("exit=%d want 0", done.ExitCode)
	}
}

func TestJobFailure(t *testing.T) {
	jm := NewJobManager(func(name string, args []string) (string, int, error) {
		return "boom", 2, nil
	})
	defer jm.Stop()
	j := jm.Submit("restore", "/restore.sh", []string{"x"})
	done := waitState(t, jm, j.ID, "failed")
	if done.ExitCode != 2 {
		t.Errorf("exit=%d want 2", done.ExitCode)
	}
}

func TestJobsRunSerially(t *testing.T) {
	var mu sync.Mutex
	active, maxActive := 0, 0
	jm := NewJobManager(func(name string, args []string) (string, int, error) {
		mu.Lock()
		active++
		if active > maxActive {
			maxActive = active
		}
		mu.Unlock()
		time.Sleep(30 * time.Millisecond)
		mu.Lock()
		active--
		mu.Unlock()
		return "", 0, nil
	})
	defer jm.Stop()
	var ids []string
	for i := 0; i < 4; i++ {
		ids = append(ids, jm.Submit("backup", "/backup.sh", nil).ID)
	}
	for _, id := range ids {
		waitState(t, jm, id, "succeeded")
	}
	if maxActive != 1 {
		t.Errorf("maxActive=%d want 1 (jobs must serialize)", maxActive)
	}
}

func TestJobNotFound(t *testing.T) {
	jm := NewJobManager(func(name string, args []string) (string, int, error) { return "", 0, nil })
	defer jm.Stop()
	if _, ok := jm.Get("nope"); ok {
		t.Error("expected not found")
	}
}

func TestSubmitAfterStopMarksFailed(t *testing.T) {
	jm := NewJobManager(func(name string, args []string) (string, int, error) { return "", 0, nil })
	jm.Stop()
	j := jm.Submit("backup", "/backup.sh", nil)
	if j == nil || j.State != "failed" {
		t.Fatalf("expected failed job after stop, got %+v", j)
	}
}

func TestJobEmptyOutputHasNoBlankLogLine(t *testing.T) {
	jm := NewJobManager(func(name string, args []string) (string, int, error) { return "", 0, nil })
	defer jm.Stop()
	j := jm.Submit("backup", "/backup.sh", nil)
	done := waitState(t, jm, j.ID, "succeeded")
	if len(done.LogTail) != 0 {
		t.Errorf("LogTail=%v want empty for empty output", done.LogTail)
	}
}
