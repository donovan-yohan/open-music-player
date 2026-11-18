package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/auth"
)

func TestManualSourceSyncRoutesRequireAuthentication(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(nil)})
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, httptest.NewRequest(method, "/api/v1/playlists/41/source-sync", strings.NewReader(`{}`)))
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s manual sync = %d, want authenticated route (401)", method, rec.Code)
		}
	}
}
