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

func TestRouterRemoteLogsExcludeRecoveryAndLegacyErrors(t *testing.T) {
	var payloads bytes.Buffer
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		if r.URL.Path == "/v1/logs" {
			payloads.Write(data)
		}
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
	log := rt.Logger(&logger.Config{Output: io.Discard})
	router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: log, ResponseTransforms: true, AgentToolsHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Error(logger.WithUserID(r.Context(), "PRIVATE_USER_CANARY"), "PRIVATE_MESSAGE_CANARY", map[string]interface{}{"url": "https://signed.invalid/?secret=PRIVATE_URL_CANARY"}, io.ErrUnexpectedEOF)
		panic("PRIVATE_PANIC_CANARY")
	})})
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest("GET", "/internal/agent-tools/v1/PRIVATE_PATH_CANARY", nil))
	if rec.Code != 500 {
		t.Fatalf("recovery status %d", rec.Code)
	}
	if err := rt.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(payloads.Bytes(), []byte("PRIVATE_")) || bytes.Contains(payloads.Bytes(), []byte(io.ErrUnexpectedEOF.Error())) {
		t.Fatal("arbitrary error/message exported")
	}
	if !bytes.Contains(payloads.Bytes(), []byte("http.request.completed")) {
		t.Fatal("safe completion absent")
	}
}
