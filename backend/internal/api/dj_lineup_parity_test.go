package api

import (
	"bytes"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// updateDJLineupGolden rewrites the themed-lineup golden corpus. The goldens
// are captured once against the untouched themed lineup and are the contract
// that every later flag-off code path must still satisfy byte-for-byte.
//
//	go test ./internal/api -run TestDJLineupFlagOffResponseParity -args -update-dj-lineup-golden
var updateDJLineupGolden = flag.Bool("update-dj-lineup-golden", false, "rewrite DJ lineup parity goldens")

// djLineupParityUserID is fixed so nothing in the recorded bytes can vary
// between runs. The lineup response never echoes the user id; pinning it here
// simply removes one source of nondeterminism from the harness itself.
var djLineupParityUserID = uuid.MustParse("6f1c6f8c-0f4a-4a3f-9a9d-1c2f6a5b7d10")

// djLineupParityFixture is a fully literal library projection: no time.Now(),
// no randomness, no map iteration. Every play window, timestamp, BPM, camelot,
// energy and genre hint is written out so the recorded goldens depend only on
// the lineup code under test.
//
// The set is shaped so all three themes fill (5 on-repeat, 5 flashback,
// 5 fresh-finds) and so the filter cases in djLineupParityCases each select a
// non-trivial subset.
func djLineupParityFixture() []db.DJLineupTrack {
	added := func(day int) time.Time {
		return time.Date(2026, time.February, day, 9, 30, 0, 0, time.UTC)
	}
	recent := func(day int) time.Time {
		return time.Date(2026, time.March, day, 21, 15, 0, 0, time.UTC)
	}
	historical := func(month time.Month, day int) time.Time {
		return time.Date(2025, month, day, 18, 45, 0, 0, time.UTC)
	}

	return []db.DJLineupTrack{
		// --- on-repeat: played inside the recent (90 day) window ---
		{
			ID: 1, Title: "Night Drive", Artist: "Artist A", Album: "Album A", DurationMs: 210000,
			BPM: 128, Camelot: "8A", Energy: 0.8, GenreHints: []string{"Techno"},
			AddedAt: added(1), RecentPlayCount: 12, LastRecentPlayedAt: recent(1), TotalPlayCount: 20,
		},
		{
			ID: 2, Title: "Warehouse", Artist: "Artist B", Album: "Album B", DurationMs: 240000,
			BPM: 130, Camelot: "8B", Energy: 0.72, GenreHints: []string{"Techno", "Hard Techno"},
			AddedAt: added(2), RecentPlayCount: 9, LastRecentPlayedAt: recent(2), TotalPlayCount: 14,
		},
		{
			ID: 3, Title: "Slow Burn", Artist: "Artist C", Album: "Album C", DurationMs: 300000,
			BPM: 90, Camelot: "5A", Energy: 0.2, GenreHints: []string{"Ambient"},
			AddedAt: added(3), RecentPlayCount: 7, LastRecentPlayedAt: recent(3), TotalPlayCount: 11,
		},
		{
			ID: 4, Title: "Midtempo", Artist: "Artist D", Album: "Album D", DurationMs: 260000,
			BPM: 110, Camelot: "3A", Energy: 0.5, GenreHints: []string{"House"},
			AddedAt: added(4), RecentPlayCount: 5, LastRecentPlayedAt: recent(4), TotalPlayCount: 6,
		},
		{
			ID: 5, Title: "Peak Time", Artist: "Artist E", Album: "Album E", DurationMs: 200000,
			BPM: 136, Camelot: "9A", Energy: 0.9, GenreHints: []string{"Techno"},
			AddedAt: added(5), RecentPlayCount: 3, LastRecentPlayedAt: recent(5), TotalPlayCount: 3,
		},

		// --- flashback: played, but not inside the recent window ---
		{
			ID: 6, Title: "Night Bus", Artist: "Artist F", Album: "Album F", DurationMs: 190000,
			BPM: 124, Camelot: "8A", Energy: 0.34, GenreHints: []string{"Downtempo"},
			AddedAt: added(6), TotalPlayCount: 5, MidWindowPlayCount: 4, HistoricalPlayCount: 1,
			LastHistoricalPlayed: historical(time.November, 5),
		},
		{
			ID: 7, Title: "Old Groove", Artist: "Artist G", Album: "Album G", DurationMs: 230000,
			BPM: 122, Camelot: "7A", Energy: 0.55, GenreHints: []string{"House"},
			AddedAt: added(7), TotalPlayCount: 5, MidWindowPlayCount: 3, HistoricalPlayCount: 2,
			LastHistoricalPlayed: historical(time.October, 20),
		},
		{
			ID: 8, Title: "Dusty Record", Artist: "Artist H", Album: "Album H", DurationMs: 250000,
			BPM: 118, Camelot: "4B", Energy: 0.65, GenreHints: []string{"Disco"},
			AddedAt: added(8), TotalPlayCount: 7, MidWindowPlayCount: 2, HistoricalPlayCount: 5,
			LastHistoricalPlayed: historical(time.September, 15),
		},
		{
			ID: 9, Title: "Forgotten Anthem", Artist: "Artist I", Album: "Album I", DurationMs: 280000,
			BPM: 140, Camelot: "12A", Energy: 0.88, GenreHints: []string{"Trance"},
			AddedAt: added(9), TotalPlayCount: 4, MidWindowPlayCount: 1, HistoricalPlayCount: 3,
			LastHistoricalPlayed: historical(time.August, 1),
		},
		{
			ID: 10, Title: "Back Catalogue", Artist: "Artist J", Album: "Album J", DurationMs: 270000,
			BPM: 100, Camelot: "2B", Energy: 0.3, GenreHints: []string{"Ambient"},
			AddedAt: added(10), TotalPlayCount: 6, MidWindowPlayCount: 6,
			LastHistoricalPlayed: historical(time.December, 11),
		},

		// --- fresh finds: never played ---
		{
			ID: 11, Title: "Fresh Night", Artist: "Artist K", Album: "Album K", DurationMs: 215000,
			BPM: 128, Camelot: "8A", Energy: 0.78, GenreHints: []string{"Techno"},
			AddedAt: added(20),
		},
		{
			ID: 12, Title: "Untouched", Artist: "Artist L", Album: "Album L", DurationMs: 195000,
			BPM: 127, Camelot: "9A", Energy: 0.68, GenreHints: []string{"Techno"},
			AddedAt: added(18),
		},
		{
			ID: 13, Title: "Brand New", Artist: "Artist M", Album: "Album M", DurationMs: 205000,
			BPM: 129, Camelot: "8B", Energy: 0.66, GenreHints: []string{"Minimal"},
			AddedAt: added(15),
		},
		{
			ID: 14, Title: "Quiet Start", Artist: "Artist N", Album: "Album N", DurationMs: 310000,
			BPM: 85, Camelot: "1A", Energy: 0.15, GenreHints: []string{"Ambient"},
			AddedAt: added(12),
		},
		{
			ID: 15, Title: "Unplayed Groove", Artist: "Artist O", Album: "Album O", DurationMs: 225000,
			BPM: 126, Camelot: "7A", Energy: 0.45, GenreHints: []string{"House"},
			AddedAt: added(11),
		},
	}
}

// djLineupParityCases spans every accepted query knob plus the four rejection
// paths, so a regression in parsing, filtering, ordering, selection or error
// copy shows up as a golden diff.
var djLineupParityCases = []struct {
	name  string
	query string
}{
	{name: "default", query: ""},
	{name: "blocks-1", query: "blocks=1"},
	{name: "blocks-3", query: "blocks=3"},
	{name: "per-block-1", query: "perBlock=1"},
	{name: "per-block-5", query: "perBlock=5"},
	{name: "block-on-repeat", query: "block=on-repeat"},
	{name: "block-flashback", query: "block=flashback"},
	{name: "block-fresh-finds", query: "block=fresh-finds"},
	{name: "energy-low", query: "energy=low"},
	{name: "energy-medium", query: "energy=medium"},
	{name: "energy-high", query: "energy=high"},
	{name: "genre-techno", query: "genre=Techno"},
	{name: "q-night", query: "q=night"},
	{name: "exclude-ids", query: "excludeIds=1,3"},
	{name: "seed-73", query: "seed=73"},
	{name: "seed-negative", query: "seed=-9"},
	{name: "error-block-harmonic", query: "block=harmonic"},
	{name: "error-block-bogus", query: "block=bogus"},
	{name: "error-energy-bogus", query: "energy=bogus"},
	{name: "error-seed-not-an-int", query: "seed=not-an-int"},
}

const djLineupParityGoldenDir = "testdata/dj_lineup_parity"

// assertDJLineupParity replays the whole case table against one handler and
// compares status + raw body bytes to the recorded goldens. extraQuery is
// appended to every case so a caller can prove that an additional query
// parameter changes nothing.
func assertDJLineupParity(t *testing.T, handler *DJLineupHandlers, extraQuery string) {
	t.Helper()
	for _, tc := range djLineupParityCases {
		t.Run(tc.name, func(t *testing.T) {
			query := tc.query
			if extraQuery != "" {
				if query == "" {
					query = extraQuery
				} else {
					query += "&" + extraQuery
				}
			}
			rawURL := "/api/v1/dj/lineup"
			if query != "" {
				rawURL += "?" + query
			}

			req := withUser(httptest.NewRequest(http.MethodGet, rawURL, nil), djLineupParityUserID)
			rec := httptest.NewRecorder()
			handler.GetLineup(rec, req)

			got := append([]byte(fmt.Sprintf("status: %d\n", rec.Code)), rec.Body.Bytes()...)
			goldenPath := filepath.Join(djLineupParityGoldenDir, tc.name+".golden")

			if *updateDJLineupGolden {
				if err := os.MkdirAll(djLineupParityGoldenDir, 0o755); err != nil {
					t.Fatalf("create golden dir: %v", err)
				}
				if err := os.WriteFile(goldenPath, got, 0o644); err != nil {
					t.Fatalf("write golden %s: %v", goldenPath, err)
				}
				return
			}

			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden %s: %v (regenerate with -args -update-dj-lineup-golden)", goldenPath, err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("GET %s is not byte-identical to %s\n got: %s\nwant: %s", rawURL, goldenPath, got, want)
			}
		})
	}
}

// newDJLineupParityHandler builds the themed lineup exactly as the pre-#401
// server did: library store only, no pin store, no skip store.
func newDJLineupParityHandler() *DJLineupHandlers {
	return NewDJLineupHandlersWithSkipSignals(&fakeDJLineupStore{tracks: djLineupParityFixture()}, nil, nil)
}

// TestDJLineupFlagOffResponseParity is the frozen contract for the themed DJ
// lineup: for a fixed library and a fixed request table, status and body bytes
// must not move.
func TestDJLineupFlagOffResponseParity(t *testing.T) {
	assertDJLineupParity(t, newDJLineupParityHandler(), "")
}
