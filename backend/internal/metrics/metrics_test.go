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
