package jobs

import (
	"crypto/rand"
	"encoding/hex"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// CommandRunner executes a command and returns combined output + exit code.
type CommandRunner func(name string, args []string) (output string, exitCode int, err error)

// DefaultRunner runs the command for real via os/exec.
func DefaultRunner(name string, args []string) (string, int, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	exit := 0
	if ee, ok := err.(*exec.ExitError); ok {
		exit = ee.ExitCode()
		err = nil
	}
	return string(out), exit, err
}

type Job struct {
	ID         string   `json:"id"`
	Type       string   `json:"type"`
	State      string   `json:"state"` // queued|running|succeeded|failed
	QueuedAt   int64    `json:"queued_at"`
	StartedAt  int64    `json:"started_at,omitempty"`
	FinishedAt int64    `json:"finished_at,omitempty"`
	ExitCode   int      `json:"exit_code"`
	LogTail    []string `json:"log_tail"`
	Err        string   `json:"error,omitempty"`
}

const maxJobs = 100
const logTailLines = 50

type jobTask struct {
	job  *Job
	name string
	args []string
}

type JobManager struct {
	mu       sync.Mutex
	jobs     map[string]*Job
	order    []string
	queue    chan jobTask
	done     chan struct{}
	stopOnce sync.Once
	runner   CommandRunner
	wg       sync.WaitGroup
}

func NewJobManager(runner CommandRunner) *JobManager {
	jm := &JobManager{
		jobs:   map[string]*Job{},
		queue:  make(chan jobTask, 256),
		done:   make(chan struct{}),
		runner: runner,
	}
	jm.wg.Add(1)
	go jm.worker()
	return jm
}

func newJobID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Submit registers a job and enqueues it for the single worker. It returns a
// snapshot copy (never the live pointer the worker mutates). If the manager has
// been stopped, the job is marked failed instead of enqueued (no panic).
func (jm *JobManager) Submit(jobType, name string, args []string) *Job {
	j := &Job{ID: newJobID(), Type: jobType, State: "queued", QueuedAt: time.Now().Unix()}
	jm.mu.Lock()
	jm.jobs[j.ID] = j
	jm.order = append(jm.order, j.ID)
	if len(jm.order) > maxJobs {
		old := jm.order[0]
		jm.order = jm.order[1:]
		delete(jm.jobs, old)
	}
	jm.mu.Unlock()

	// Check done first (non-blocking) so a stopped manager never enqueues onto
	// the buffered queue, which the exited worker would never drain. A bare
	// select would pick randomly between the ready send and the closed done
	// channel, leaving the job stuck in "queued".
	select {
	case <-jm.done:
		jm.setState(j, "failed", func(x *Job) {
			x.FinishedAt = time.Now().Unix()
			x.Err = "job manager stopped"
		})
	default:
		select {
		case jm.queue <- jobTask{job: j, name: name, args: args}:
		case <-jm.done:
			jm.setState(j, "failed", func(x *Job) {
				x.FinishedAt = time.Now().Unix()
				x.Err = "job manager stopped"
			})
		}
	}
	cp, _ := jm.Get(j.ID)
	return cp
}

func (jm *JobManager) worker() {
	defer jm.wg.Done()
	for {
		select {
		case <-jm.done:
			return
		case task := <-jm.queue:
			jm.runTask(task)
		}
	}
}

func (jm *JobManager) runTask(task jobTask) {
	jm.setState(task.job, "running", func(j *Job) { j.StartedAt = time.Now().Unix() })
	out, exit, err := jm.runner(task.name, task.args)
	jm.setState(task.job, stateFor(exit, err), func(j *Job) {
		j.ExitCode = exit
		j.FinishedAt = time.Now().Unix()
		j.LogTail = tailLines(out, logTailLines)
		if err != nil {
			j.Err = err.Error()
		}
	})
}

func stateFor(exit int, err error) string {
	if err != nil || exit != 0 {
		return "failed"
	}
	return "succeeded"
}

func (jm *JobManager) setState(j *Job, state string, mutate func(*Job)) {
	jm.mu.Lock()
	defer jm.mu.Unlock()
	j.State = state
	mutate(j)
}

// Get returns a snapshot copy (safe to read without the lock). The copied
// LogTail shares its backing array with the stored job, but LogTail is assigned
// once at completion and never mutated afterward, so the share is safe.
func (jm *JobManager) Get(id string) (*Job, bool) {
	jm.mu.Lock()
	defer jm.mu.Unlock()
	j, ok := jm.jobs[id]
	if !ok {
		return nil, false
	}
	cp := *j
	return &cp, true
}

func (jm *JobManager) List() []*Job {
	jm.mu.Lock()
	defer jm.mu.Unlock()
	// order and jobs are kept in sync under mu, so every id resolves.
	out := make([]*Job, 0, len(jm.order))
	for i := len(jm.order) - 1; i >= 0; i-- { // newest first
		cp := *jm.jobs[jm.order[i]]
		out = append(out, &cp)
	}
	return out
}

// Stop signals the worker to exit and waits for it. Idempotent and safe to call
// concurrently with Submit (Submit marks new jobs failed rather than panic).
func (jm *JobManager) Stop() {
	jm.stopOnce.Do(func() { close(jm.done) })
	jm.wg.Wait()
}

func tailLines(s string, n int) []string {
	if s == "" {
		return nil
	}
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
