package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Metrics holds all application metrics
type Metrics struct {
	mu sync.RWMutex

	// Request metrics
	requestCount    map[string]*uint64 // endpoint:method -> count
	requestDuration map[string]*Histogram // endpoint:method -> duration histogram
	requestErrors   map[string]*uint64 // endpoint:status_class -> count

	// Application metrics
	activeWSConnections int64
	downloadQueueLength int64

	// Custom gauges and counters
	gauges   map[string]float64
	counters map[string]*uint64

	startTime time.Time
}

// Histogram tracks value distributions
type Histogram struct {
	mu    sync.Mutex
	count uint64
	sum   float64
	// Buckets: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s
	buckets    []float64
	bucketVals []uint64
}

// NewHistogram creates a new histogram with default buckets
func NewHistogram() *Histogram {
	return &Histogram{
		buckets:    []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
		bucketVals: make([]uint64, 11),
	}
}

// Observe records a value
func (h *Histogram) Observe(v float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.count++
	h.sum += v
	for i, b := range h.buckets {
		if v <= b {
			h.bucketVals[i]++
		}
	}
}

// New creates a new Metrics instance
func New() *Metrics {
	return &Metrics{
		requestCount:    make(map[string]*uint64),
		requestDuration: make(map[string]*Histogram),
		requestErrors:   make(map[string]*uint64),
		gauges:          make(map[string]float64),
		counters:        make(map[string]*uint64),
		startTime:       time.Now(),
	}
}

// global metrics instance
var defaultMetrics = New()

// Default returns the default metrics instance
func Default() *Metrics {
	return defaultMetrics
}

// RecordRequest records a request
func (m *Metrics) RecordRequest(method, path string, statusCode int, duration time.Duration) {
	key := fmt.Sprintf("%s:%s", normalizeEndpoint(path), method)

	m.mu.Lock()
	if m.requestCount[key] == nil {
		var zero uint64
		m.requestCount[key] = &zero
	}
	if m.requestDuration[key] == nil {
		m.requestDuration[key] = NewHistogram()
	}
	m.mu.Unlock()

	atomic.AddUint64(m.requestCount[key], 1)

	m.mu.RLock()
	m.requestDuration[key].Observe(duration.Seconds())
	m.mu.RUnlock()

	// Track errors by status class
	if statusCode >= 400 {
		errorKey := fmt.Sprintf("%s:%d", key, statusCode/100*100)
		m.mu.Lock()
		if m.requestErrors[errorKey] == nil {
			var zero uint64
			m.requestErrors[errorKey] = &zero
		}
		m.mu.Unlock()
		atomic.AddUint64(m.requestErrors[errorKey], 1)
	}
}

// normalizeEndpoint normalizes an endpoint path for metrics (removes IDs)
func normalizeEndpoint(path string) string {
	// Replace UUIDs and numeric IDs with placeholders
	parts := strings.Split(path, "/")
	for i, part := range parts {
		// UUID pattern (simplified)
		if len(part) == 36 && strings.Count(part, "-") == 4 {
			parts[i] = "{id}"
		} else if len(part) > 0 && isNumeric(part) {
			parts[i] = "{id}"
		}
	}
	return strings.Join(parts, "/")
}

