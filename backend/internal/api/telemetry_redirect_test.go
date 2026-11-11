package api

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestRouterRedirectsNeverExportUnregisteredPath(t *testing.T) {
	var payloads bytes.Buffer
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		payloads.Write(data)
		w.Header().Set("Content-Type", "application/x-protobuf")
	}))
	defer collector.Close()
	c := observability.DefaultConfig()
	c.Endpoint = collector.URL
	c.LogsExporter = "otlp"
	rt, err := observability.New(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Shutdown(context.Background())
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: io.Discard}), AgentToolsHandler: http.NotFoundHandler()})
	for _, path := range []string{"//PRIVATE_REDIRECT_CANARY", "/PRIVATE_REDIRECT_CANARY/../health", "/internal/agent-tools/v1//PRIVATE_REDIRECT_CANARY", "/api/v1/tracks/PRIVATE_REDIRECT_CANARY/metadata-override"} {
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	}
	if err := rt.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(payloads.Bytes(), []byte("PRIVATE_REDIRECT_CANARY")) {
		t.Fatal("mux redirect returned an unregistered raw path as a pattern")
	}
}
