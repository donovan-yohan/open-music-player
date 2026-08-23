package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func newPlayEventTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres play-event integration tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE play_events, user_library, tracks, users RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
}

func seedPlayUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedPlayTrack(t *testing.T, repo *TrackRepository, ctx context.Context, artist, title string) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, artist, title, title+" Album", 200000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// insertPlayAt inserts a play event at an explicit played_at so ordering and
// windowing can be asserted deterministically.
func insertPlayAt(t *testing.T, database *DB, userID uuid.UUID, trackID int64, at time.Time) {
	t.Helper()
	if _, err := database.Exec(
		`INSERT INTO play_events (user_id, track_id, played_at, context_type) VALUES ($1, $2, $3, 'library')`,
		userID, trackID, at); err != nil {
		t.Fatalf("insert play event: %v", err)
	}
}

// insertSkipAt inserts a skipped play event at an explicit played_at so
// skip-aware listing behavior can be asserted deterministically.
func insertSkipAt(t *testing.T, database *DB, userID uuid.UUID, trackID int64, at time.Time) {
	t.Helper()
	if _, err := database.Exec(
		`INSERT INTO play_events (user_id, track_id, played_at, skipped) VALUES ($1, $2, $3, TRUE)`,
		userID, trackID, at); err != nil {
		t.Fatalf("insert skip event: %v", err)
	}
}

func TestPlayEventRecordAndListingsAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	repo := NewPlayEventRepository(database)

	user := seedPlayUser(t, database, "primary@example.test")
	other := seedPlayUser(t, database, "other@example.test")

	trackA := seedPlayTrack(t, trackRepo, ctx, "Artist A", "Alpha")
	trackB := seedPlayTrack(t, trackRepo, ctx, "Artist B", "Bravo")
	trackC := seedPlayTrack(t, trackRepo, ctx, "Artist C", "Charlie")

	// RecordPlay inserts exactly one row with a server-set played_at.
	before := time.Now().Add(-2 * time.Second)
	if err := repo.RecordPlay(ctx, user, trackA, "playlist", "pl-1"); err != nil {
		t.Fatalf("RecordPlay: %v", err)
	}
	after := time.Now().Add(2 * time.Second)

	var count int
	var playedAt time.Time
	var ctxType sql.NullString
	if err := database.QueryRow(
		`SELECT COUNT(*), MAX(played_at), MAX(context_type) FROM play_events WHERE user_id = $1`, user).
		Scan(&count, &playedAt, &ctxType); err != nil {
		t.Fatalf("count play events: %v", err)
	}
	if count != 1 {
		t.Fatalf("play event count = %d, want 1", count)
	}
	if playedAt.Before(before) || playedAt.After(after) {
		t.Fatalf("played_at = %v, want server time within [%v, %v]", playedAt, before, after)
	}
	if !ctxType.Valid || ctxType.String != "playlist" {
		t.Fatalf("context_type = %#v, want playlist", ctxType)
	}

	// Build a richer history for recency/dedup/top assertions. The RecordPlay above
	// stamped trackA at (real) NOW, which is the most recent play overall. All
	// subsequent plays are inserted at explicit past times relative to `now`.
	now := time.Now()
	// user history (most-recent-play per track):
	//   trackA: NOW (RecordPlay) + -40d (out of window) + -3h  -> most recent overall
	//   trackB: -1min
	//   trackC: -10h, -9h
	insertPlayAt(t, database, user, trackA, now.Add(-40*24*time.Hour)) // out of 30d window
	insertPlayAt(t, database, user, trackA, now.Add(-3*time.Hour))
	insertPlayAt(t, database, user, trackC, now.Add(-10*time.Hour))
	insertPlayAt(t, database, user, trackC, now.Add(-9*time.Hour))
	insertPlayAt(t, database, user, trackB, now.Add(-1*time.Minute))

	// other user has plays that must never leak into user's listings.
	insertPlayAt(t, database, other, trackA, now.Add(-1*time.Second))
	insertPlayAt(t, database, other, trackC, now.Add(-1*time.Second))

	// Recently played: deduped by track, newest first.
	recent, err := repo.RecentlyPlayed(ctx, user, 10, 0)
	if err != nil {
		t.Fatalf("RecentlyPlayed: %v", err)
	}
	if len(recent) != 3 {
		t.Fatalf("recent len = %d, want 3 (deduped)", len(recent))
	}
	// Most-recent play order: trackA (NOW) > trackB (-1min) > trackC (-9h).
	if recent[0].ID != trackA {
		t.Fatalf("recent[0] = %d, want trackA %d", recent[0].ID, trackA)
	}
	if recent[1].ID != trackB {
		t.Fatalf("recent[1] = %d, want trackB %d", recent[1].ID, trackB)
	}
	if recent[2].ID != trackC {
		t.Fatalf("recent[2] = %d, want trackC %d", recent[2].ID, trackC)
	}
	// Ensure descending by last-played time.
	if recent[0].LastPlayedAt.Before(recent[1].LastPlayedAt) || recent[1].LastPlayedAt.Before(recent[2].LastPlayedAt) {
		t.Fatalf("recent not sorted newest-first: %v, %v, %v",
			recent[0].LastPlayedAt, recent[1].LastPlayedAt, recent[2].LastPlayedAt)
	}

	// Limit/offset honored: first page of 1, then page 2.
	page1, err := repo.RecentlyPlayed(ctx, user, 1, 0)
	if err != nil {
		t.Fatalf("RecentlyPlayed page1: %v", err)
	}
	if len(page1) != 1 || page1[0].ID != trackA {
		t.Fatalf("page1 = %#v, want single trackA", page1)
	}
	page2, err := repo.RecentlyPlayed(ctx, user, 1, 1)
	if err != nil {
		t.Fatalf("RecentlyPlayed page2: %v", err)
	}
	if len(page2) != 1 || page2[0].ID != trackB {
		t.Fatalf("page2 = %#v, want single trackB", page2)
	}

	// Full play history preserves every play event, newest first, including
	// repeated listens of the same track.
	history, err := repo.PlayHistory(ctx, user, 10, 0)
	if err != nil {
		t.Fatalf("PlayHistory: %v", err)
	}
	if len(history) != 6 {
		t.Fatalf("history len = %d, want 6 raw play events", len(history))
	}
	wantHistoryOrder := []int64{trackA, trackB, trackA, trackC, trackC, trackA}
	for i, wantTrackID := range wantHistoryOrder {
		if history[i].Track.ID != wantTrackID {
			t.Fatalf("history[%d] track = %d, want %d", i, history[i].Track.ID, wantTrackID)
		}
	}
	if !history[0].ContextType.Valid || history[0].ContextType.String != "playlist" {
		t.Fatalf("history[0] context_type = %#v, want playlist from RecordPlay", history[0].ContextType)
	}
	historyPage2, err := repo.PlayHistory(ctx, user, 2, 2)
	if err != nil {
		t.Fatalf("PlayHistory page2: %v", err)
	}
	if len(historyPage2) != 2 || historyPage2[0].Track.ID != trackA || historyPage2[1].Track.ID != trackC {
		t.Fatalf("history page2 = %#v, want trackA then trackC", historyPage2)
	}

	// Top tracks within 30 days: trackA has 3 in-window plays (RecordPlay~now,
	// -3h, plus... wait -40d is out) -> in-window trackA count = 2 (now + -3h),
	// trackC count = 2, trackB count = 1. Order by count desc then recency:
	// trackA and trackC both 2; trackA most-recent (now) beats trackC (-9h).
	top, err := repo.TopTracks(ctx, user, 30, 10)
	if err != nil {
		t.Fatalf("TopTracks: %v", err)
	}
	if len(top) != 3 {
		t.Fatalf("top len = %d, want 3", len(top))
	}
	if top[0].ID != trackA || top[0].PlayCount != 2 {
		t.Fatalf("top[0] = id %d count %d, want trackA %d count 2", top[0].ID, top[0].PlayCount, trackA)
	}
	if top[1].ID != trackC || top[1].PlayCount != 2 {
		t.Fatalf("top[1] = id %d count %d, want trackC %d count 2", top[1].ID, top[1].PlayCount, trackC)
	}
	if top[2].ID != trackB || top[2].PlayCount != 1 {
		t.Fatalf("top[2] = id %d count %d, want trackB %d count 1", top[2].ID, top[2].PlayCount, trackB)
	}

	// A short window excludes tracks whose only plays fall outside it: use 1 day.
	// Within 1 day: trackA (now, -3h) = 2, trackC (-10h, -9h) = 2, trackB (-1m) = 1.
	// Seed a track with only an out-of-window play to prove 0-count absence.
	trackD := seedPlayTrack(t, trackRepo, ctx, "Artist D", "Delta")
	insertPlayAt(t, database, user, trackD, now.Add(-100*24*time.Hour))
	topWindow, err := repo.TopTracks(ctx, user, 30, 10)
	if err != nil {
		t.Fatalf("TopTracks window: %v", err)
	}
	for _, tt := range topWindow {
		if tt.ID == trackD {
			t.Fatalf("trackD with only out-of-window plays must be absent from top tracks")
		}
	}
}

func TestPlayEventsIndexExists(t *testing.T) {
	database, _ := newPlayEventTestDB(t)

	var exists bool
	if err := database.QueryRow(
		`SELECT EXISTS(
			SELECT 1 FROM pg_indexes
			WHERE tablename = 'play_events' AND indexname = 'idx_play_events_user_played_at'
		)`).Scan(&exists); err != nil {
		t.Fatalf("query pg_indexes: %v", err)
	}
	if !exists {
		t.Fatal("expected idx_play_events_user_played_at index on play_events(user_id, played_at DESC)")
	}
}

