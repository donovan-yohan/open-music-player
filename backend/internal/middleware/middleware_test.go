package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCORSAllowsAnalysisPatchPreflightWithoutBroadeningOrigins(t *testing.T) {
	const allowedOrigin = "http://localhost:18145"
	handler := CORS([]string{allowedOrigin})(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Fatal("preflight must not reach wrapped handler")
	}))
	request := httptest.NewRequest(http.MethodOptions, "/api/v1/tracks/42/analysis/overrides", nil)
	request.Header.Set("Origin", allowedOrigin)
	request.Header.Set("Access-Control-Request-Method", http.MethodPatch)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusNoContent)
	}
	if got, want := response.Header().Get("Access-Control-Allow-Methods"), "GET, POST, PUT, PATCH, DELETE, OPTIONS"; got != want {
		t.Fatalf("methods = %q, want %q", got, want)
	}
	blocked := httptest.NewRequest(http.MethodOptions, "/api/v1/tracks/42/analysis/overrides", nil)
	blocked.Header.Set("Origin", "https://not-allowed.example")
	blockedResponse := httptest.NewRecorder()
	handler.ServeHTTP(blockedResponse, blocked)
	if got := blockedResponse.Header().Get("Access-Control-Allow-Methods"); got != "" {
		t.Fatalf("blocked methods = %q, want empty", got)
	}
}
