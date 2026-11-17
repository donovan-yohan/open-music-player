package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type varietyWireFixture struct {
	rows         []musicbrainz.TrackResult
	seeds, calls int
}

func (f *varietyWireFixture) RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error) {
	f.seeds++
	return db.RadarSeeds{Artists: []uuid.UUID{uuid.MustParse("11111111-1111-4111-8111-111111111111"), uuid.MustParse("22222222-1111-4111-8111-111111111111")}, Available: 2, Events: 3}, nil
}
func (f *varietyWireFixture) OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error) {
	return map[uuid.UUID]bool{}, nil
}
func (f *varietyWireFixture) SearchTracks(context.Context, string, int, int, bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	f.calls++
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Results: f.rows, Limit: 100, Total: len(f.rows)}, nil
}
func varietyWireRows() []musicbrainz.TrackResult {
	return []musicbrainz.TrackResult{
		{MBID: "00000001-2222-4222-8222-222222222222", Title: "Album first", Artist: "Seed A", FirstReleaseDate: "2026-11-12", ReleaseGroupMBID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ReleaseID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", ArtistCredits: []musicbrainz.ArtistCredit{{MBID: "11111111-1111-4111-8111-111111111111"}}},
		{MBID: "00000002-2222-4222-8222-222222222222", Title: "Album sibling", Artist: "Seed A", FirstReleaseDate: "2026-11-12", ReleaseGroupMBID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ReleaseID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", ArtistCredits: []musicbrainz.ArtistCredit{{MBID: "11111111-1111-4111-8111-111111111111"}}},
		{MBID: "00000003-2222-4222-8222-222222222222", Title: "Other album", Artist: "Seed B", FirstReleaseDate: "2026-11-11", ReleaseGroupMBID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", ArtistCredits: []musicbrainz.ArtistCredit{{MBID: "22222222-1111-4111-8111-111111111111"}}},
	}
}
func varietyRequest(h *ReleaseRadarHandlers, headers http.Header, query string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases"+query, nil)
	r.Header = headers
	r = r.WithContext(context.WithValue(r.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.MustParse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")}))
	w := httptest.NewRecorder()
	h.Releases(w, r)
	return w
}
func TestReleaseRadarRawHTTPPolicyHeaders(t *testing.T) {
	for _, fields := range []string{
		"X-SoundQ-Radar-Policy: recording-radar-v2\r\nx-soundq-radar-policy: recording-radar-v2\r\n",
		"x-soundq-radar-policy: recording-radar-v2\r\nX-SoundQ-Radar-Policy: unknown\r\n",
		"X-SoundQ-Radar-Policy: recording-radar-v2, recording-radar-v1\r\n",
		"X-SoundQ-Radar-Policy:\r\n",
	} {
		r, err := http.ReadRequest(bufio.NewReader(strings.NewReader("GET /api/v1/me/discovery/releases HTTP/1.1\r\nHost: fixture.invalid\r\n" + fields + "\r\n")))
		if err != nil {
			t.Fatal(err)
		}
		r = r.WithContext(context.WithValue(r.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
		f := &varietyWireFixture{rows: varietyWireRows()}
		h := NewReleaseRadarHandlers(discovery.NewRadarService(f, f, f), f, true)
		w := httptest.NewRecorder()
		h.Releases(w, r)
		if w.Code != 400 || f.calls != 0 || f.seeds != 0 {
			t.Fatal("raw duplicate/unknown header reached provider")
		}
	}
}

func TestReleaseRadarPolicyHeaderRefusesBeforeProviders(t *testing.T) {
	for _, headers := range []http.Header{
		{"X-Soundq-Radar-Policy": {"unknown"}}, {"X-Soundq-Radar-Policy": {""}},
		{"X-Soundq-Radar-Policy": {"recording-radar-v1"}},
		{"X-Soundq-Radar-Policy": {"recording-radar-v2", "recording-radar-v2"}},
		{"X-Soundq-Radar-Policy": {"recording-radar-v2, recording-radar-v2"}},
		{"X-Soundq-Radar-Policy": {"recording-radar-v2"}, "x-soundq-radar-policy": {"unknown"}},
	} {
		f := &varietyWireFixture{rows: varietyWireRows()}
		h := NewReleaseRadarHandlers(discovery.NewRadarService(f, f, f), f, true)
		w := varietyRequest(h, headers, "")
		if w.Code != 400 || f.seeds != 0 || f.calls != 0 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("policy admitted: %v code=%d seeds=%d calls=%d", headers, w.Code, f.seeds, f.calls)
		}
	}
}
func TestReleaseRadarNegotiatesActualProducerOrdering(t *testing.T) {
	f := &varietyWireFixture{rows: varietyWireRows()}
	h := NewReleaseRadarHandlers(discovery.NewRadarService(f, f, f), f, true)
	h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
	for _, v2 := range []bool{false, true} {
		headers := http.Header{}
		policy := "recording-radar-v1"
		want := []string{"Album first", "Album sibling", "Other album"}
		if v2 {
			headers.Set("X-SoundQ-Radar-Policy", "recording-radar-v2")
			policy = "recording-radar-v2"
			want = []string{"Album first", "Other album", "Album sibling"}
		}
		w := varietyRequest(h, headers, "")
		var p discovery.RadarPage
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &p) != nil || p.PolicyVersion != policy || len(p.Items) != 3 {
			t.Fatalf("wrong negotiated response %d %s", w.Code, w.Body.String())
		}
		for i, title := range want {
			if p.Items[i].Title != title {
				t.Fatalf("wrong %s order: %+v", policy, p.Items)
			}
		}
		// The v1 producer contract remains date/ID sorted, not relabelled variety.
		for i := 1; i < len(p.Items); i++ {
			if !v2 && p.Items[i-1].FirstRelease.Raw < p.Items[i].FirstRelease.Raw {
				t.Fatal("reordered v1 producer")
			}
		}
	}
}
