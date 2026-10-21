package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
)

func TestConnectProductionRedisOffFailsClosed(t *testing.T) {
	handler := newConnectHandlers(nil)
	// Real router supplies auth; the composition seam must always return a handler
	// rather than silently forgetting to register Redis-off endpoints.
	if handler == nil {
		t.Fatal("Connect production handler absent")
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/me/devices", nil))
	if rec.Code != 401 {
		t.Fatalf("unauthenticated handler=%d", rec.Code)
	}
}

func TestConnectProductionUsesConfiguredCache(t *testing.T) {
	addr := os.Getenv("OMP_CONNECT_REDIS_ADDR")
	if addr == "" {
		t.Skip("OMP_CONNECT_REDIS_ADDR not set")
	}
	configured, err := cache.New(addr)
	if err != nil {
		t.Fatal(err)
	}
	defer configured.Close()
	handler := newConnectHandlers(configured)
	owner := uuid.New()
	secret := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	id := uuid.NewString()
	key := "connect:v1:" + owner.String() + ":0"
	defer configured.Client().Del(context.Background(), key)
	req := httptest.NewRequest("POST", "/api/v1/me/devices", strings.NewReader(`{"deviceId":"`+id+`","label":"production seam","platform":"macos","writerSecret":"`+secret+`"}`))
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: owner, ConnectGeneration: 0}))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != 201 {
		t.Fatalf("production register=%d %s", rec.Code, rec.Body.String())
	}
	raw, err := configured.Client().Get(context.Background(), key).Result()
	if err != nil || !strings.Contains(raw, id) {
		t.Fatalf("configured Redis missing device err=%v", err)
	}
	var result map[string]any
	if err = json.Unmarshal([]byte(raw), &result); err != nil || len(result) != 1 {
		t.Fatalf("persisted map=%v err=%v", result, err)
	}
	var constructor func(*cache.Cache) *api.ConnectHandlers = newConnectHandlers
	_ = constructor
}
