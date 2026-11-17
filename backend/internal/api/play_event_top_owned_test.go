package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

type topModeStore struct {
	fakePlayStore
	calls       int
	owned       bool
	user        uuid.UUID
	days, limit int
	err         error
}

func (s *topModeStore) TopTracks(_ context.Context, user uuid.UUID, days, limit int) ([]db.TopTrack, error) {
	s.calls++
	s.user, s.days, s.limit = user, days, limit
	return s.top, s.err
}

func (s *topModeStore) OwnedTopTracks(_ context.Context, user uuid.UUID, days, limit int) ([]db.TopTrack, error) {
	s.calls++
	s.owned = true
	s.user, s.days, s.limit = user, days, limit
	return s.top, s.err
}

func TestTopTracksOwnedModeHTTP(t *testing.T) {
	for _, tc := range []struct {
		name, query         string
		owned               bool
		days, limit, status int
	}{
		{"historical default", "", false, 30, 20, 200},
		{"historical explicit false", "?owned=false&days=7&limit=10", false, 7, 10, 200},
		{"owned default", "?owned=true", true, 30, 20, 200},
		{"owned top25", "?owned=true&days=30&limit=25", true, 30, 25, 200},
		{"owned maximum", "?owned=true&limit=1000", true, 30, 100, 200},
		{"owned zero defaults", "?owned=true&days=0&limit=0", true, 30, 20, 200},
		{"invalid mode", "?owned=yes", false, 0, 0, 400},
		{"empty mode", "?owned=", false, 0, 0, 400},
		{"conflicting mode", "?owned=true&owned=false", false, 0, 0, 400},
		{"duplicate mode", "?owned=true&owned=true", false, 0, 0, 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			user := uuid.New()
			store := &topModeStore{}
			h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})
			rr := httptest.NewRecorder()
			h.TopTracks(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top"+tc.query, nil), user))
			if rr.Code != tc.status {
				t.Fatalf("status = %d, want %d, body=%s", rr.Code, tc.status, rr.Body.String())
			}
			if tc.status != http.StatusOK {
				if store.calls != 0 {
					t.Fatal("invalid mode reached store")
				}
				return
			}
			if store.calls != 1 || store.user != user || store.owned != tc.owned || store.days != tc.days || store.limit != tc.limit {
				t.Fatalf("store call = %+v", store)
			}
			var wire map[string]json.RawMessage
			if err := json.Unmarshal(rr.Body.Bytes(), &wire); err != nil {
				t.Fatal(err)
			}
			if tc.owned {
				if string(wire["ownedOnly"]) != "true" {
					t.Fatalf("owned marker = %s", wire["ownedOnly"])
				}
			} else if _, present := wire["ownedOnly"]; present {
				t.Fatal("legacy mode must omit ownedOnly")
			}
			if string(wire["tracks"]) != "[]" {
				t.Fatalf("empty tracks = %s, want []", wire["tracks"])
			}
			var resp TopTracksResponse
			if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
				t.Fatal(err)
			}
			if resp.Days != tc.days || resp.Limit != tc.limit {
				t.Fatalf("envelope bounds = %+v", resp)
			}
		})
	}
}

func TestTopTracksOwnedAuthAndStoreFailure(t *testing.T) {
	store := &topModeStore{err: errors.New("private store error")}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})
	rr := httptest.NewRecorder()
	h.TopTracks(rr, httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top?owned=true", nil))
	if rr.Code != http.StatusUnauthorized || store.calls != 0 {
		t.Fatal("unauthenticated request reached store")
	}
	rr = httptest.NewRecorder()
	h.TopTracks(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top?owned=true", nil), uuid.New()))
	if rr.Code != http.StatusInternalServerError || !store.owned || store.calls != 1 {
		t.Fatalf("failure status=%d store=%+v", rr.Code, store)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Code != "INTERNAL_ERROR" || resp.Message != "failed to load top tracks" {
		t.Fatalf("error=%+v", resp)
	}
}
