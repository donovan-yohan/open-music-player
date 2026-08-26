package api

import (
	"math"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

// TestDJHarmonicLineupIntegrationAnchorsOnRealAnalysisProjection drives the
// harmonic block end to end against a real Postgres: the anchor's BPM/camelot
// come from the same track_analysis projection the candidate query filters on,
// and the emitted block is the affinity-ranked, harmonically feasible set.
//
// Play events are seeded days apart so the affinity SQL's NOW()-relative
// exponential decay cannot flip the expected ordering between runs.
func TestDJHarmonicLineupIntegrationAnchorsOnRealAnalysisProjection(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)
	userID := seedMixUser(t, database, "dj-harmonic@example.test")

	seed := func(title string, bpm float64, camelot string) int64 {
		t.Helper()
		trackID := seedMixTrack(t, trackRepo, ctx, title, 210000)
		if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
			t.Fatalf("add %q to library: %v", title, err)
		}
		seedNearbyTrackAnalysis(t, analysisRepo, ctx, trackID, bpm, camelot)
		return trackID
	}
	playAt := func(trackID int64, daysAgo int) {
		t.Helper()
		at := time.Now().UTC().AddDate(0, 0, -daysAgo)
		if _, err := database.Exec(
			`INSERT INTO play_events (user_id, track_id, played_at, context_type) VALUES ($1, $2, $3, 'library')`,
			userID, trackID, at); err != nil {
			t.Fatalf("insert play event: %v", err)
		}
	}

	// Anchor is 128 BPM / 8A: compatible keys are {7A, 8A, 8B, 9A} and the
	// tolerance window is [122, 134].
	anchor := seed("Anchor", 128, "8A")
	sameKey := seed("Same key", 127, "8A")
	adjacentKey := seed("Adjacent key", 130, "9A")
	oppositeKey := seed("Opposite letter", 124, "8B")
	neverPlayed := seed("Never played", 132, "7A")
	wrongKey := seed("Wrong key", 128, "3A")
	tooFast := seed("Too fast", 140, "8A")

	// Affinity ordering: most recently played first, never-played last.
	playAt(adjacentKey, 1)
	playAt(sameKey, 10)
	playAt(oppositeKey, 30)

	handler := NewDJLineupHandlersWithHarmonicCandidates(
		db.NewDJLineupRepository(database), nil, nil, libraryRepo, true)

	rawURL := "/api/v1/dj/lineup?perBlock=10&anchorTrackId=" + itoa64(anchor)
	req := withUser(httptest.NewRequest(http.MethodGet, rawURL, nil), userID)
	rec := httptest.NewRecorder()
	handler.GetLineup(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s status = %d, body = %s", rawURL, rec.Code, rec.Body.String())
	}
	response := decodeDJLineupResponse(t, rec)

	block, ok := djHarmonicBlock(t, response)
	if !ok {
		t.Fatalf("no harmonic block in %#v", response.Blocks)
	}

	// (a) the anchor resolved from the real compact-analysis projection.
	if block.Detail != "From 128 BPM · 8A" {
		t.Fatalf("harmonic detail = %q, want %q", block.Detail, "From 128 BPM · 8A")
	}

	// (b) every emitted candidate is harmonically compatible and in tolerance.
	for _, track := range block.Tracks {
		if track.ID == anchor {
			t.Fatalf("anchor track %d appeared in its own block", track.ID)
		}
		if track.ID == wrongKey || track.ID == tooFast {
			t.Fatalf("incompatible track %d survived: %#v", track.ID, block.Tracks)
		}
		number, letter, parsed := autoBlendParseCamelot(track.Camelot)
		compatible, _ := autoBlendCamelotDistance(8, 'A', true, number, letter, parsed)
		if !compatible {
			t.Fatalf("track %d camelot %q is not compatible with 8A", track.ID, track.Camelot)
		}
		if math.Abs(track.BPM-128) > djHarmonicLineupBPMTolerance {
			t.Fatalf("track %d bpm %v is outside +/-%v of 128", track.ID, track.BPM, float64(djHarmonicLineupBPMTolerance))
		}
	}

	// (c) affinity order: recent plays first, never-played last.
	want := []int64{adjacentKey, sameKey, oppositeKey, neverPlayed}
	if got := djHarmonicBlockTrackIDs(block); !reflect.DeepEqual(got, want) {
		t.Fatalf("harmonic track IDs = %v, want affinity order %v", got, want)
	}
}

