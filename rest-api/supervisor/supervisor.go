package supervisor

import (
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Supervisor runs the scheduler binary (go-cron) as a child and can restart it.
type Supervisor struct {
	bin    string
	args   []string
	mu     sync.Mutex
	cmd    *exec.Cmd
	waitCh chan error
}

func NewSupervisor(bin string, args []string) *Supervisor {
	return &Supervisor{bin: bin, args: args}
}

func (s *Supervisor) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.startLocked(s.args)
}

func (s *Supervisor) startLocked(args []string) error {
	cmd := exec.Command(s.bin, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }() // the ONLY Wait on this child
	s.cmd = cmd
	s.args = args
	s.waitCh = waitCh
	return nil
}

func (s *Supervisor) stopLocked() {
	if s.cmd == nil || s.cmd.Process == nil {
		return
	}
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.waitCh:
	case <-time.After(5 * time.Second):
		_ = s.cmd.Process.Kill()
		<-s.waitCh
	}
	s.cmd = nil
	s.waitCh = nil
}

// Restart stops the current child and starts a new one with newArgs.
func (s *Supervisor) Restart(newArgs []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
	return s.startLocked(newArgs)
}

func (s *Supervisor) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
}
