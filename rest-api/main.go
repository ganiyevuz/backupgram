package main

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"backupgram/config"
	"backupgram/handlers"
	"backupgram/jobs"
	"backupgram/server"
	"backupgram/supervisor"
)

func resolveToken() (string, error) {
	if f := os.Getenv("REST_API_TOKEN_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", fmt.Errorf("REST_API_TOKEN_FILE set but unreadable: %w", err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return os.Getenv("REST_API_TOKEN"), nil
}

func getenvOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func gocronBin() string { return getenvOr("GOCRON_BIN", "/usr/local/bin/go-cron") }

func gocronArgs(schedule string, initialRun bool) []string {
	args := []string{"-s", schedule, "-p", getenvOr("HEALTHCHECK_PORT", "8080")}
	if initialRun && os.Getenv("BACKUP_ON_START") == "TRUE" {
		args = append(args, "-i")
	}
	return append(args, "--", "/backup.sh")
}

// modes says which route groups to serve, and the REST API's token.
type modes struct {
	rest, metrics bool
	token         string
}

// startup reads REST_API_ENABLE / METRICS_ENABLE. A token is required only for the REST API.
func startup() (modes, error) {
	m := modes{
		rest:    os.Getenv("REST_API_ENABLE") == "TRUE",
		metrics: os.Getenv("METRICS_ENABLE") == "TRUE",
	}
	if !m.rest && !m.metrics {
		return modes{}, errors.New("neither REST_API_ENABLE nor METRICS_ENABLE is TRUE; nothing to do")
	}
	if !m.rest {
		return m, nil
	}
	token, err := resolveToken()
	if err != nil {
		return modes{}, err
	}
	if token == "" {
		return modes{}, errors.New("REST_API_ENABLE=TRUE requires REST_API_TOKEN or REST_API_TOKEN_FILE")
	}
	m.token = token
	return m, nil
}

func main() {
	m, err := startup()
	if err != nil {
		log.Fatal(err)
	}

	schedule := config.Get("SCHEDULE")
	if schedule == "" {
		schedule = "@daily"
	}

	sup := supervisor.NewSupervisor(gocronBin(), gocronArgs(schedule, true))
	if err := sup.Start(); err != nil {
		log.Fatalf("failed to start scheduler: %v", err)
	}

	h := &handlers.Handlers{
		BackupDir:       getenvOr("BACKUP_DIR", "/backups"),
		Jobs:            jobs.NewJobManager(jobs.DefaultRunner),
		RestartSchedule: func(newSchedule string) error { return sup.Restart(gocronArgs(newSchedule, false)) },
	}

	srv := &http.Server{Addr: ":" + getenvOr("REST_API_PORT", "8081"), Handler: server.Router(server.Options{Token: m.token, REST: m.rest, Metrics: m.metrics}, h)}

	go func() {
		log.Printf("backupgram-api listening on %s (rest=%t, metrics=%t)", srv.Addr, m.rest, m.metrics)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	<-sigs
	log.Println("shutting down...")
	sup.Stop()
	_ = srv.Close()
}
