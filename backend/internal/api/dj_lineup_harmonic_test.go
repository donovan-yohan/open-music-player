package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// recordingNearbyReader captures exactly what the lineup asked the harmonic
// candidate seam for, and can be made to fail or to assert it was never asked.
type recordingNearbyReader struct {
	tracks []db.NearbyTrack
	err    error

	calls        int
	gotUserID    uuid.UUID
	gotBPM       float64
	gotTolerance float64
	gotCamelot   []string
	gotRank      db.AffinityRank
}

func (r *recordingNearbyReader) NearbyTracks(
	_ context.Context,
	userID uuid.UUID,
	bpm, tolerance float64,
	camelot []string,
	rank db.AffinityRank,
) ([]db.NearbyTrack, error) {
	r.calls++
	r.gotUserID = userID
	r.gotBPM = bpm
	r.gotTolerance = tolerance
	r.gotCamelot = append([]string(nil), camelot...)
	r.gotRank = rank
	if r.err != nil {
		return nil, r.err
	}
	return r.tracks, nil
}

const djHarmonicAnchorTrackID int64 = 100

// djHarmonicFixtureTracks is the library projection behind every harmonic unit
// test. The anchor is 128 BPM / 8A, so the compatible camelot set is
// {7A, 8A, 8B, 9A} and the tolerance window is [122, 134].
//
// 101-104 are compatible, 105 is the wrong key, 106 is out of tolerance, 107
// is unanalyzed. 200-202 exist so the themed blocks still fill.
func djHarmonicFixtureTracks() []db.DJLineupTrack {
	added := func(day int) time.Time {
		return time.Date(2026, time.January, day, 8, 0, 0, 0, time.UTC)
	}
	return []db.DJLineupTrack{
		{ID: djHarmonicAnchorTrackID, Title: "Anchor Track", Artist: "Anchor", Album: "Anchor LP", DurationMs: 210000,
			BPM: 128, Camelot: "8A", Energy: 0.70, GenreHints: []string{"Techno"}, AddedAt: added(1)},
		{ID: 101, Title: "Compatible One", Artist: "One", Album: "One LP", DurationMs: 200000,
			BPM: 127, Camelot: "8A", Energy: 0.70, GenreHints: []string{"House"}, AddedAt: added(2)},
		{ID: 102, Title: "Compatible Two", Artist: "Two", Album: "Two LP", DurationMs: 205000,
			BPM: 130, Camelot: "9A", Energy: 0.72, GenreHints: []string{"House"}, AddedAt: added(3)},
		{ID: 103, Title: "Compatible Three", Artist: "Three", Album: "Three LP", DurationMs: 215000,
			BPM: 124, Camelot: "8B", Energy: 0.66, GenreHints: []string{"House"}, AddedAt: added(4)},
		{ID: 104, Title: "Compatible Four", Artist: "Four", Album: "Four LP", DurationMs: 220000,
			BPM: 132, Camelot: "7A", Energy: 0.68, GenreHints: []string{"House"}, AddedAt: added(5)},
		{ID: 105, Title: "Wrong Key", Artist: "Five", Album: "Five LP", DurationMs: 225000,
			BPM: 128, Camelot: "3A", Energy: 0.70, GenreHints: []string{"House"}, AddedAt: added(6)},
		{ID: 106, Title: "Too Fast", Artist: "Six", Album: "Six LP", DurationMs: 230000,
			BPM: 140, Camelot: "8A", Energy: 0.70, GenreHints: []string{"House"}, AddedAt: added(7)},
		{ID: 107, Title: "Unanalyzed", Artist: "Seven", Album: "Seven LP", DurationMs: 235000,
			BPM: 0, Camelot: "", Energy: 0.70, GenreHints: []string{"House"}, AddedAt: added(8)},
		{ID: 200, Title: "Recent Favourite", Artist: "Eight", Album: "Eight LP", DurationMs: 240000,
			BPM: 120, Camelot: "5A", Energy: 0.50, GenreHints: []string{"Disco"}, AddedAt: added(9),
			RecentPlayCount: 6, LastRecentPlayedAt: added(20), TotalPlayCount: 6},
		{ID: 201, Title: "Recent Second", Artist: "Nine", Album: "Nine LP", DurationMs: 245000,
			BPM: 118, Camelot: "6A", Energy: 0.50, GenreHints: []string{"Disco"}, AddedAt: added(10),
			RecentPlayCount: 4, LastRecentPlayedAt: added(19), TotalPlayCount: 4},
		{ID: 202, Title: "Old Friend", Artist: "Ten", Album: "Ten LP", DurationMs: 250000,
			BPM: 116, Camelot: "4A", Energy: 0.45, GenreHints: []string{"Disco"}, AddedAt: added(11),
			TotalPlayCount: 3, MidWindowPlayCount: 3,
			LastHistoricalPlayed: time.Date(2025, time.November, 3, 20, 0, 0, 0, time.UTC)},
	}
}

