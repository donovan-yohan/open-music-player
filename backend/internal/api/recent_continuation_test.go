package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

type recentPageStore struct {
	fakePlayStore
	pageCalls int
	revision  string
	offset    int
	err       error
}

func (f *recentPageStore) RecentPage(ctx context.Context, user uuid.UUID, limit, offset int, revision string) ([]db.RecentlyPlayedTrack, string, bool, error) {
	f.pageCalls++
	f.revision = revision
	f.offset = offset
	return f.recent, strings.Repeat("a", 64), true, f.err
}
func TestRecentContinuationOptInCarriesRevisionAndRealEndEvidence(t *testing.T) {
	store := &recentPageStore{}
	h := NewPlayEventHandlers(store, nil)
	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?continuation=true&limit=20&offset=20&revision="+strings.Repeat("a", 64), nil), uuid.New())
	rr := httptest.NewRecorder()
	h.RecentlyPlayed(rr, req)
	var body map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if rr.Code != 200 || store.pageCalls != 1 || body["revision"] != strings.Repeat("a", 64) || body["hasMore"] != true || store.offset != 20 || store.revision != strings.Repeat("a", 64) {
		t.Fatalf("code=%d calls=%d body=%v", rr.Code, store.pageCalls, body)
	}
}

func TestRecentContinuationRejectsInvalidCursorBeforeRepositoryAndPreservesLegacy(t *testing.T) {
	for _, query := range []string{"limit=101&offset=0", "limit=0&offset=0", "limit=20&offset=-1", "limit=20&offset=20", "limit=20&offset=0&revision=wrong", "limit=no&offset=0", "limit=20&offset=no"} {
		store := &recentPageStore{}
		h := NewPlayEventHandlers(store, nil)
		rr := httptest.NewRecorder()
		h.RecentlyPlayed(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?continuation=true&"+query, nil), uuid.New()))
		if rr.Code != 400 || store.pageCalls != 0 {
			t.Fatalf("query=%s code=%d calls=%d", query, rr.Code, store.pageCalls)
		}
	}
	store := &recentPageStore{}
	h := NewPlayEventHandlers(store, nil)
	rr := httptest.NewRecorder()
	h.RecentlyPlayed(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?limit=20&offset=0", nil), uuid.New()))
	if rr.Code != 200 || store.pageCalls != 0 || strings.Contains(rr.Body.String(), "revision") || strings.Contains(rr.Body.String(), "hasMore") {
		t.Fatalf("legacy response changed: %d %s", rr.Code, rr.Body.String())
	}
}

func TestRecentContinuationMutationReturnsConflictAndRequiresAuthentication(t *testing.T) {
	store := &recentPageStore{err: db.ErrRecentChanged}
	h := NewPlayEventHandlers(store, nil)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?continuation=true&limit=20&offset=0", nil)
	rr := httptest.NewRecorder()
	h.RecentlyPlayed(rr, req)
	if rr.Code != 401 || store.pageCalls != 0 {
		t.Fatalf("unauth code=%d calls=%d", rr.Code, store.pageCalls)
	}
	rr = httptest.NewRecorder()
	h.RecentlyPlayed(rr, withUser(req, uuid.New()))
	if rr.Code != 409 || !strings.Contains(rr.Body.String(), "RECENT_CHANGED") {
		t.Fatalf("code=%d body=%s", rr.Code, rr.Body.String())
	}
}
