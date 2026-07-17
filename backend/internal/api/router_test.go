package api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/auth"
)

func TestDisabledQueueRoutesRequireAuth(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/queue", nil)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("GET /api/v1/queue without auth = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestDisabledDownloadRoutesRequireAuth(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/downloads", nil)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("GET /api/v1/downloads without auth = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestDisabledPlaylistImportRoutesRequireAuth(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/playlist-imports", strings.NewReader(`{"url":"https://www.youtube.com/playlist?list=PLx"}`))
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("POST /api/v1/playlist-imports without auth = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestStreamProxyRouteRemovedFromNormalPath(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/stream/42", nil)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /api/v1/stream/42 = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestDiscoveryAssistRouteRequiresAuth(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(`{"prompt":"x"}`))
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("POST /api/v1/discovery/assist without auth = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestDiscoveryAssistRouteIsRegisteredWhenDisabled(t *testing.T) {
	// With no discovery handlers wired the assist route must still exist (not 404)
	// so it can surface SERVICE_DISABLED after auth, mirroring search/resolve-url.
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(`{"prompt":"x"}`))
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code == http.StatusNotFound {
		t.Fatalf("POST /api/v1/discovery/assist = 404, route should be registered")
	}
}

func TestPrivateAgentToolsRouteIsAbsentUntilWired(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(nil)})
	request := httptest.NewRequest(http.MethodPost, "/internal/agent-tools/v1/capabilities", strings.NewReader(`{}`))
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("unwired private gateway = %d, want 404", recorder.Code)
	}

	router = NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
		AgentToolsHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusNoContent)
		}),
	})
	recorder = httptest.NewRecorder()
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("wired private gateway = %d, want 204", recorder.Code)
	}
}

func TestLocalFlutterAuthPreflightGetsCORSHeaders(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{})

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/auth/login", nil)
	req.Header.Set("Origin", "http://localhost:18145")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	req.Header.Set("Access-Control-Request-Headers", "authorization, content-type")
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS /api/v1/auth/login = %d, want %d", rec.Code, http.StatusNoContent)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "http://localhost:18145" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want local Flutter origin", got)
	}
	if got := rec.Header().Get("Access-Control-Allow-Methods"); !strings.Contains(got, http.MethodPost) {
		t.Fatalf("Access-Control-Allow-Methods = %q, want %s", got, http.MethodPost)
	}
	if got := rec.Header().Get("Access-Control-Allow-Headers"); !strings.Contains(got, "Authorization") {
		t.Fatalf("Access-Control-Allow-Headers = %q, want Authorization", got)
	}
	if got := rec.Header().Get("Vary"); !strings.Contains(got, "Origin") {
		t.Fatalf("Vary = %q, want Origin", got)
	}
}

func TestNonLocalAuthPreflightGetsNoAllowOrigin(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{})

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/auth/login", nil)
	req.Header.Set("Origin", "https://evil.example")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS /api/v1/auth/login = %d, want %d", rec.Code, http.StatusNoContent)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want empty for non-local origin", got)
	}
	if got := rec.Header().Get("Vary"); !strings.Contains(got, "Origin") {
		t.Fatalf("Vary = %q, want Origin", got)
	}
}

func TestSavedMixPlanItemRoutesUseOpenAPIPathParam(t *testing.T) {
	source, err := os.ReadFile("router.go")
	if err != nil {
		t.Fatalf("read router.go: %v", err)
	}

	text := string(source)
	for _, route := range []string{
		`"GET /api/v1/mix-plans/{mixPlanId}"`,
		`"PUT /api/v1/mix-plans/{mixPlanId}"`,
	} {
		if !strings.Contains(text, route) {
			t.Fatalf("router.go missing saved mix-plan route %s", route)
		}
	}
	if strings.Contains(text, "/api/v1/mix-plans/{id}") {
		t.Fatal("saved mix-plan routes must use OpenAPI path parameter {mixPlanId}, not {id}")
	}
}