func nearbyCandidate(id int64, bpm float64, camelot string) db.NearbyTrack {
	return db.NearbyTrack{ID: id, Title: fmt.Sprintf("nearby-%d", id), EffectiveBPM: bpm, EffectiveCamelot: camelot}
}

// djHarmonicFixtureCandidates is the repository's affinity-ranked result:
// the anchor itself, two rejects (wrong key, out of tolerance), and the four
// compatible tracks in a deliberately non-id order so ordering assertions
// prove the affinity ranking survives.
func djHarmonicFixtureCandidates() []db.NearbyTrack {
	return []db.NearbyTrack{
		nearbyCandidate(djHarmonicAnchorTrackID, 128, "8A"),
		nearbyCandidate(103, 124, "8B"),
		nearbyCandidate(101, 127, "8A"),
		nearbyCandidate(105, 128, "3A"),
		nearbyCandidate(104, 132, "7A"),
		nearbyCandidate(106, 140, "8A"),
		nearbyCandidate(102, 130, "9A"),
	}
}

func newDJHarmonicHandler(reader nearbyTrackReader, enabled bool) *DJLineupHandlers {
	return NewDJLineupHandlersWithHarmonicCandidates(
		&fakeDJLineupStore{tracks: djHarmonicFixtureTracks()}, nil, nil, reader, enabled)
}

func newDJHarmonicHandlerWithPin(reader nearbyTrackReader, enabled bool, pin *staticDJPinReader) *DJLineupHandlers {
	return NewDJLineupHandlersWithHarmonicCandidates(
		&fakeDJLineupStore{tracks: djHarmonicFixtureTracks()}, pin, nil, reader, enabled)
}

// djHarmonicRawResponse returns status line + raw body so tests can compare
// whole responses byte-for-byte, not just decoded fields.
func djHarmonicRawResponse(t *testing.T, handler *DJLineupHandlers, rawURL string) []byte {
	t.Helper()
	req := withUser(httptest.NewRequest(http.MethodGet, rawURL, nil), djLineupParityUserID)
	rec := httptest.NewRecorder()
	handler.GetLineup(rec, req)
	return append([]byte(fmt.Sprintf("status: %d\n", rec.Code)), rec.Body.Bytes()...)
}

func itoa64(id int64) string {
	return strconv.FormatInt(id, 10)
}

func decodeDJLineupResponse(t *testing.T, rec *httptest.ResponseRecorder) DJLineupResponse {
	t.Helper()
	var response DJLineupResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode lineup response: %v (body=%s)", err, rec.Body.String())
	}
	return response
}

func djHarmonicBlock(t *testing.T, response DJLineupResponse) (DJLineupBlock, bool) {
	t.Helper()
	for _, block := range response.Blocks {
		if block.ID == djHarmonicLineupBlockID {
			return block, true
		}
	}
	return DJLineupBlock{}, false
}

func djHarmonicBlockTrackIDs(block DJLineupBlock) []int64 {
	ids := make([]int64, 0, len(block.Tracks))
	for _, track := range block.Tracks {
		ids = append(ids, track.ID)
	}
	return ids
}

// --- D1: block identity and copy -------------------------------------------