// TestSkipsExcludedFromAggregates pins the skip semantics: a skip is not a
// listen, so a track whose only events are skips stays out of RecentlyPlayed
// and TopTracks and remains fresh-finds eligible (zero play counts in the DJ
// lineup projection), while PlayHistory keeps the skip with skipped=true.
func TestSkipsExcludedFromAggregates(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	playRepo := NewPlayEventRepository(database)

	user := seedPlayUser(t, database, "skips@example.test")
	skipOnly := seedPlayTrack(t, trackRepo, ctx, "Artist S", "SkipOnly")
	mixed := seedPlayTrack(t, trackRepo, ctx, "Artist M", "Mixed")

	now := time.Now()
	insertSkipAt(t, database, user, skipOnly, now.Add(-5*time.Minute))
	insertSkipAt(t, database, user, mixed, now.Add(-4*time.Minute))
	insertPlayAt(t, database, user, mixed, now.Add(-3*time.Minute))

	recent, err := playRepo.RecentlyPlayed(ctx, user, 10, 0)
	if err != nil {
		t.Fatalf("RecentlyPlayed: %v", err)
	}
	if len(recent) != 1 || recent[0].ID != mixed {
		t.Fatalf("recent = %#v, want only the played track %d (skip-only track must be absent)", recentIDs(recent), mixed)
	}

	top, err := playRepo.TopTracks(ctx, user, 30, 10)
	if err != nil {
		t.Fatalf("TopTracks: %v", err)
	}
	if len(top) != 1 || top[0].ID != mixed || top[0].PlayCount != 1 {
		t.Fatalf("top = %#v, want only track %d count 1 (skips must not count as plays)", topTrackSummary(top), mixed)
	}

	history, err := playRepo.PlayHistory(ctx, user, 10, 0)
	if err != nil {
		t.Fatalf("PlayHistory: %v", err)
	}
	if len(history) != 3 {
		t.Fatalf("history len = %d, want 3 raw events including both skips", len(history))
	}
	for _, event := range history {
		switch event.Track.ID {
		case skipOnly:
			if !event.Skipped {
				t.Fatalf("history event for skip-only track %d must carry skipped=true", event.Track.ID)
			}
		case mixed:
		default:
			t.Fatalf("unexpected history event for unknown track %d", event.Track.ID)
		}
	}
	// mixed has exactly one skip event and one listen event in history.
	mixedSkips, mixedPlays := 0, 0
	for _, event := range history {
		if event.Track.ID != mixed {
			continue
		}
		if event.Skipped {
			mixedSkips++
		} else {
			mixedPlays++
		}
	}
	if mixedSkips != 1 || mixedPlays != 1 {
		t.Fatalf("mixed-track history = %d skips / %d plays, want 1 of each with correct skipped flags", mixedSkips, mixedPlays)
	}

	// DJ lineup projection: the skip-only track keeps zero play counts so it is
	// still fresh-finds eligible; the played track counts exactly one play.
	lineupRepo := NewDJLineupRepository(database)
	if _, err := database.Exec(
		`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2), ($1, $3)`, user, skipOnly, mixed); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	tracks, err := lineupRepo.ListDJLineupTracks(ctx, user)
	if err != nil {
		t.Fatalf("ListDJLineupTracks: %v", err)
	}
	counts := make(map[int64]DJLineupTrack, len(tracks))
	for _, track := range tracks {
		counts[track.ID] = track
	}
	skipStats := counts[skipOnly]
	if skipStats.TotalPlayCount != 0 || skipStats.RecentPlayCount != 0 ||
		skipStats.HistoricalPlayCount != 0 || skipStats.MidWindowPlayCount != 0 {
		t.Fatalf("skip-only track play stats = %#v, want all-zero counts (fresh-finds eligibility)", skipStats)
	}
	mixedStats := counts[mixed]
	if mixedStats.TotalPlayCount != 1 || mixedStats.RecentPlayCount != 1 {
		t.Fatalf("played track stats = %#v, want total=1 recent=1 (skip excluded from counts)", mixedStats)
	}
}

func recentIDs(tracks []RecentlyPlayedTrack) []int64 {
	ids := make([]int64, 0, len(tracks))
	for _, t := range tracks {
		ids = append(ids, t.ID)
	}
	return ids
}

func topTrackSummary(tracks []TopTrack) []string {
	summaries := make([]string, 0, len(tracks))
	for _, t := range tracks {
		summaries = append(summaries, fmt.Sprintf("{id:%d count:%d}", t.ID, t.PlayCount))
	}
	return summaries
}
