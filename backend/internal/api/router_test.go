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