func TestDJHarmonicLineupBlockCopy(t *testing.T) {
	if djHarmonicLineupTheme.ID != "harmonic" {
		t.Fatalf("harmonic block id = %q, want %q", djHarmonicLineupTheme.ID, "harmonic")
	}
	if djHarmonicLineupTheme.Title != "In key" {
		t.Fatalf("harmonic block title = %q, want %q", djHarmonicLineupTheme.Title, "In key")
	}
	if djHarmonicLineupTheme.Reason != "Mixes cleanly from what you just queued." {
		t.Fatalf("harmonic block reason = %q", djHarmonicLineupTheme.Reason)
	}
	// The harmonic block is additive: the frozen three-theme design contract
	// (and everything bounded by its length) must not have moved.
	if len(djLineupThemes) != 3 {
		t.Fatalf("djLineupThemes = %d entries, want 3", len(djLineupThemes))
	}
	for _, theme := range djLineupThemes {
		if theme.ID == djHarmonicLineupBlockID {
			t.Fatal("harmonic block leaked into djLineupThemes")
		}
	}

	cases := []struct {
		anchor djHarmonicAnchor
		want   string
	}{
		{anchor: djHarmonicAnchor{BPM: 128, Number: 8, Letter: 'A'}, want: "From 128 BPM · 8A"},
		{anchor: djHarmonicAnchor{BPM: 127.96, Number: 8, Letter: 'A'}, want: "From 128 BPM · 8A"},
		{anchor: djHarmonicAnchor{BPM: 122.45, Number: 12, Letter: 'B'}, want: "From 122.5 BPM · 12B"},
	}
	for _, tc := range cases {
		if got := djHarmonicLineupDetail(tc.anchor); got != tc.want {
			t.Fatalf("djHarmonicLineupDetail(%v) = %q, want %q", tc.anchor, got, tc.want)
		}
	}
}

// --- D3: anchor derivation --------------------------------------------------

func TestDJHarmonicLineupResolvesAnchorFromLibraryProjection(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandler(reader, true)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")

	if reader.calls != 1 {
		t.Fatalf("nearby reader calls = %d, want 1", reader.calls)
	}
	if reader.gotBPM != 128 {
		t.Fatalf("nearby bpm = %v, want 128 (from the anchor's compact-analysis projection)", reader.gotBPM)
	}
	if djHarmonicLineupBPMTolerance != 6 {
		t.Fatalf("djHarmonicLineupBPMTolerance = %v, want 6", float64(djHarmonicLineupBPMTolerance))
	}
	if reader.gotTolerance != djHarmonicLineupBPMTolerance {
		t.Fatalf("nearby tolerance = %v, want %v", reader.gotTolerance, float64(djHarmonicLineupBPMTolerance))
	}
	if want := []string{"7A", "8A", "8B", "9A"}; !reflect.DeepEqual(reader.gotCamelot, want) {
		t.Fatalf("nearby camelot candidates = %v, want %v", reader.gotCamelot, want)
	}
	if reader.gotRank != db.AffinityRankHistory {
		t.Fatalf("nearby rank = %q, want %q", reader.gotRank, db.AffinityRankHistory)
	}

	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}
	if block.Detail != "From 128 BPM · 8A" {
		t.Fatalf("harmonic detail = %q, want %q", block.Detail, "From 128 BPM · 8A")
	}
	if response.Blocks[0].ID != djHarmonicLineupBlockID {
		t.Fatalf("blocks[0].id = %q, want the harmonic block to lead", response.Blocks[0].ID)
	}
}

func TestDJHarmonicLineupAnchorSurvivesActivePin(t *testing.T) {
	// The pin's genre envelope excludes the anchor (Techno) but keeps every
	// candidate (House). The anchor must still resolve, because it is read
	// before the pin filter is applied.
	pin := &staticDJPinReader{blockID: "fresh-finds", energyLow: 0, energyHigh: 1, genres: []string{"House"}}
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandlerWithPin(reader, true, pin)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")

	if reader.gotBPM != 128 {
		t.Fatalf("nearby bpm = %v, want 128 despite the pin hiding the anchor", reader.gotBPM)
	}
	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}
	if want := []int64{103, 101, 104, 102}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
		t.Fatalf("harmonic track IDs = %v, want %v", djHarmonicBlockTrackIDs(block), want)
	}
}

func TestDJLineupRejectsInvalidAnchorTrackId(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandler(reader, true)

	for _, raw := range []string{"abc", "0", "-5", ""} {
		t.Run("anchorTrackId="+raw, func(t *testing.T) {
			req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/dj/lineup?anchorTrackId="+raw, nil), uuid.New())
			rec := httptest.NewRecorder()
			handler.GetLineup(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400 (body=%s)", rec.Code, rec.Body.String())
			}
			var payload struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
				t.Fatalf("decode error body: %v", err)
			}
			if payload.Code != "invalid_request" {
				t.Fatalf("code = %q, want invalid_request", payload.Code)
			}
			if payload.Message != "anchorTrackId must be a positive integer track ID" {
				t.Fatalf("message = %q", payload.Message)
			}
		})
	}
	if reader.calls != 0 {
		t.Fatalf("nearby reader calls = %d, want 0 for rejected requests", reader.calls)
	}
}

