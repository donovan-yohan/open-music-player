package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	logpb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	metricpb "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	tracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/protobuf/proto"
)

func TestSmokeRunsActualRouterAndDrainsAllSignals(t *testing.T) {
	var mu sync.Mutex
	spans, logs, metrics := 0, 0, 0
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/v1/traces":
			var message tracepb.ExportTraceServiceRequest
			if err := proto.Unmarshal(data, &message); err != nil {
				t.Error(err)
			}
			for _, resource := range message.ResourceSpans {
				for _, scope := range resource.ScopeSpans {
					spans += len(scope.Spans)
				}
			}
		case "/v1/logs":
			var message logpb.ExportLogsServiceRequest
			if err := proto.Unmarshal(data, &message); err != nil {
				t.Error(err)
			}
			for _, resource := range message.ResourceLogs {
				for _, scope := range resource.ScopeLogs {
					logs += len(scope.LogRecords)
				}
			}
		case "/v1/metrics":
			var message metricpb.ExportMetricsServiceRequest
			if err := proto.Unmarshal(data, &message); err != nil {
				t.Error(err)
			}
			for _, resource := range message.ResourceMetrics {
				for _, scope := range resource.ScopeMetrics {
					metrics += len(scope.Metrics)
				}
			}
		default:
			t.Errorf("unexpected export %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/x-protobuf")
	}))
	defer collector.Close()
	for k, v := range map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": collector.URL, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "", "OTEL_TRACES_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp", "OTEL_METRICS_EXPORTER": "otlp", "OTEL_SDK_DISABLED": "false", "OTEL_TRACES_SAMPLER": "always_on", "OTEL_RESOURCE_ATTRIBUTES": "deployment.environment.name=development,service.instance.id=smoke-test"} {
		t.Setenv(k, v)
	}
	if err := run(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if spans != 3 || logs != 3 || metrics != 2 {
		t.Fatalf("received spans=%d logs=%d metric instruments=%d, want 3/3/2", spans, logs, metrics)
	}
}
