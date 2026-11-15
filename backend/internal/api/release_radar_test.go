package api

import (
	"context"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

type radarWireFixture struct {
	user  uuid.UUID
	calls int
}

func (f *radarWireFixture) RecentArtistSeeds(ctx context.Context, u uuid.UUID, since, through time.Time, n int) (db.RadarSeeds, error) {
	if u != f.user {
		panic("foreign actor")
	}
	f.calls++
	return db.RadarSeeds{Artists: []uuid.UUID{uuid.MustParse("11111111-1111-4111-8111-111111111111")}, Available: 1, Events: 45}, nil
}
func (f *radarWireFixture) OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error) {
	return map[uuid.UUID]bool{}, nil
}
func (f *radarWireFixture) SearchTracks(context.Context, string, int, int, bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Limit: 100, Total: 1, Results: []musicbrainz.TrackResult{{MBID: "33333333-3333-4333-8333-333333333333", Title: "Synthetic newest song", Artist: "Synthetic listened artist", FirstReleaseDate: "2026-11-12", ArtistCredits: []musicbrainz.ArtistCredit{{MBID: "11111111-1111-4111-8111-111111111111"}}}}}, nil
}
func TestReleaseRadarHandlerWire(t *testing.T) {
	f := &radarWireFixture{user: uuid.MustParse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")}
	h := NewReleaseRadarHandlers(discovery.NewRadarService(f, f, f), f, true)
	h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
	request := func(query string, actor bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases"+query, nil)
		if actor {
			r = r.WithContext(context.WithValue(r.Context(), auth.UserContextKey, &auth.UserContext{UserID: f.user}))
		}
		w := httptest.NewRecorder()
		h.Releases(w, r)
		return w
	}
	if w := request("", false); w.Code != 401 || f.calls != 0 {
		t.Fatal("unauthenticated read")
	}
	if w := request("?userId=foreign", true); w.Code != 400 || f.calls != 0 {
		t.Fatal("caller actor admitted")
	}
	w := request("", true)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	if output := os.Getenv("SOUNDQ_RADAR_WIRE_OUTPUT"); output != "" {
		if err := os.WriteFile(output, w.Body.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
	}
	h.admitted = false
	if w = request("", true); w.Code != 503 || f.calls != 1 {
		t.Fatal("production hold bypass")
	}
}
