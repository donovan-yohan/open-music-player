package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestJamAcquisitionProductionRoutesExistAndRequireOwner(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{})
	for _, target := range []struct{ method, path string }{
		{"POST", "/api/v1/jams/11111111-1111-4111-8111-111111111111/requests/22222222-2222-4222-8222-222222222222/approval"},
		{"DELETE", "/api/v1/jams/11111111-1111-4111-8111-111111111111/members/22222222-2222-4222-8222-222222222222"},
	} {
		out := httptest.NewRecorder()
		router.ServeHTTP(out, httptest.NewRequest(target.method, target.path, nil))
		if out.Code != http.StatusUnauthorized || out.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("host route missing or unguarded: %s %s HTTP %d %s", target.method, target.path, out.Code, out.Body.String())
		}
	}
}
