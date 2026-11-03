package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"

	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Exercise the same outer transformations as cmd/server with the actual router.
func TestComposedRouterWebSocketAndStreaming(t *testing.T) {
	t.Run("websocket", func(t *testing.T) {
		rt, _ := observability.New(context.Background(), observability.DefaultConfig())
		defer rt.Shutdown(context.Background())
		var logs bytes.Buffer
		router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: &logs}), ResponseTransforms: true, AgentToolsHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer conn.Close()
			kind, data, err := conn.ReadMessage()
			if err == nil {
				_ = conn.WriteMessage(kind, data)
			}
		})})
		done := make(chan struct{})
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { defer close(done); router.ServeHTTP(w, r) }))
		defer server.Close()
		header := http.Header{"Accept-Encoding": []string{"gzip"}}
		conn, res, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/internal/agent-tools/v1/echo", header)
		if err != nil {
			if res != nil {
				defer res.Body.Close()
			}
			t.Fatal(err)
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		if err := conn.WriteMessage(websocket.TextMessage, []byte("echo")); err != nil {
			t.Fatal(err)
		}
		_, data, err := conn.ReadMessage()
		if err != nil || string(data) != "echo" {
			t.Fatalf("echo %q: %v", data, err)
		}
		// Hijacked connections are not awaited by http.Server.Close.
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("handler did not finish")
		}
		_ = conn.Close()
		server.Close()
		var entry logger.Entry
		_ = json.Unmarshal(bytes.TrimSpace(logs.Bytes()), &entry)
		if entry.Fields["http.response.status_code"] != float64(101) {
			t.Fatalf("websocket completion status: %s", logs.String())
		}
	})
	t.Run("stream", func(t *testing.T) {
		release := make(chan struct{})
		defer close(release)
		rt, _ := observability.New(context.Background(), observability.DefaultConfig())
		defer rt.Shutdown(context.Background())
		var logs bytes.Buffer
		router := NewRouterWithConfig(&RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Output: &logs}), ResponseTransforms: true, AgentToolsHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: early\n\n")
			if err := http.NewResponseController(w).Flush(); err != nil {
				t.Errorf("flush: %v", err)
				return
			}
			select {
			case <-release:
			case <-r.Context().Done():
			}
		})})
		done := make(chan struct{})
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { defer close(done); router.ServeHTTP(w, r) }))
		defer server.Close()
		client := &http.Client{Timeout: 2 * time.Second}
		req, _ := http.NewRequest("GET", server.URL+"/internal/agent-tools/v1/stream", nil)
		// Do not announce SSE in Accept: response Flush must still work.
		req.Header.Set("Accept-Encoding", "gzip")
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		line, err := bufio.NewReader(res.Body).ReadString('\n')
		if err != nil || line != "data: early\n" {
			t.Fatalf("early %q: %v", line, err)
		}
		if res.Header.Get("Content-Encoding") != "" {
			t.Fatal("stream must bypass buffering/compression")
		}
	})
}