// TestDJHarmonicLineupIntegrationFallsBackForUnanalyzedAnchor proves the
// fallback is exact against a real database: an anchor with no analysis row
// yields the themed lineup, byte-for-byte.
func TestDJHarmonicLineupIntegrationFallsBackForUnanalyzedAnchor(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)
	userID := seedMixUser(t, database, "dj-harmonic-fallback@example.test")

	unanalyzed := seedMixTrack(t, trackRepo, ctx, "Unanalyzed anchor", 200000)
	if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, unanalyzed); err != nil {
		t.Fatalf("add unanalyzed track to library: %v", err)
	}
	analyzed := seedMixTrack(t, trackRepo, ctx, "Analyzed neighbour", 200000)
	if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, analyzed); err != nil {
		t.Fatalf("add analyzed track to library: %v", err)
	}
	seedNearbyTrackAnalysis(t, analysisRepo, ctx, analyzed, 128, "8A")

	lineupRepo := db.NewDJLineupRepository(database)

	// The anchor rejection itself, against the real projection: an unanalyzed
	// row comes back with no usable BPM/camelot and the resolver refuses it,
	// while the analyzed neighbour resolves from the same read. Without this,
	// relaxing resolveDJHarmonicAnchor's validation would still leave the
	// response comparison below green, because a bogus anchor simply matches
	// no candidates.
	projection, err := lineupRepo.ListDJLineupTracks(ctx, userID)
	if err != nil {
		t.Fatalf("list lineup tracks: %v", err)
	}
	if _, resolved := resolveDJHarmonicAnchor(projection, unanalyzed); resolved {
		t.Fatalf("unanalyzed track %d resolved as a harmonic anchor: %#v", unanalyzed, projection)
	}
	if _, resolved := resolveDJHarmonicAnchor(projection, analyzed); !resolved {
		t.Fatalf("analyzed track %d did not resolve as a harmonic anchor: %#v", analyzed, projection)
	}

	rawURL := "/api/v1/dj/lineup?perBlock=10&anchorTrackId=" + itoa64(unanalyzed)

	on := NewDJLineupHandlersWithHarmonicCandidates(lineupRepo, nil, nil, libraryRepo, true)
	off := NewDJLineupHandlersWithHarmonicCandidates(lineupRepo, nil, nil, libraryRepo, false)

	// Both arms must authenticate as the seeded user: requesting as anyone
	// else returns the empty-library envelope from both handlers, and the
	// byte comparison would then hold even with the fallback fully broken.
	got := djHarmonicRawResponseAs(t, on, rawURL, userID)
	want := djHarmonicRawResponseAs(t, off, rawURL, userID)

	// Non-triviality gate: the compared response has to actually carry the
	// seeded rows, or this test proves nothing about the fallback.
	baseline := decodeDJHarmonicRawResponse(t, want)
	if len(baseline.Blocks) == 0 {
		t.Fatalf("flag-off arm returned no blocks; the seeded library was not read: %s", want)
	}
	if !djLineupContainsTrack(baseline, analyzed) {
		t.Fatalf("analyzed neighbour %d is missing from the themed lineup: %s", analyzed, want)
	}

	if string(got) != string(want) {
		t.Fatalf("unanalyzed anchor changed the response:\n got: %s\nwant: %s", got, want)
	}
	// And the fallback is an omission, not a degraded block.
	if _, present := djHarmonicBlock(t, decodeDJHarmonicRawResponse(t, got)); present {
		t.Fatalf("unanalyzed anchor still produced a harmonic block: %s", got)
	}
}
