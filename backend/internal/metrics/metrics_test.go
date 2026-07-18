package metrics

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetrics_RecordRequest(t *testing.T) {
	m := New()

	m.RecordRequest("GET", "/api/v1/health", 200, 100*time.Millisecond)
	m.RecordRequest("GET", "/api/v1/health", 200, 150*time.Millisecond)
	m.RecordRequest("GET", "/api/v1/health", 500, 50*time.Millisecond)

	// Request the metrics handler
	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, "omp_http_requests_total") {
		t.Error("expected omp_http_requests_total metric")
	}
	if !strings.Contains(body, "omp_http_request_duration_seconds") {
		t.Error("expected omp_http_request_duration_seconds metric")
	}
	if !strings.Contains(body, `omp_http_request_duration_seconds_bucket{endpoint="/api/v1/health",method="GET",le="10"}`) {
		t.Error("expected HTTP duration 10-second bucket")
	}
	if strings.Contains(body, `omp_http_request_duration_seconds_bucket{endpoint="/api/v1/health",method="GET",le="30"}`) {
		t.Error("HTTP duration histogram must not include research latency buckets")
	}
}

func TestMetrics_WSConnections(t *testing.T) {
	m := New()

	m.IncWSConnections()
	m.IncWSConnections()
	m.DecWSConnections()

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, "omp_websocket_connections_active 1") {
		t.Errorf("expected omp_websocket_connections_active 1, got:\n%s", body)
	}
}

func TestMetrics_DownloadQueueLength(t *testing.T) {
	m := New()

	m.SetDownloadQueueLength(5)

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, "omp_download_queue_length 5") {
		t.Errorf("expected omp_download_queue_length 5, got:\n%s", body)
	}
}

func TestMetrics_Uptime(t *testing.T) {
	m := New()

	// Wait a bit to ensure uptime is > 0
	time.Sleep(10 * time.Millisecond)

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, "omp_uptime_seconds") {
		t.Error("expected omp_uptime_seconds metric")
	}
}

func TestMetrics_EndpointNormalization(t *testing.T) {
	m := New()

	// These should be normalized to the same endpoint
	m.RecordRequest("GET", "/api/v1/tracks/123e4567-e89b-12d3-a456-426614174000", 200, 10*time.Millisecond)
	m.RecordRequest("GET", "/api/v1/tracks/550e8400-e29b-41d4-a716-446655440000", 200, 10*time.Millisecond)

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	// Should have normalized the UUID to {id}
	if !strings.Contains(body, "/api/v1/tracks/{id}") {
		t.Errorf("expected normalized endpoint /api/v1/tracks/{id}, got:\n%s", body)
	}
}

func TestMetricsMiddleware(t *testing.T) {
	m := New()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	wrappedHandler := MetricsMiddleware(m)(handler)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/test", nil)
	w := httptest.NewRecorder()

	wrappedHandler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	// Check that metrics were recorded
	metricsHandler := m.Handler()
	metricsReq := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	metricsW := httptest.NewRecorder()

	metricsHandler(metricsW, metricsReq)

	body := metricsW.Body.String()

	if !strings.Contains(body, "/api/v1/test") {
		t.Errorf("expected endpoint /api/v1/test in metrics, got:\n%s", body)
	}
}

func TestMetrics_CustomCounter(t *testing.T) {
	m := New()

	m.IncCounter("cache_hits")
	m.IncCounter("cache_hits")
	m.IncCounter("cache_misses")

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, `omp_counter{name="cache_hits"} 2`) {
		t.Errorf("expected cache_hits counter = 2, got:\n%s", body)
	}
}

func TestMetrics_ResearchObservationsAreAllowlistedAndCoverLongWork(t *testing.T) {
	m := New()
	m.ObserveResearchCreate("https://query.example/private-token", 75*time.Second)
	m.ObserveResearchSnapshot("user-123", "job-456", "https://degradation.example", "raw-prompt", "revision-999", 80*time.Second, true)
	m.ObserveResearchMutation("cancel?job=secret", "credential-value")
	m.ObserveResearchReview("https://candidate.example", "user-id")
	m.ObserveResearchToolCalls(3)
	m.ObserveResearchModelAttempt("model-name", "api-key", true, 90*time.Second)

	w := httptest.NewRecorder()
	m.Handler()(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := w.Body.String()

	for _, expected := range []string{
		`omp_research_job_creates_total{outcome="unknown"} 1`,
		`omp_research_job_status_observations_total{status="unknown"} 1`,
		`omp_research_mutations_total{operation="unknown",outcome="unknown"} 1`,
		`omp_research_terminal_model_attempt_duration_seconds_bucket{stage="unknown",status="unknown",repair="true",le="120"} 1`,
		`omp_research_baseline_duration_seconds_bucket{outcome="unknown",le="120"} 1`,
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("metrics missing %q:\n%s", expected, body)
		}
	}
	for _, sensitive := range []string{"query.example", "private-token", "user-123", "job-456", "degradation.example", "raw-prompt", "revision-999", "candidate.example", "credential-value", "model-name", "api-key"} {
		if strings.Contains(body, sensitive) {
			t.Errorf("metrics leaked %q:\n%s", sensitive, body)
		}
	}
}

func TestMetrics_CustomGauge(t *testing.T) {
	m := New()

	m.SetGauge("active_downloads", 3.0)

	handler := m.Handler()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()

	handler(w, req)

	body := w.Body.String()

	if !strings.Contains(body, `omp_gauge{name="active_downloads"}`) {
		t.Errorf("expected active_downloads gauge, got:\n%s", body)
	}
}
