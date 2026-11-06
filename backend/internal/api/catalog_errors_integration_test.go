package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
)

func TestCatalogErrorJSON(t *testing.T) {
	f := newMembershipFixture(t)
	disabled := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(f.router.authService), AuthService: f.router.authService})
	for _, endpoint := range []string{"resolution", "membership"} {
		t.Run(endpoint, func(t *testing.T) {
			for _, c := range []struct {
				name, recording, query, code, message string
				status                                int
				nilUser, unavailable, databaseError   bool
			}{
				{name: "nil_owner", recording: f.recording.String(), nilUser: true, status: 401, code: "UNAUTHORIZED", message: "authentication required"},
				{name: "invalid_recording", recording: "invalid", status: 400, code: "VALIDATION_ERROR", message: "a canonical non-nil recording MBID and no query parameters are required"},
				{name: "query_override", recording: f.recording.String(), query: "?userId=" + uuid.NewString(), status: 400, code: "VALIDATION_ERROR", message: "a canonical non-nil recording MBID and no query parameters are required"},
				{name: "unwired", recording: f.recording.String(), unavailable: true, status: 503, code: "SERVICE_DISABLED", message: "Catalog recording resolution is unavailable"},
				{name: "database_error", recording: f.recording.String(), databaseError: true, status: 500, code: "INTERNAL_ERROR", message: "failed to resolve catalog recording"},
			} {
				t.Run(c.name, func(t *testing.T) {
					method := http.MethodGet
					if endpoint == "membership" {
						method = http.MethodPost
					}
					r := httptest.NewRequest(method, "/api/v1/catalog/recordings/"+c.recording+"/"+endpoint+c.query, strings.NewReader(fmt.Sprintf(`{"trackId":%d}`, f.track)))
					r.Header.Set("Content-Type", "application/json")
					user := f.user
					if c.nilUser {
						user = uuid.Nil
					}
					r.Header.Set("Authorization", "Bearer "+f.token(user))
					if c.databaseError {
						ctx, cancel := context.WithCancel(r.Context())
						cancel()
						r = r.WithContext(ctx)
					}
					w := httptest.NewRecorder()
					if c.unavailable {
						disabled.ServeHTTP(w, r)
					} else {
						f.router.ServeHTTP(w, r)
					}
					message := c.message
					if endpoint == "membership" {
						message = ""
					}
					assertCatalogJSONError(t, w, c.status, c.code, message)
				})
			}
			// Direct handler admission also protects callers without middleware.
			w := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			var h *LibraryHandlers
			message := "authentication required"
			if endpoint == "resolution" {
				h.ResolveCatalogRecording(w, r)
			} else {
				h.AddCatalogMembership(w, r)
				message = ""
			}
			assertCatalogJSONError(t, w, 401, "UNAUTHORIZED", message)
		})
	}
}

func assertCatalogJSONError(t *testing.T, w *httptest.ResponseRecorder, status int, code, message string) {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if w.Code != status || body["code"] != code || body["message"] != message {
		t.Fatalf("error contract: status=%d body=%s want=%d/%s/%q", w.Code, w.Body.String(), status, code, message)
	}
	if got := w.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type=%q want application/json", got)
	}
	if got := w.Header().Get("Cache-Control"); got != "private, no-store" {
		t.Errorf("Cache-Control=%q want private, no-store", got)
	}
}
