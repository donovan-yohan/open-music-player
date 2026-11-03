package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"

	"sync"
	"testing"
	"time"

	logpb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	"google.golang.org/protobuf/proto"

	apperrors "github.com/openmusicplayer/backend/internal/errors"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestRouterCanonicalRequestIDAndRecovery(t *testing.T) {
	rt, err := observability.New(context.Background(), observability.DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Shutdown(context.Background())
	var output bytes.Buffer
	log := rt.Logger(&logger.Config{Output: &output, Level: logger.LevelInfo})
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: log, AgentToolsHandler: apperrors.RequestIDMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := apperrors.GetRequestID(r.Context()); got == "PRIVATE_HEADER_CANARY" || got == "" {
			t.Errorf("request ID was replaced by untrusted header: %q", got)
		}
		if logger.GetRequestID(r.Context()) != apperrors.GetRequestID(r.Context()) {
			t.Error("different IDs")
		}
		if got := w.Header().Get("X-Request-ID"); got != logger.GetRequestID(r.Context()) {
			t.Errorf("response ID %q != context", got)
		}
		panic("PRIVATE_PANIC_CANARY")
	}))})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/internal/agent-tools/v1/panic", nil)
	req.Header.Set("X-Request-ID", "PRIVATE_HEADER_CANARY")
	router.ServeHTTP(rec, req)
	if rec.Code != 500 {
		t.Fatalf("panic status %d", rec.Code)
	}
	var response apperrors.ErrorResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &response)
	body := response.Error
	if body.RequestID != rec.Header().Get("X-Request-ID") {
		t.Fatalf("error ID %q != response ID %q", body.RequestID, rec.Header().Get("X-Request-ID"))
	}
	lines := bytes.Split(bytes.TrimSpace(output.Bytes()), []byte("\n"))
	if len(lines) != 2 {
		t.Fatalf("expected one local recovery and one completion: %s", output.String())
	}
	for _, line := range lines {
		var e logger.Entry
		_ = json.Unmarshal(line, &e)
		if e.RequestID != body.RequestID {
			t.Fatalf("mismatched log request ID: %s", line)
		}
	}
}

func TestRouterSamplingDisabledUnknownAndFlush(t *testing.T) {
	for _, mode := range []string{"ratio-zero", "disabled", "exporter-none", "flush"} {
		t.Run(mode, func(t *testing.T) {
			var mu sync.Mutex
			received := map[string][][]byte{}
			collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				data, _ := io.ReadAll(r.Body)
				mu.Lock()
				received[r.URL.Path] = append(received[r.URL.Path], data)
				mu.Unlock()
				w.Header().Set("Content-Type", "application/x-protobuf")
			}))
			defer collector.Close()
			c := observability.DefaultConfig()
			c.Endpoint = collector.URL
			c.TracesExporter = "otlp"
			c.LogsExporter = "otlp"
			c.MetricsExporter = "otlp"
			switch mode {
			case "ratio-zero":
				c.SampleRatio = 0
			case "disabled":
				c.Disabled = true
			case "exporter-none":
				c.TracesExporter = "none"
				c.LogsExporter = "none"
				c.MetricsExporter = "none"
			}
			rt, err := observability.New(context.Background(), c)
			if err != nil {
				t.Fatal(err)
			}
			defer rt.Shutdown(context.Background())
			router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: io.Discard})})
			req := httptest.NewRequest("GET", "/PRIVATE_UNKNOWN_PATH_CANARY?secret=PRIVATE_QUERY_CANARY", nil)
			req.Header.Set("Traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")
			router.ServeHTTP(httptest.NewRecorder(), req)
			if err := rt.ForceFlush(context.Background()); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			defer mu.Unlock()
			if mode == "disabled" || mode == "exporter-none" {
				if len(received) != 0 {
					t.Fatal("disabled exporter sent data")
				}
				return
			}
			if mode == "ratio-zero" && len(received["/v1/traces"]) != 0 {
				t.Fatal("incoming sampled flag bypassed ratio=0")
			}
			if mode == "flush" && len(received["/v1/traces"]) == 0 {
				t.Fatal("flush did not export trace")
			}
			if len(received["/v1/logs"]) == 0 || len(received["/v1/metrics"]) == 0 {
				t.Fatal("flush did not drain logs and metrics")
			}
			for _, parts := range received {
				for _, data := range parts {
					if bytes.Contains(data, []byte("PRIVATE_")) {
						t.Fatal("unknown path leaked")
					}
				}
			}
			logs := new(logpb.ExportLogsServiceRequest)
			_ = proto.Unmarshal(received["/v1/logs"][0], logs)
			found := false
			for _, a := range logs.ResourceLogs[0].ScopeLogs[0].LogRecords[0].Attributes {
				if a.Key == "http.route" && a.Value.GetStringValue() == "unknown" {
					found = true
				}
			}
			if !found {
				t.Fatal("missing fixed unknown route")
			}
		})
	}
}

func TestRouterExporterOutageBoundedShutdown(t *testing.T) {
	held := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { close(held) })
		<-release
		w.WriteHeader(503)
	}))
	defer collector.Close()
	defer close(release)
	c := observability.DefaultConfig()
	c.Endpoint = collector.URL
	c.TracesExporter = "otlp"
	c.LogsExporter = "otlp"
	c.MetricsExporter = "otlp"
	c.ExportTimeout = 100 * time.Millisecond
	c.ShutdownTimeout = 200 * time.Millisecond
	c.BatchInterval = 10 * time.Millisecond
	rt, err := observability.New(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: io.Discard})})
	started := time.Now()
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest("GET", "/health", nil))
	if rec.Code != 200 || time.Since(started) > time.Second {
		t.Fatal("export outage blocked request")
	}
	select {
	case <-held:
	case <-time.After(2 * time.Second):
		t.Fatal("export not attempted")
	}
	started = time.Now()
	err = rt.Shutdown(context.Background())
	if err == nil {
		t.Fatal("expected exporter failure")
	}
	if time.Since(started) > time.Second {
		t.Fatal("shutdown exceeded bounded budget")
	}
	if again := rt.Shutdown(context.Background()); again != err {
		t.Fatal("shutdown not idempotent")
	}
}
