package api

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	logpb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	metricpb "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	tracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/protobuf/proto"

	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestRouterOTLPExportPrivacyAndCorrelation(t *testing.T) {
	for _, environment := range []string{"development", "production"} {
		t.Run(environment, func(t *testing.T) {
			var mu sync.Mutex
			payloads := map[string][][]byte{}
			collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				data, _ := io.ReadAll(r.Body)
				mu.Lock()
				payloads[r.URL.Path] = append(payloads[r.URL.Path], data)
				mu.Unlock()
				w.Header().Set("Content-Type", "application/x-protobuf")
			}))
			defer collector.Close()
			cfg := observability.DefaultConfig()
			cfg.Endpoint = collector.URL
			cfg.TracesExporter = "otlp"
			cfg.LogsExporter = "otlp"
			cfg.MetricsExporter = "otlp"
			cfg.Environment = environment
			cfg.ServiceVersion = "test-version"
			cfg.InstanceID = "test-instance"
			runtime, err := observability.New(context.Background(), cfg)
			if err != nil {
				t.Fatal(err)
			}
			var stdout bytes.Buffer
			log := runtime.Logger(&logger.Config{Output: &stdout, Level: logger.LevelInfo})
			router := NewRouterWithConfig(&RouterConfig{Telemetry: runtime, Logger: log})
			server := httptest.NewServer(router)
			defer server.Close()
			canary := "PRIVACY_CANARY_do_not_export"
			req, _ := http.NewRequestWithContext(t.Context(), "PUT", server.URL+"/api/v1/tracks/"+canary+"/metadata-override?url=https://signed.invalid/?X-Amz-Signature="+canary, strings.NewReader(canary))
			req.Header.Set("Authorization", canary)
			req.Header.Set("Cookie", canary)
			req.Header.Set("User-Agent", canary)
			req.Header.Set("X-Trace-ID", canary)
			req.Header.Set("X-Request-ID", canary)
			req.Header.Set("Baggage", "secret="+canary)
			req.Header.Set("Tracestate", "secret="+canary)
			req.Header.Set("Traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")
			res, err := server.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			_, _ = io.ReadAll(res.Body)
			if res.StatusCode != 401 {
				t.Fatalf("status %d", res.StatusCode)
			}
			requestID := res.Header.Get("X-Request-ID")
			if requestID == "" || requestID == canary {
				t.Fatalf("unsafe request ID %q", requestID)
			}
			// Arbitrary legacy fields/messages/errors are stdout-only, never bridged.
			log.Info(context.Background(), canary, map[string]interface{}{"url": canary, "user_id": canary})
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if err := runtime.Shutdown(ctx); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			defer mu.Unlock()
			for _, path := range []string{"/v1/traces", "/v1/logs", "/v1/metrics"} {
				if len(payloads[path]) == 0 {
					t.Fatalf("missing %s", path)
				}
				for _, data := range payloads[path] {
					if bytes.Contains(data, []byte(canary)) {
						t.Fatalf("privacy leak in %s", path)
					}
				}
			}
			traces := new(tracepb.ExportTraceServiceRequest)
			if err := proto.Unmarshal(payloads["/v1/traces"][0], traces); err != nil {
				t.Fatal(err)
			}
			if len(traces.ResourceSpans) != 1 || len(traces.ResourceSpans[0].ScopeSpans[0].Spans) != 1 {
				t.Fatalf("duplicate spans %v", traces)
			}
			span := traces.ResourceSpans[0].ScopeSpans[0].Spans[0]
			if span.Name != "PUT /api/v1/tracks/{track_id}/metadata-override" {
				t.Fatalf("route %q", span.Name)
			}
			if hex.EncodeToString(span.TraceId) != "0123456789abcdef0123456789abcdef" {
				t.Fatalf("traceparent lost %x", span.TraceId)
			}
			logs := new(logpb.ExportLogsServiceRequest)
			_ = proto.Unmarshal(payloads["/v1/logs"][0], logs)
			records := logs.ResourceLogs[0].ScopeLogs[0].LogRecords
			if len(records) != 1 {
				t.Fatalf("completion count %d", len(records))
			}
			record := records[0]
			if !bytes.Equal(record.TraceId, span.TraceId) || !bytes.Equal(record.SpanId, span.SpanId) {
				t.Fatal("log trace correlation lost")
			}
			resource := map[string]string{}
			for _, a := range logs.ResourceLogs[0].Resource.Attributes {
				resource[a.Key] = a.Value.GetStringValue()
			}
			if resource["deployment.environment.name"] != environment || resource["service.version"] != "test-version" || resource["service.instance.id"] != "test-instance" {
				t.Fatalf("resource %v", resource)
			}
			metrics := new(metricpb.ExportMetricsServiceRequest)
			_ = proto.Unmarshal(payloads["/v1/metrics"][0], metrics)
			names := map[string]bool{}
			for _, sm := range metrics.ResourceMetrics[0].ScopeMetrics {
				for _, m := range sm.Metrics {
					names[m.Name] = true
				}
			}
			if !names["http.server.request.duration"] || !names["http.server.request.count"] {
				t.Fatalf("HTTP metrics %v", names)
			}
			var entry logger.Entry
			_ = json.Unmarshal(bytes.Split(stdout.Bytes(), []byte("\n"))[0], &entry)
			if entry.RequestID != requestID || entry.TraceID != hex.EncodeToString(span.TraceId) || entry.SpanID != hex.EncodeToString(span.SpanId) {
				t.Fatalf("stdout correlation %s", stdout.String())
			}
		})
	}
}
