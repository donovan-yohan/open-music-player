package middleware

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestTimingHeaderExistsOnWire(t *testing.T) {
	for _, flushFirst := range []bool{false, true} {
		t.Run(map[bool]string{false: "write", true: "flush"}[flushFirst], func(t *testing.T) {
			server := httptest.NewServer(Timing(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if flushFirst {
					if err := http.NewResponseController(w).Flush(); err != nil {
						t.Error(err)
					}
				}
				io.WriteString(w, "response")
			})))
			defer server.Close()
			res, err := server.Client().Get(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			_, _ = io.Copy(io.Discard, res.Body)
			if !strings.Contains(res.Header.Get("Server-Timing"), "first_response;dur=") {
				t.Fatalf("missing honest first-response timing on wire: %v", res.Header)
			}
		})
	}
}

func TestETagLargeResponseDeliversBeforeCompletion(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	server := httptest.NewServer(ETag(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, strings.Repeat("a", (1<<20)+1))
		if err := http.NewResponseController(w).Flush(); err != nil {
			t.Error(err)
		}
		select {
		case <-r.Context().Done():
		case <-release:
		}
	})))
	defer server.Close()
	client := &http.Client{Timeout: 2 * time.Second}
	res, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data := make([]byte, 3)
	if _, err := io.ReadFull(res.Body, data); err != nil || string(data) != "aaa" {
		t.Fatalf("early bytes %q %v", data, err)
	}
	if res.Header.Get("ETag") != "" {
		t.Fatal("large streamed response got validator")
	}
}