func isNumeric(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// SetWSConnections sets the active WebSocket connections count
func (m *Metrics) SetWSConnections(count int64) {
	atomic.StoreInt64(&m.activeWSConnections, count)
}

// IncWSConnections increments WebSocket connections
func (m *Metrics) IncWSConnections() {
	atomic.AddInt64(&m.activeWSConnections, 1)
}

// DecWSConnections decrements WebSocket connections
func (m *Metrics) DecWSConnections() {
	atomic.AddInt64(&m.activeWSConnections, -1)
}

// SetDownloadQueueLength sets the download queue length
func (m *Metrics) SetDownloadQueueLength(length int64) {
	atomic.StoreInt64(&m.downloadQueueLength, length)
}

// SetGauge sets a gauge value
func (m *Metrics) SetGauge(name string, value float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gauges[name] = value
}

// IncCounter increments a counter
func (m *Metrics) IncCounter(name string) {
	m.mu.Lock()
	if m.counters[name] == nil {
		var zero uint64
		m.counters[name] = &zero
	}
	m.mu.Unlock()
	atomic.AddUint64(m.counters[name], 1)
}

// Handler returns an HTTP handler for the metrics endpoint
func (m *Metrics) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

		var sb strings.Builder

		// Uptime
		uptime := time.Since(m.startTime).Seconds()
		sb.WriteString(fmt.Sprintf("# HELP omp_uptime_seconds Time since the server started\n"))
		sb.WriteString(fmt.Sprintf("# TYPE omp_uptime_seconds gauge\n"))
		sb.WriteString(fmt.Sprintf("omp_uptime_seconds %f\n\n", uptime))

		// Active WebSocket connections
		sb.WriteString("# HELP omp_websocket_connections_active Active WebSocket connections\n")
		sb.WriteString("# TYPE omp_websocket_connections_active gauge\n")
		sb.WriteString(fmt.Sprintf("omp_websocket_connections_active %d\n\n", atomic.LoadInt64(&m.activeWSConnections)))

		// Download queue length
		sb.WriteString("# HELP omp_download_queue_length Current download queue length\n")
		sb.WriteString("# TYPE omp_download_queue_length gauge\n")
		sb.WriteString(fmt.Sprintf("omp_download_queue_length %d\n\n", atomic.LoadInt64(&m.downloadQueueLength)))

		// Request counts
		m.mu.RLock()
		if len(m.requestCount) > 0 {
			sb.WriteString("# HELP omp_http_requests_total Total HTTP requests\n")
			sb.WriteString("# TYPE omp_http_requests_total counter\n")
			keys := make([]string, 0, len(m.requestCount))
			for k := range m.requestCount {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, key := range keys {
				parts := strings.SplitN(key, ":", 2)
				if len(parts) == 2 {
					count := atomic.LoadUint64(m.requestCount[key])
					sb.WriteString(fmt.Sprintf("omp_http_requests_total{endpoint=\"%s\",method=\"%s\"} %d\n", parts[0], parts[1], count))
				}
			}
			sb.WriteString("\n")
		}

		// Request duration histograms
		if len(m.requestDuration) > 0 {
			sb.WriteString("# HELP omp_http_request_duration_seconds HTTP request latency\n")
			sb.WriteString("# TYPE omp_http_request_duration_seconds histogram\n")
			keys := make([]string, 0, len(m.requestDuration))
			for k := range m.requestDuration {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, key := range keys {
				parts := strings.SplitN(key, ":", 2)
				if len(parts) == 2 {
					h := m.requestDuration[key]
					h.mu.Lock()
					for i, bucket := range h.buckets {
						sb.WriteString(fmt.Sprintf("omp_http_request_duration_seconds_bucket{endpoint=\"%s\",method=\"%s\",le=\"%g\"} %d\n", parts[0], parts[1], bucket, h.bucketVals[i]))
					}
					sb.WriteString(fmt.Sprintf("omp_http_request_duration_seconds_bucket{endpoint=\"%s\",method=\"%s\",le=\"+Inf\"} %d\n", parts[0], parts[1], h.count))
					sb.WriteString(fmt.Sprintf("omp_http_request_duration_seconds_sum{endpoint=\"%s\",method=\"%s\"} %f\n", parts[0], parts[1], h.sum))
					sb.WriteString(fmt.Sprintf("omp_http_request_duration_seconds_count{endpoint=\"%s\",method=\"%s\"} %d\n", parts[0], parts[1], h.count))
					h.mu.Unlock()
				}
			}
			sb.WriteString("\n")
		}

		// Error counts
		if len(m.requestErrors) > 0 {
			sb.WriteString("# HELP omp_http_errors_total Total HTTP errors by status class\n")
			sb.WriteString("# TYPE omp_http_errors_total counter\n")
			keys := make([]string, 0, len(m.requestErrors))
			for k := range m.requestErrors {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, key := range keys {
				// key format: endpoint:method:statusClass
				parts := strings.Split(key, ":")
				if len(parts) >= 3 {
					count := atomic.LoadUint64(m.requestErrors[key])
					sb.WriteString(fmt.Sprintf("omp_http_errors_total{endpoint=\"%s\",method=\"%s\",status_class=\"%sxx\"} %d\n", parts[0], parts[1], parts[2][:1], count))
				}
			}
			sb.WriteString("\n")
		}

		// Custom gauges
		if len(m.gauges) > 0 {
			sb.WriteString("# HELP omp_gauge Custom gauge metrics\n")
			sb.WriteString("# TYPE omp_gauge gauge\n")
			keys := make([]string, 0, len(m.gauges))
			for k := range m.gauges {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, name := range keys {
				sb.WriteString(fmt.Sprintf("omp_gauge{name=\"%s\"} %f\n", name, m.gauges[name]))
			}
			sb.WriteString("\n")
		}

		// Custom counters
		if len(m.counters) > 0 {
			sb.WriteString("# HELP omp_counter Custom counter metrics\n")
			sb.WriteString("# TYPE omp_counter counter\n")
			keys := make([]string, 0, len(m.counters))
			for k := range m.counters {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, name := range keys {
				count := atomic.LoadUint64(m.counters[name])
				sb.WriteString(fmt.Sprintf("omp_counter{name=\"%s\"} %d\n", name, count))
			}
		}
		m.mu.RUnlock()

		w.Write([]byte(sb.String()))
	}
}

// MetricsMiddleware creates middleware that records request metrics
func MetricsMiddleware(m *Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()

			// Wrap response writer to capture status
			wrapped := &statusResponseWriter{
				ResponseWriter: w,
				statusCode:     http.StatusOK,
			}

			next.ServeHTTP(wrapped, r)

			duration := time.Since(start)
			m.RecordRequest(r.Method, r.URL.Path, wrapped.statusCode, duration)
		})
	}
}

type statusResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (w *statusResponseWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}
