package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestRouterEnvEndpointHeadersAndResource(t *testing.T) {
	var mu sync.Mutex
	paths := map[string]int{}
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Telemetry-Test") != "operator-value" {
			t.Errorf("export headers %v", r.Header)
		}
		if r.Header.Get("Content-Type") != "application/x-protobuf" {
			t.Errorf("content type %s", r.Header.Get("Content-Type"))
		}
		_, _ = io.Copy(io.Discard, r.Body)
		mu.Lock()
		paths[r.URL.Path]++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/x-protobuf")
	}))
	defer collector.Close()
	for k, v := range map[string]string{"OTEL_SDK_DISABLED": "false", "OTEL_SERVICE_NAME": "soundq-env-test", "OTEL_RESOURCE_ATTRIBUTES": "service.version=wire-v,service.instance.id=wire-i,deployment.environment.name=production", "OTEL_TRACES_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp", "OTEL_METRICS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_ENDPOINT": collector.URL + "/prefix", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": collector.URL + "/custom-trace", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "", "OTEL_EXPORTER_OTLP_HEADERS": "X-Telemetry-Test=operator-value", "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf", "OTEL_TRACES_SAMPLER": "always_on", "OTEL_TRACES_SAMPLER_ARG": ""} {
		t.Setenv(k, v)
	}
	c, err := observability.ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	rt, err := observability.New(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Shutdown(context.Background())
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: io.Discard}), ResponseTransforms: true})
	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/health", nil))
	if err := rt.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, path := range []string{"/custom-trace", "/prefix/v1/logs", "/prefix/v1/metrics"} {
		if paths[path] != 1 {
			t.Fatalf("export paths %v", paths)
		}
	}
}
