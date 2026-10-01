package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// stalledMultipart plays just enough S3 for minio-go's multipart upload: it starts an upload,
// holds every part until the client gives up, lists the open uploads and records each abort.
type stalledMultipart struct {
	stop    chan struct{} // releases the held parts when the test ends
	mu      sync.Mutex
	open    map[string]string // upload id → key
	aborted []string          // "<key> <upload id>"
}

func (s *stalledMultipart) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	key := strings.TrimPrefix(r.URL.Path, "/bucket/")
	if r.Method == http.MethodPut && q.Has("partNumber") {
		_, _ = io.Copy(io.Discard, r.Body)
		select { // a stalled endpoint: the part never completes
		case <-r.Context().Done():
		case <-s.stop:
		}
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.Method == http.MethodPost && q.Has("uploads"):
		s.open["upload-1"] = key
		fmt.Fprintf(w, "<InitiateMultipartUploadResult><Bucket>bucket</Bucket><Key>%s</Key><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>", key)
	case r.Method == http.MethodGet && q.Has("uploads"):
		fmt.Fprint(w, "<ListMultipartUploadsResult><Bucket>bucket</Bucket><IsTruncated>false</IsTruncated>")
		for id, k := range s.open {
			if strings.HasPrefix(k, q.Get("prefix")) {
				fmt.Fprintf(w, "<Upload><Key>%s</Key><UploadId>%s</UploadId></Upload>", k, id)
			}
		}
		fmt.Fprint(w, "</ListMultipartUploadsResult>")
	case r.Method == http.MethodDelete && q.Has("uploadId"):
		s.aborted = append(s.aborted, key+" "+q.Get("uploadId"))
		delete(s.open, q.Get("uploadId"))
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "unexpected request", http.StatusNotImplemented)
	}
}

// A sync stopped in the middle of a multipart upload (S3_SYNC_TIMEOUT, SIGTERM) aborts that
// upload, so its parts are not left in the bucket.
func TestPutAbortsTheUploadItStopped(t *testing.T) {
	fake := &stalledMultipart{stop: make(chan struct{}), open: map[string]string{}}
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(fake.stop) })
	st, err := NewMinioStorage(Env{Bucket: "bucket", Endpoint: srv.URL, Region: "us-east-1",
		AccessKey: "key", SecretKey: "secret", PathStyle: true})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "db-20261123-040000.dump.gpg")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	const size = 17 << 20 // over one 16 MiB part: a multipart upload
	if err := f.Truncate(size); err != nil {
		t.Fatal(err)
	}
	f.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	start := time.Now()
	key := "p/db/db-20261123-040000.dump.gpg"
	if err := st.Put(ctx, key, path, size); err == nil {
		t.Fatal("Put to a stalled endpoint succeeded")
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("Put took %v", elapsed)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.aborted) != 1 || fake.aborted[0] != key+" upload-1" {
		t.Errorf("aborted = %q, want [%q]", fake.aborted, key+" upload-1")
	}
}
