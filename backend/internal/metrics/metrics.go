package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Metrics holds all application metrics
type Metrics struct {
	mu sync.RWMutex

	// Request metrics
	requestCount    map[string]*uint64    // endpoint:method -> count
	requestDuration map[string]*Histogram // endpoint:method -> duration histogram
	requestErrors   map[string]*uint64    // endpoint:status_class -> count

	// Application metrics
	activeWSConnections int64
	downloadQueueLength int64

	// Research metrics use only fixed, allowlisted labels. They deliberately do
	// not retain request content, IDs, providers, URLs, or credentials.
	researchCreates       map[string]*uint64
	researchBaseline      map[string]*Histogram
	researchStatuses      map[string]*uint64
	researchTerminals     map[string]*uint64
	researchDegradations  map[string]*uint64
	researchMutations     map[string]*uint64
	researchReviews       map[string]*uint64
	researchRevisions     map[string]*uint64
	researchTimeToLatest  map[string]*Histogram
	researchToolCalls     *Histogram
	researchModelAttempts map[string]*Histogram

	// Custom gauges and counters
	gauges   map[string]float64
	counters map[string]*uint64

	startTime time.Time
}

// Histogram tracks value distributions
type Histogram struct {
	mu         sync.Mutex
	count      uint64
	sum        float64
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

// newResearchHistogram creates a histogram with buckets suitable for bounded
// research latency measurements.
func newResearchHistogram() *Histogram {
	buckets := []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 90, 120}
	return &Histogram{buckets: buckets, bucketVals: make([]uint64, len(buckets))}
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
		requestCount:          make(map[string]*uint64),
		requestDuration:       make(map[string]*Histogram),
		requestErrors:         make(map[string]*uint64),
		researchCreates:       make(map[string]*uint64),
		researchBaseline:      make(map[string]*Histogram),
		researchStatuses:      make(map[string]*uint64),
		researchTerminals:     make(map[string]*uint64),
		researchDegradations:  make(map[string]*uint64),
		researchMutations:     make(map[string]*uint64),
		researchReviews:       make(map[string]*uint64),
		researchRevisions:     make(map[string]*uint64),
		researchTimeToLatest:  make(map[string]*Histogram),
		researchToolCalls:     NewHistogram(),
		researchModelAttempts: make(map[string]*Histogram),
		gauges:                make(map[string]float64),
		counters:              make(map[string]*uint64),
		startTime:             time.Now(),
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

func researchOutcomeLabel(value string) string {
	switch value {
	case "created", "success", "invalid_request", "baseline_unavailable", "conflict", "not_found", "capacity_exhausted", "unavailable":
		return value
	default:
		return "unknown"
	}
}

func researchStatusLabel(value string) string {
	switch value {
	case "queued", "running", "cancel_requested", "completed", "degraded", "cancelled": //nolint:misspell // Preserve the persisted status contract.
		return value
	default:
		return "unknown"
	}
}

func researchTerminalLabel(value string) string {
	switch value {
	case "completed", "degraded", "cancelled": //nolint:misspell // Preserve the persisted status contract.
		return value
	default:
		return "unknown"
	}
}

func researchDegradationLabel(value string) string {
	switch value {
	case "model_disabled", "model_unavailable", "budget_exhausted", "transient", "timeout", "runner_terminal", "validation_rejected", "safety_rejected", "enhancement_rejected", "lease_expired", "no_candidates":
		return value
	default:
		return "unknown"
	}
}

func researchMutationLabel(value string) string {
	switch value {
	case "cancel", "retry":
		return value
	default:
		return "unknown"
	}
}

func researchReviewActionLabel(value string) string {
	switch value {
	case "accepted", "overridden":
		return value
	default:
		return "unknown"
	}
}

func researchStageLabel(value string) string {
	switch value {
	case "baseline", "direct_judge", "deep_agent":
		return value
	default:
		return "unknown"
	}
}

func researchRevisionKindLabel(value string) string {
	switch value {
	case "baseline", "enhancement":
		return value
	default:
		return "unknown"
	}
}

func researchModelStatusLabel(value string) string {
	switch value {
	case "success", "parse_error", "transport_error":
		return value
	default:
		return "unknown"
	}
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

// ObserveResearchCreate records a bounded create outcome and baseline latency.
func (m *Metrics) ObserveResearchCreate(outcome string, baselineLatency time.Duration) {
	outcome = researchOutcomeLabel(outcome)
	m.incrementResearchCounter(m.researchCreates, outcome)
	if baselineLatency > 0 {
		m.observeResearchHistogram(m.researchBaseline, outcome, baselineLatency.Seconds())
	}
}

// ObserveResearchSnapshot records safe state derived from an immutable snapshot.
func (m *Metrics) ObserveResearchSnapshot(status, terminalStatus, degradation, revisionStage, revisionKind string, timeToLatest time.Duration, hasTimeToLatest bool) {
	m.incrementResearchCounter(m.researchStatuses, researchStatusLabel(status))
	if terminalStatus != "" {
		m.incrementResearchCounter(m.researchTerminals, researchTerminalLabel(terminalStatus))
	}
	if degradation != "" {
		m.incrementResearchCounter(m.researchDegradations, researchDegradationLabel(degradation))
	}
	stage, kind := researchStageLabel(revisionStage), researchRevisionKindLabel(revisionKind)
	m.incrementResearchCounter(m.researchRevisions, stage+":"+kind)
	if hasTimeToLatest && timeToLatest >= 0 {
		m.observeResearchHistogram(m.researchTimeToLatest, stage+":"+kind, timeToLatest.Seconds())
	}
}

// ObserveResearchMutation records cancel and retry outcomes with fixed labels.
func (m *Metrics) ObserveResearchMutation(operation, outcome string) {
	m.incrementResearchCounter(m.researchMutations, researchMutationLabel(operation)+":"+researchOutcomeLabel(outcome))
}

// ObserveResearchReview records review actions and outcomes with fixed labels.
func (m *Metrics) ObserveResearchReview(action, outcome string) {
	m.incrementResearchCounter(m.researchReviews, researchReviewActionLabel(action)+":"+researchOutcomeLabel(outcome))
}

// ObserveResearchToolCalls records only the aggregate count supplied by safe terminal telemetry.
func (m *Metrics) ObserveResearchToolCalls(calls int) {
	if calls < 0 {
		return
	}
	m.researchToolCalls.Observe(float64(calls))
}

// ObserveResearchModelAttempt records model-attempt duration without a model or worker identity.
func (m *Metrics) ObserveResearchModelAttempt(stage, status string, repair bool, duration time.Duration) {
	if duration < 0 {
		return
	}
	key := researchStageLabel(stage) + ":" + researchModelStatusLabel(status) + ":" + strconv.FormatBool(repair)
	m.observeResearchHistogram(m.researchModelAttempts, key, duration.Seconds())
}

func (m *Metrics) incrementResearchCounter(values map[string]*uint64, key string) {
	m.mu.Lock()
	if values[key] == nil {
		var zero uint64
		values[key] = &zero
	}
	counter := values[key]
	m.mu.Unlock()
	atomic.AddUint64(counter, 1)
}

func (m *Metrics) observeResearchHistogram(values map[string]*Histogram, key string, value float64) {
	m.mu.Lock()
	if values[key] == nil {
		values[key] = newResearchHistogram()
	}
	histogram := values[key]
	m.mu.Unlock()
	histogram.Observe(value)
}

// Handler returns an HTTP handler for the metrics endpoint
func (m *Metrics) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

		var sb strings.Builder

		// Uptime
		uptime := time.Since(m.startTime).Seconds()
		sb.WriteString("# HELP omp_uptime_seconds Time since the server started\n")
		sb.WriteString("# TYPE omp_uptime_seconds gauge\n")
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

		writeResearchMetrics(&sb, m)

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

func writeResearchMetrics(sb *strings.Builder, m *Metrics) {
	writeResearchCounter := func(name, help string, values map[string]*uint64, labels ...string) {
		if len(values) == 0 {
			return
		}
		sb.WriteString("# HELP " + name + " " + help + "\n# TYPE " + name + " counter\n")
		keys := sortedMetricKeys(values)
		for _, key := range keys {
			writeMetricLabels(sb, name, labels, strings.Split(key, ":"))
			sb.WriteString(fmt.Sprintf(" %d\n", atomic.LoadUint64(values[key])))
		}
		sb.WriteString("\n")
	}
	writeResearchHistogram := func(name, help string, values map[string]*Histogram, labels ...string) {
		if len(values) == 0 {
			return
		}
		sb.WriteString("# HELP " + name + " " + help + "\n# TYPE " + name + " histogram\n")
		for _, key := range sortedMetricKeys(values) {
			histogram := values[key]
			histogram.mu.Lock()
			for index, bucket := range histogram.buckets {
				writeMetricLabels(sb, name+"_bucket", append(labels, "le"), append(strings.Split(key, ":"), strconv.FormatFloat(bucket, 'g', -1, 64)))
				sb.WriteString(fmt.Sprintf(" %d\n", histogram.bucketVals[index]))
			}
			writeMetricLabels(sb, name+"_bucket", append(labels, "le"), append(strings.Split(key, ":"), "+Inf"))
			sb.WriteString(fmt.Sprintf(" %d\n", histogram.count))
			writeMetricLabels(sb, name+"_sum", labels, strings.Split(key, ":"))
			sb.WriteString(fmt.Sprintf(" %f\n", histogram.sum))
			writeMetricLabels(sb, name+"_count", labels, strings.Split(key, ":"))
			sb.WriteString(fmt.Sprintf(" %d\n", histogram.count))
			histogram.mu.Unlock()
		}
		sb.WriteString("\n")
	}

	writeResearchCounter("omp_research_job_creates_total", "Research job create outcomes", m.researchCreates, "outcome")
	writeResearchHistogram("omp_research_baseline_duration_seconds", "Research baseline build latency", m.researchBaseline, "outcome")
	writeResearchCounter("omp_research_job_status_observations_total", "Research job status observations", m.researchStatuses, "status")
	writeResearchCounter("omp_research_terminal_observations_total", "Research terminal status observations", m.researchTerminals, "status")
	writeResearchCounter("omp_research_degradations_total", "Research degradation observations", m.researchDegradations, "code")
	writeResearchCounter("omp_research_mutations_total", "Research cancel and retry outcomes", m.researchMutations, "operation", "outcome")
	writeResearchCounter("omp_research_reviews_total", "Research review outcomes", m.researchReviews, "action", "outcome")
	writeResearchCounter("omp_research_latest_revision_observations_total", "Latest validated research revision observations", m.researchRevisions, "stage", "kind")
	writeResearchHistogram("omp_research_time_to_latest_revision_seconds", "Time from job creation to latest validated revision", m.researchTimeToLatest, "stage", "kind")
	if m.researchToolCalls != nil {
		writeResearchHistogram("omp_research_terminal_tool_calls", "Tool calls reported by safe terminal telemetry", map[string]*Histogram{"": m.researchToolCalls})
	}
	writeResearchHistogram("omp_research_terminal_model_attempt_duration_seconds", "Model attempt duration reported by safe terminal telemetry", m.researchModelAttempts, "stage", "status", "repair")
}

func sortedMetricKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func writeMetricLabels(sb *strings.Builder, name string, labelNames, labelValues []string) {
	sb.WriteString(name)
	if len(labelNames) == 0 {
		return
	}
	sb.WriteString("{")
	for index, labelName := range labelNames {
		if index > 0 {
			sb.WriteString(",")
		}
		value := "unknown"
		if index < len(labelValues) {
			value = labelValues[index]
		}
		sb.WriteString(labelName + "=\"" + value + "\"")
	}
	sb.WriteString("}")
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
