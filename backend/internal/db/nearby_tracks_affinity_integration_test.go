package db

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
)

// seedAffinityTrack creates a track in the user's library analyzed at the given
// BPM/Camelot so it is always harmonically feasible for the query used below.
func seedAffinityTrack(t *testing.T, trackRepo *TrackRepository, libraryRepo *LibraryRepository, analysisRepo *AnalysisRepository, ctx context.Context, userID uuid.UUID, title string) int64 {
	t.Helper()
	trackID := seedPlayTrack(t, trackRepo, ctx, "Affinity", title)
	if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
		t.Fatalf("add track %q to library: %v", title, err)
	}
	seedNearbyAnalysis(t, analysisRepo, ctx, trackID, 120, "1A")
	return trackID
}

func nearbyTrackIDs(tracks []NearbyTrack) []int64 {
	ids := make([]int64, len(tracks))
	for i, track := range tracks {
		ids[i] = track.ID
	}
	return ids
}

func assertInt64Slice(t *testing.T, got, want []int64) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("track IDs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("track IDs = %v, want %v (order mismatch at %d)", got, want, i)
		}
	}
}

// AC: empty-history users fall back to pure harmonic ordering.
func TestNearbyTracksHistoryRankFallsBackToHarmonicOrderWithoutPlays(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "affinity-empty@example.test")

	zulu := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Zulu")
	alpha := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Alpha")
	mike := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Mike")

	tracks, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRankHistory)
	if err != nil {
		t.Fatalf("history-ranked nearby query: %v", err)
	}
	assertInt64Slice(t, nearbyTrackIDs(tracks), []int64{alpha, mike, zulu})
}

// AC: zero-play artists score below artists with plays; a recently-played
// track outranks an equally-played older track (recency dominance).
func TestNearbyTracksHistoryRankPrefersRecentPlaysAndRanksZeroPlayLast(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	playRepo := NewPlayEventRepository(database)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "affinity-recency@example.test")

	old := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Old Played")
	recent := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Recent Played")
	unplayed := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Unplayed")

	now := time.Now()
	// Same play count (one each), different ages: recency must win.
	if err := playRepo.RecordPlay(ctx, userID, old, "library", ""); err != nil {
		t.Fatalf("record old play: %v", err)
	}
	insertPlayAt(t, database, userID, recent, now.Add(-time.Hour))
	// Backdate the "old" play far beyond one half-life.
	if _, err := database.Exec(
		`UPDATE play_events SET played_at = $3 WHERE user_id = $1 AND track_id = $2`,
		userID, old, now.Add(-10*24*time.Hour)); err != nil {
		t.Fatalf("backdate old play: %v", err)
	}
	// A skip must not count toward affinity.
	insertSkipAt(t, database, userID, unplayed, now)

	tracks, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRankHistory)
	if err != nil {
		t.Fatalf("history-ranked nearby query: %v", err)
	}
	assertInt64Slice(t, nearbyTrackIDs(tracks), []int64{recent, old, unplayed})
}

// AC: deterministic total order — identical inputs produce identical order
// across runs, and equal-affinity ties break by bpm proximity then title/id.
func TestNearbyTracksHistoryRankIsDeterministicAcrossRuns(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	playRepo := NewPlayEventRepository(database)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "affinity-determinism@example.test")

	bravo := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Bravo")
	charlie := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Charlie")
	if err := playRepo.RecordPlay(ctx, userID, charlie, "library", ""); err != nil {
		t.Fatalf("record play: %v", err)
	}
	if err := playRepo.RecordPlay(ctx, userID, bravo, "library", ""); err != nil {
		t.Fatalf("record play: %v", err)
	}
	// Equal affinity (same age/count): tie-break falls through to title asc.
	for i := 0; i < 5; i++ {
		tracks, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRankHistory)
		if err != nil {
			t.Fatalf("run %d: history-ranked nearby query: %v", i, err)
		}
		assertInt64Slice(t, nearbyTrackIDs(tracks), []int64{bravo, charlie})
	}
}

// AC: ordering composes with the harmonic filter — incompatible-key /
// out-of-tolerance tracks never enter the result regardless of affinity.
func TestNearbyTracksHistoryRankComposesWithHarmonicFilter(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	playRepo := NewPlayEventRepository(database)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "affinity-compose@example.test")

	feasible := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Feasible")
	wrongKey := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Wrong Key")
	outOfTolerance := seedAffinityTrack(t, trackRepo, libraryRepo, analysisRepo, ctx, userID, "Out Of Tolerance")

	// Make the incompatible tracks far more desirable by affinity.
	for _, trackID := range []int64{wrongKey, outOfTolerance} {
		for i := 0; i < 10; i++ {
			if err := playRepo.RecordPlay(ctx, userID, trackID, "library", ""); err != nil {
				t.Fatalf("record play: %v", err)
			}
		}
	}
	seedNearbyAnalysis(t, analysisRepo, ctx, wrongKey, 120, "8B")       // incompatible key
	seedNearbyAnalysis(t, analysisRepo, ctx, outOfTolerance, 180, "1A") // out of BPM tolerance

	tracks, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRankHistory)
	if err != nil {
		t.Fatalf("history-ranked nearby query: %v", err)
	}
	assertInt64Slice(t, nearbyTrackIDs(tracks), []int64{feasible})

	// The default rank keeps the same feasible set.
	tracks, err = libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRankOff)
	if err != nil {
		t.Fatalf("default nearby query: %v", err)
	}
	assertInt64Slice(t, nearbyTrackIDs(tracks), []int64{feasible})
}

// Invalid ranking options are rejected like other invalid query facts.
func TestNearbyTracksRejectsUnknownAffinityRank(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	libraryRepo := NewLibraryRepository(database)
	userID := seedPlayUser(t, database, "affinity-invalid@example.test")

	if _, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"}, AffinityRank("vibes")); err == nil {
		t.Fatal("unknown affinity rank accepted, want ErrInvalidNearbyTrackQuery")
	}
}