func TestDJLineupRejectsHarmonicBlockParamWhenFlagOff(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}

	off := newDJHarmonicHandler(reader, false)
	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/dj/lineup?block=harmonic", nil), uuid.New())
	rec := httptest.NewRecorder()
	off.GetLineup(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("flag-off status = %d, want 400", rec.Code)
	}
	if got, want := rec.Body.String(), `"message":"block must be one of: on-repeat, flashback, fresh-finds"`; !bytes.Contains([]byte(got), []byte(want)) {
		t.Fatalf("flag-off body = %s, want the pre-#401 enum error", got)
	}

	// Flag on, block=harmonic, no anchor: accepted, and the response is the
	// same empty-blocks shape an empty library already produces.
	on := newDJHarmonicHandler(reader, true)
	req = withUser(httptest.NewRequest(http.MethodGet, "/api/v1/dj/lineup?block=harmonic", nil), uuid.New())
	rec = httptest.NewRecorder()
	on.GetLineup(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("flag-on status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); !bytes.Contains([]byte(got), []byte(`"blocks":[]`)) {
		t.Fatalf("flag-on body = %s, want empty blocks", got)
	}
	if reader.calls != 0 {
		t.Fatalf("nearby reader calls = %d, want 0 without an anchor", reader.calls)
	}
}

// --- D4: candidate composition ---------------------------------------------

func TestDJHarmonicLineupBlockReturnsCompatibleOrderedCandidates(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandler(reader, true)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")
	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}

	// Repository affinity order minus the anchor, the 3A key mismatch (105)
	// and the 140 BPM out-of-tolerance track (106).
	if want := []int64{103, 101, 104, 102}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
		t.Fatalf("harmonic track IDs = %v, want %v", djHarmonicBlockTrackIDs(block), want)
	}
	for _, track := range block.Tracks {
		if track.ID == 105 || track.ID == 106 {
			t.Fatalf("incompatible track %d survived into the harmonic block", track.ID)
		}
		// The payload comes from the lineup projection, not the nearby
		// projection, so duration/energy/album are populated.
		if track.DurationMs == 0 || track.Energy == 0 || track.Album == "" {
			t.Fatalf("harmonic track %d lost lineup projection fields: %#v", track.ID, track)
		}
	}
}

func TestDJHarmonicLineupExcludesAnchorTrack(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandler(reader, true)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")
	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}
	for _, track := range block.Tracks {
		if track.ID == djHarmonicAnchorTrackID {
			t.Fatalf("anchor track %d appeared in its own harmonic block", track.ID)
		}
	}
}

func TestDJHarmonicLineupRespectsFiltersPinAndExcludeIds(t *testing.T) {
	t.Run("excludeIds", func(t *testing.T) {
		reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
		handler := newDJHarmonicHandler(reader, true)
		response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100&excludeIds=101")
		block, ok := djHarmonicBlock(t, response)
		if !ok {
			t.Fatalf("no harmonic block in %#v", response.Blocks)
		}
		if want := []int64{103, 104, 102}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
			t.Fatalf("harmonic track IDs = %v, want %v", djHarmonicBlockTrackIDs(block), want)
		}
	})

	t.Run("genre filter", func(t *testing.T) {
		reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
		handler := newDJHarmonicHandler(reader, true)
		response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100&genre=Disco")
		if _, ok := djHarmonicBlock(t, response); ok {
			t.Fatalf("harmonic block survived a genre filter that excludes every candidate: %#v", response.Blocks)
		}
	})

	t.Run("single themed block skips the candidate read", func(t *testing.T) {
		reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
		handler := newDJHarmonicHandler(reader, true)
		response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100&block=fresh-finds")
		if _, ok := djHarmonicBlock(t, response); ok {
			t.Fatalf("harmonic block appeared for block=fresh-finds: %#v", response.Blocks)
		}
		if reader.calls != 0 {
			t.Fatalf("nearby reader calls = %d, want 0 when a single themed block was requested", reader.calls)
		}
	})

	t.Run("active pin envelope", func(t *testing.T) {
		// Energy envelope keeps 103 (0.66), 101 (0.70) and 104 (0.68) but
		// drops 102 (0.72): the pin governs which candidates may appear.
		pin := &staticDJPinReader{blockID: "on-repeat", energyLow: 0.65, energyHigh: 0.71}
		reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
		handler := newDJHarmonicHandlerWithPin(reader, true, pin)
		response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")
		block, ok := djHarmonicBlock(t, response)
		if !ok {
			t.Fatalf("no harmonic block in %#v", response.Blocks)
		}
		if want := []int64{103, 101, 104}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
			t.Fatalf("harmonic track IDs = %v, want %v", djHarmonicBlockTrackIDs(block), want)
		}
	})
}

