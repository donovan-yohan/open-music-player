package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/metrics"
	"github.com/openmusicplayer/backend/internal/middleware"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestComposedObserverRetainsCanonicalIDThroughLegacyMiddleware(t *testing.T) {
	rt, _ := observability.New(context.Background(), observability.DefaultConfig())
	defer rt.Shutdown(context.Background())
	var logs bytes.Buffer
	log := rt.Logger(&logger.Config{Output: &logs})
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: log, AgentToolsHandler: middleware.RequestID(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if logger.GetRequestID(r.Context()) == "PRIVATE_LEGACY_ID" {
			t.Error("legacy middleware replaced canonical ID")
		}
		w.WriteHeader(204)
	}))})
	req := httptest.NewRequest("POST", "/internal/agent-tools/v1/check", nil)
	req.Header.Set("X-Request-ID", "PRIVATE_LEGACY_ID")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	var entry logger.Entry
	_ = json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &entry)
	if rec.Header().Get("X-Request-ID") != entry.RequestID {
		t.Fatal("response ID differs from completion ID")
	}
}

func TestComposedObserverCountsFinalConditionalStatusOnce(t *testing.T) {
	rt, _ := observability.New(context.Background(), observability.DefaultConfig())
	defer rt.Shutdown(context.Background())
	var logs bytes.Buffer
	prometheus := metrics.New()
	fixed := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: &logs}), ResponseTransforms: true, Metrics: prometheus, AgentToolsHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "fixed") })})
	req := httptest.NewRequest("GET", "/internal/agent-tools/v1/fixed", nil)
	rec := httptest.NewRecorder()
	fixed.ServeHTTP(rec, req)
	req = httptest.NewRequest("GET", "/internal/agent-tools/v1/fixed", nil)
	req.Header.Set("If-None-Match", rec.Header().Get("ETag"))
	rec = httptest.NewRecorder()
	fixed.ServeHTTP(rec, req)
	if rec.Code != 304 {
		t.Fatalf("wire status %d", rec.Code)
	}
	lines := bytes.Split(bytes.TrimSpace(logs.Bytes()), []byte("\n"))
	var e logger.Entry
	_ = json.Unmarshal(lines[len(lines)-1], &e)
	if e.Fields["http.response.status_code"] != float64(304) {
		t.Fatalf("observed status %s", lines[len(lines)-1])
	}
	if len(lines) != 2 {
		t.Fatalf("duplicate completions: %s", logs.String())
	}
	metricResponse := httptest.NewRecorder()
	prometheus.Handler().ServeHTTP(metricResponse, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(metricResponse.Body.String(), `omp_http_requests_total{endpoint="/internal/agent-tools/v1/",method="GET"} 2`) {
		t.Fatalf("Prometheus request count changed: %s", metricResponse.Body.String())
	}
}
