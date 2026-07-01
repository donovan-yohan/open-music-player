package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
)

// authedLibraryRequest builds a GET /api/v1/library request carrying a valid
// user context so the handler proceeds past the auth check to sort validation.
func authedLibraryRequest(rawQuery string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/library?"+rawQuery, nil)
	ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: uuid.New(),
		Email:  "sort@test.local",
	})
	return req.WithContext(ctx)
}

// TestGetLibraryRejectsUnknownSort confirms an unrecognized sort value is a 400
// with INVALID_SORT before any repository access (nil repo is never touched).
func TestGetLibraryRejectsUnknownSort(t *testing.T) {
	h := NewLibraryHandlers(nil, nil)

	rec := httptest.NewRecorder()
	h.GetLibrary(rec, authedLibraryRequest("sort=bogus"))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d; want %d", rec.Code, http.StatusBadRequest)
	}
	var body LibraryErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if body.Code != "INVALID_SORT" {
		t.Fatalf("code = %q; want INVALID_SORT", body.Code)
	}
}

// TestGetLibraryAcceptsDurationSort confirms sort=duration passes validation. A
// valid sort proceeds to the repository call; with a nil repo that panics, so a
// recovered panic proves validation accepted the value (no 400 was written).
func TestGetLibraryAcceptsDurationSort(t *testing.T) {
	h := NewLibraryHandlers(nil, nil)
	rec := httptest.NewRecorder()

	defer func() {
		_ = recover() // expected: nil libraryRepo dereference after validation passes
		if rec.Code == http.StatusBadRequest {
			t.Fatalf("sort=duration was rejected with 400; want accepted")
		}
	}()

	h.GetLibrary(rec, authedLibraryRequest("sort=duration&order=asc"))
	t.Fatalf("expected nil-repo panic after validation, but handler returned cleanly")
}