func TestDJHarmonicLineupDegradesWhenNearbyReadFails(t *testing.T) {
	const rawURL = "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100"

	failing := &recordingNearbyReader{err: errors.New("nearby search unavailable")}
	got := djHarmonicRawResponse(t, newDJHarmonicHandler(failing, true), rawURL)
	if failing.calls != 1 {
		t.Fatalf("nearby reader calls = %d, want 1", failing.calls)
	}

	want := djHarmonicRawResponse(t, newDJHarmonicHandler(&recordingNearbyReader{}, false), rawURL)
	if !bytes.Equal(got, want) {
		t.Fatalf("failed candidate read did not degrade to the themed lineup:\n got: %s\nwant: %s", got, want)
	}
	if !bytes.HasPrefix(got, []byte("status: 200\n")) {
		t.Fatalf("status = %s, want 200", got[:12])
	}
}

func TestDJHarmonicLineupDoesNotRepeatTracksInThemedBlocks(t *testing.T) {
	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	handler := newDJHarmonicHandler(reader, true)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100")
	if len(response.Blocks) < 2 {
		t.Fatalf("want the harmonic block plus themed blocks, got %#v", response.Blocks)
	}
	seen := make(map[int64]string, 16)
	for _, block := range response.Blocks {
		for _, track := range block.Tracks {
			if previous, duplicate := seen[track.ID]; duplicate {
				t.Fatalf("track %d appears in both %q and %q", track.ID, previous, block.ID)
			}
			seen[track.ID] = block.ID
		}
	}
	// The harmonic candidates are unplayed, so they would otherwise be
	// fresh-finds material: this is the invariant that actually bites.
	for _, block := range response.Blocks {
		if block.ID != "fresh-finds" {
			continue
		}
		for _, track := range block.Tracks {
			for _, harmonicID := range []int64{101, 102, 103, 104} {
				if track.ID == harmonicID {
					t.Fatalf("harmonic track %d was re-served by fresh-finds", track.ID)
				}
			}
		}
	}
}

// --- D5: silent, exact fallback --------------------------------------------

func TestDJHarmonicLineupFallsBackWithoutQueueTail(t *testing.T) {
	const rawURL = "/api/v1/dj/lineup?perBlock=10"

	reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
	got := djHarmonicRawResponse(t, newDJHarmonicHandler(reader, true), rawURL)
	if reader.calls != 0 {
		t.Fatalf("nearby reader calls = %d, want 0 without anchorTrackId", reader.calls)
	}

	want := djHarmonicRawResponse(t, newDJHarmonicHandler(&recordingNearbyReader{}, false), rawURL)
	if !bytes.Equal(got, want) {
		t.Fatalf("flag-on response without an anchor differs from flag-off:\n got: %s\nwant: %s", got, want)
	}
}

func TestDJHarmonicLineupFallsBackWhenAnchorLacksAnalysis(t *testing.T) {
	cases := map[string]string{
		"unanalyzed anchor":     "/api/v1/dj/lineup?perBlock=10&anchorTrackId=107",
		"anchor not in library": "/api/v1/dj/lineup?perBlock=10&anchorTrackId=999",
	}
	for name, rawURL := range cases {
		t.Run(name, func(t *testing.T) {
			reader := &recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}
			got := djHarmonicRawResponse(t, newDJHarmonicHandler(reader, true), rawURL)
			if reader.calls != 0 {
				t.Fatalf("nearby reader calls = %d, want 0 for an unresolvable anchor", reader.calls)
			}
			want := djHarmonicRawResponse(t, newDJHarmonicHandler(&recordingNearbyReader{}, false), rawURL)
			if !bytes.Equal(got, want) {
				t.Fatalf("unresolvable anchor changed the response:\n got: %s\nwant: %s", got, want)
			}
		})
	}
}

