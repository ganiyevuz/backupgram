package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"pgbackupapi/config"
	"pgbackupapi/handlers"
	"pgbackupapi/jobs"
	"pgbackupapi/server"
	"pgbackupapi/supervisor"
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

func gocronArgs(schedule string) []string {
	args := []string{"-s", schedule, "-p", getenvOr("HEALTHCHECK_PORT", "8080")}
	if os.Getenv("BACKUP_ON_START") == "TRUE" {
		args = append(args, "-i")
	}
	return append(args, "--", "/backup.sh")
}

func main() {
	if os.Getenv("REST_API_ENABLE") != "TRUE" {
		log.Fatal("REST_API_ENABLE is not TRUE; nothing to do")
	}
	token, err := resolveToken()
	if err != nil {
		log.Fatal(err)
	}
	if token == "" {
		log.Fatal("REST_API_ENABLE=TRUE requires REST_API_TOKEN or REST_API_TOKEN_FILE")
	}

	schedule := config.Get("SCHEDULE")
	if schedule == "" {
		schedule = "@daily"
	}

	sup := supervisor.NewSupervisor(gocronBin(), gocronArgs(schedule))
	if err := sup.Start(); err != nil {
		log.Fatalf("failed to start scheduler: %v", err)
	}

	h := &handlers.Handlers{
		BackupDir:       getenvOr("BACKUP_DIR", "/backups"),
		Jobs:            jobs.NewJobManager(jobs.DefaultRunner),
		RestartSchedule: func(newSchedule string) error { return sup.Restart(gocronArgs(newSchedule)) },
	}

	srv := &http.Server{Addr: ":" + getenvOr("REST_API_PORT", "8081"), Handler: server.Router(token, h)}

	go func() {
		log.Printf("pgbackup-api listening on %s", srv.Addr)
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