func TestDJHarmonicLineupFallsBackBelowCandidateFloor(t *testing.T) {
	if djHarmonicLineupMinCandidates != 3 {
		t.Fatalf("djHarmonicLineupMinCandidates = %d, want 3", djHarmonicLineupMinCandidates)
	}

	const rawURL = "/api/v1/dj/lineup?perBlock=10&anchorTrackId=100"
	// Two compatible candidates plus both rejects: still below the floor.
	thin := &recordingNearbyReader{tracks: []db.NearbyTrack{
		nearbyCandidate(103, 124, "8B"),
		nearbyCandidate(101, 127, "8A"),
		nearbyCandidate(105, 128, "3A"),
		nearbyCandidate(106, 140, "8A"),
	}}
	got := djHarmonicRawResponse(t, newDJHarmonicHandler(thin, true), rawURL)
	want := djHarmonicRawResponse(t, newDJHarmonicHandler(&recordingNearbyReader{}, false), rawURL)
	if !bytes.Equal(got, want) {
		t.Fatalf("two compatible candidates produced a block:\n got: %s\nwant: %s", got, want)
	}
}

// --- D6: determinism --------------------------------------------------------

func TestDJHarmonicLineupIsDeterministicForSeed(t *testing.T) {
	const rawURL = "/api/v1/dj/lineup?perBlock=10&seed=73&anchorTrackId=100"
	handler := newDJHarmonicHandler(&recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}, true)

	first := djHarmonicRawResponse(t, handler, rawURL)
	second := djHarmonicRawResponse(t, handler, rawURL)
	if !bytes.Equal(first, second) {
		t.Fatalf("same seed produced different responses:\n first: %s\nsecond: %s", first, second)
	}

	// perBlock=2 against a 4-track candidate pool: the seed must actually
	// steer which two are chosen, or the block is not seeded at all.
	selections := make(map[string]struct{})
	for seed := 1; seed <= 20; seed++ {
		url := fmt.Sprintf("/api/v1/dj/lineup?perBlock=2&seed=%d&anchorTrackId=100", seed)
		response := requestDJLineup(t, handler, url)
		block, ok := djHarmonicBlock(t, response)
		if !ok {
			t.Fatalf("seed %d produced no harmonic block", seed)
		}
		if len(block.Tracks) != 2 {
			t.Fatalf("seed %d selected %d tracks, want 2", seed, len(block.Tracks))
		}
		selections[fmt.Sprint(djHarmonicBlockTrackIDs(block))] = struct{}{}
	}
	if len(selections) < 2 {
		t.Fatalf("every seed selected the same harmonic tracks (%v): the seed is not consumed", selections)
	}
}

func TestDJHarmonicLineupOutputIsAffinityOrdered(t *testing.T) {
	handler := newDJHarmonicHandler(&recordingNearbyReader{tracks: djHarmonicFixtureCandidates()}, true)

	// perBlock >= candidate count: the whole pool is selected, so the emitted
	// order must be the repository order minus the filtered entries.
	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?perBlock=10&seed=99991&anchorTrackId=100")
	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}
	if want := []int64{103, 101, 104, 102}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
		t.Fatalf("harmonic track IDs = %v, want repository affinity order %v", djHarmonicBlockTrackIDs(block), want)
	}

	// Every seed must keep that order, even though each seed shuffles a
	// different pool: selection picks, affinity orders.
	for seed := 1; seed <= 20; seed++ {
		url := fmt.Sprintf("/api/v1/dj/lineup?perBlock=10&seed=%d&anchorTrackId=100", seed)
		response := requestDJLineup(t, handler, url)
		block, ok := djHarmonicBlock(t, response)
		if !ok {
			t.Fatalf("seed %d produced no harmonic block", seed)
		}
		if want := []int64{103, 101, 104, 102}; !reflect.DeepEqual(djHarmonicBlockTrackIDs(block), want) {
			t.Fatalf("seed %d order = %v, want %v", seed, djHarmonicBlockTrackIDs(block), want)
		}
	}
}
