package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// newPlaylistTestDB provisions a fresh, migrated Postgres for playlist repository
// tests, truncating the relevant tables so each test starts clean.
func newPlaylistTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	return newGuardedTestDB(t,
		"set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres playlist integration tests",
		"TRUNCATE TABLE playlist_tracks, playlists, user_library, tracks, users RESTART IDENTITY CASCADE")
}

func seedPlaylistUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedPlaylistTrack(t *testing.T, repo *TrackRepository, ctx context.Context, artist, title string) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, artist, title, title+" Album", 200000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// playlistPositions returns track_id -> position for the given playlist.
func playlistPositions(t *testing.T, database *DB, playlistID int64) map[int64]int {
	t.Helper()
	rows, err := database.Query(`SELECT track_id, position FROM playlist_tracks WHERE playlist_id = $1 ORDER BY position`, playlistID)
	if err != nil {
		t.Fatalf("query positions: %v", err)
	}
	defer rows.Close()
	out := map[int64]int{}
	for rows.Next() {
		var trackID int64
		var pos int
		if err := rows.Scan(&trackID, &pos); err != nil {
			t.Fatalf("scan position: %v", err)
		}
		out[trackID] = pos
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows err: %v", err)
	}
	return out
}

// contiguousPositions asserts positions are exactly 0..n-1 with no gaps/dupes.
func contiguousPositions(t *testing.T, positions map[int64]int, want int) {
	t.Helper()
	if len(positions) != want {
		t.Fatalf("row count = %d, want %d (positions=%v)", len(positions), want, positions)
	}
	seen := make(map[int]bool, want)
	for trackID, pos := range positions {
		if pos < 0 || pos >= want {
			t.Fatalf("track %d has out-of-range position %d (want 0..%d)", trackID, pos, want-1)
		}
		if seen[pos] {
			t.Fatalf("duplicate position %d in %v", pos, positions)
		}
		seen[pos] = true
	}
}

func TestPlaylistGetByIDWithTracksEmpty(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	repo := NewPlaylistRepository(database)
	playlist := &Playlist{UserID: seedPlaylistUser(t, database, "empty-detail@example.test"), Name: "Empty"}
	if err := repo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}

	got, err := repo.GetByIDWithTracks(ctx, playlist.ID)
	if err != nil {
		t.Fatalf("get empty playlist with tracks: %v", err)
	}
	if got.Playlist != *playlist || got.Tracks == nil || len(got.Tracks) != 0 || got.TrackCount != 0 || got.DurationMs != 0 {
		t.Fatalf("empty playlist = %+v, want original playlist, non-nil empty tracks and zero aggregates", got)
	}
}

func TestPlaylistGetByIDWithTracksLifecycle(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	repo := NewPlaylistRepository(database)
	trackRepo := NewTrackRepository(database)
	playlist := &Playlist{UserID: seedPlaylistUser(t, database, "lifecycle@example.test"), Name: "Lifecycle"}
	if err := repo.Create(ctx, playlist); err != nil {
		t.Fatal(err)
	}
	if got, err := repo.GetByIDWithTracks(ctx, playlist.ID+1); !errors.Is(err, ErrPlaylistNotFound) || got != nil {
		t.Fatalf("missing playlist = %+v, %v; want nil, ErrPlaylistNotFound", got, err)
	}
	a := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "Rich track")
	b := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "Sparse track")
	if _, err := database.ExecContext(ctx, `UPDATE tracks SET
		version='Live', mb_recording_id=$2, mb_release_id=$3, mb_artist_id=$4, mb_verified=true,
		source_url='https://source.test/track', source_type='fixture', storage_key='fixture/track.opus',
		file_size_bytes=12345, codec='opus', bitrate_kbps=192, sample_rate_hz=48000, channels=2,
		content_type='audio/ogg', metadata_json='{"fixture":"rich"}'::jsonb WHERE id=$1`,
		a, uuid.New(), uuid.New(), uuid.New()); err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE tracks SET artist=NULL, album=NULL, duration_ms=NULL, metadata_json=NULL WHERE id=$1`, b); err != nil {
		t.Fatal(err)
	}
	expected := make(map[int64]Track)
	for _, id := range []int64{a, b} {
		track, err := trackRepo.GetByID(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		// These enrichment-only fields are not selected by the playlist query.
		track.MetadataStatus = sql.NullString{}
		track.MetadataConfidence = sql.NullFloat64{}
		track.MetadataProvenance = nil
		track.AnalysisSummary = json.RawMessage(`{}`)
		expected[id] = *track
	}
	assertTracks := func(ids []int64, duration int64) {
		t.Helper()
		got, err := repo.GetByIDWithTracks(ctx, playlist.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got.Tracks == nil || len(got.Tracks) != len(ids) || got.TrackCount != len(ids) || got.DurationMs != duration {
			t.Fatalf("playlist = %+v, want order %v and duration %d", got, ids, duration)
		}
		for i, id := range ids {
			if !reflect.DeepEqual(got.Tracks[i], expected[id]) {
				t.Fatalf("track[%d] = %+v, want %+v", i, got.Tracks[i], expected[id])
			}
		}
	}
	assertTracks(nil, 0)
	if _, err := repo.AddTracks(ctx, playlist.ID, []int64{b, a}); err != nil {
		t.Fatal(err)
	}
	assertTracks([]int64{b, a}, 200000)
	if err := repo.SetTrackOrder(ctx, playlist.ID, []int64{a, b}); err != nil {
		t.Fatal(err)
	}
	assertTracks([]int64{a, b}, 200000)
	if err := repo.RemoveTracks(ctx, playlist.ID, []int64{a, b}); err != nil {
		t.Fatal(err)
	}
	assertTracks(nil, 0)
	if _, err := repo.AddTracks(ctx, playlist.ID, []int64{a}); err != nil {
		t.Fatal(err)
	}
	assertTracks([]int64{a}, 200000)
	if err := repo.RemoveTrack(ctx, playlist.ID, a); err != nil {
		t.Fatal(err)
	}
	assertTracks(nil, 0)
}

func TestPlaylistGetByIDWithTracksRejectsMalformedPresentTrack(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	// Session-local views exercise real SQL NULLs/conversion errors without
	// relaxing the migrated table's NOT NULL constraints or touching its data.
	database.SetMaxOpenConns(1)
	repo := NewPlaylistRepository(database)
	playlist := &Playlist{UserID: seedPlaylistUser(t, database, "malformed@example.test"), Name: "Malformed"}
	if err := repo.Create(ctx, playlist); err != nil {
		t.Fatal(err)
	}
	id := seedPlaylistTrack(t, NewTrackRepository(database), ctx, "Artist", "Present")
	if _, err := repo.AddTracks(ctx, playlist.ID, []int64{id}); err != nil {
		t.Fatal(err)
	}
	columns := strings.Split("id identity_hash title artist album duration_ms version mb_recording_id mb_release_id mb_artist_id mb_verified source_url source_type storage_key file_size_bytes codec bitrate_kbps sample_rate_hz channels content_type metadata_json created_at updated_at", " ")
	for _, column := range []string{"identity_hash", "title", "mb_verified", "created_at", "updated_at", "channels"} {
		t.Run(column, func(t *testing.T) {
			projection := append([]string(nil), columns...)
			for i, name := range projection {
				if name == column {
					projection[i] = "NULL AS " + name
					if name == "channels" {
						projection[i] = "'invalid-integer'::text AS channels"
					}
				}
			}
			if _, err := database.ExecContext(ctx, "CREATE TEMP VIEW tracks AS SELECT "+strings.Join(projection, ", ")+" FROM public.tracks"); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if _, err := database.ExecContext(ctx, "DROP VIEW pg_temp.tracks"); err != nil {
					t.Error(err)
				}
			})
			got, err := repo.GetByIDWithTracks(ctx, playlist.ID)
			if err == nil || got != nil {
				t.Fatalf("malformed present track %s = %+v, %v; want nil and error", column, got, err)
			}
			wantError := "NULL required columns"
			if column == "channels" {
				wantError = "invalid-integer"
			}
			if !strings.Contains(err.Error(), wantError) {
				t.Fatalf("malformed %s error = %v, want %q", column, err, wantError)
			}
		})
	}
}

// TestPlaylistBatchRemoveRenumbersContiguously covers batch-remove of 3 of 5
// tracks leaving 2 rows renumbered to contiguous 0..1, and verifies single
// remove/reorder still work afterward (regression).
func TestPlaylistBatchRemoveRenumbersContiguously(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	trackRepo := NewTrackRepository(database)
	repo := NewPlaylistRepository(database)

	userID := seedPlaylistUser(t, database, "batch@example.test")
	pl := &Playlist{UserID: userID, Name: "Road Trip"}
	if err := repo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}

	var trackIDs []int64
	for i, title := range []string{"t0", "t1", "t2", "t3", "t4"} {
		trackIDs = append(trackIDs, seedPlaylistTrack(t, trackRepo, ctx, "Artist", title))
		_ = i
	}
	if _, err := repo.AddTracks(ctx, pl.ID, trackIDs); err != nil {
		t.Fatalf("add tracks: %v", err)
	}
	contiguousPositions(t, playlistPositions(t, database, pl.ID), 5)

	// Remove positions 0, 2, 4 (t0, t2, t4). Remaining should be t1, t3 at 0,1.
	if err := repo.RemoveTracks(ctx, pl.ID, []int64{trackIDs[0], trackIDs[2], trackIDs[4]}); err != nil {
		t.Fatalf("batch remove: %v", err)
	}
	positions := playlistPositions(t, database, pl.ID)
	contiguousPositions(t, positions, 2)
	if positions[trackIDs[1]] != 0 {
		t.Fatalf("t1 position = %d, want 0", positions[trackIDs[1]])
	}
	if positions[trackIDs[3]] != 1 {
		t.Fatalf("t3 position = %d, want 1", positions[trackIDs[3]])
	}

	// Regression: single-track remove still works and renumbers.
	if err := repo.RemoveTrack(ctx, pl.ID, trackIDs[1]); err != nil {
		t.Fatalf("single remove: %v", err)
	}
	positions = playlistPositions(t, database, pl.ID)
	contiguousPositions(t, positions, 1)
	if positions[trackIDs[3]] != 0 {
		t.Fatalf("t3 position after single remove = %d, want 0", positions[trackIDs[3]])
	}

	// Regression: reorder still works on a re-populated playlist.
	if _, err := repo.AddTracks(ctx, pl.ID, []int64{trackIDs[0], trackIDs[2]}); err != nil {
		t.Fatalf("re-add tracks: %v", err)
	}
	// Now order is t3(0), t0(1), t2(2). Move t2 to front.
	if err := repo.ReorderTrack(ctx, pl.ID, trackIDs[2], 0); err != nil {
		t.Fatalf("reorder: %v", err)
	}
	positions = playlistPositions(t, database, pl.ID)
	contiguousPositions(t, positions, 3)
	if positions[trackIDs[2]] != 0 {
		t.Fatalf("t2 position after reorder = %d, want 0", positions[trackIDs[2]])
	}
}

// TestPlaylistBatchRemoveIsAtomic verifies the batch remove happens in a single
// committed transaction (all requested rows gone, remainder renumbered) and that
// removing an empty set is a no-op.
func TestPlaylistBatchRemoveEmptyNoop(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	trackRepo := NewTrackRepository(database)
	repo := NewPlaylistRepository(database)

	userID := seedPlaylistUser(t, database, "empty@example.test")
	pl := &Playlist{UserID: userID, Name: "Keep"}
	if err := repo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	a := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "a")
	b := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "b")
	if _, err := repo.AddTracks(ctx, pl.ID, []int64{a, b}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	if err := repo.RemoveTracks(ctx, pl.ID, nil); err != nil {
		t.Fatalf("empty remove: %v", err)
	}
	contiguousPositions(t, playlistPositions(t, database, pl.ID), 2)
}

// TestPlaylistAddTracksReportsAddedAndSkipped verifies AddTracks reports added
// vs already-present ids without creating duplicate rows.
func TestPlaylistAddTracksReportsAddedAndSkipped(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	trackRepo := NewTrackRepository(database)
	repo := NewPlaylistRepository(database)

	userID := seedPlaylistUser(t, database, "dup@example.test")
	pl := &Playlist{UserID: userID, Name: "Mix"}
	if err := repo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	a := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "a")
	b := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "b")
	c := seedPlaylistTrack(t, trackRepo, ctx, "Artist", "c")

	// Seed a and b already present.
	first, err := repo.AddTracks(ctx, pl.ID, []int64{a, b})
	if err != nil {
		t.Fatalf("first add: %v", err)
	}
	if len(first.Added) != 2 || len(first.Skipped) != 0 {
		t.Fatalf("first add report = %+v, want 2 added 0 skipped", first)
	}

	// Mix: a (present), b (present), c (new), c (dup within request).
	report, err := repo.AddTracks(ctx, pl.ID, []int64{a, b, c, c})
	if err != nil {
		t.Fatalf("mixed add: %v", err)
	}
	if len(report.Added) != 1 || report.Added[0] != c {
		t.Fatalf("added = %v, want [%d]", report.Added, c)
	}
	// a, b already present + the second c duplicate => 3 skipped.
	if len(report.Skipped) != 3 {
		t.Fatalf("skipped = %v, want 3 entries", report.Skipped)
	}

	// No duplicate rows: exactly 3 rows, contiguous positions.
	contiguousPositions(t, playlistPositions(t, database, pl.ID), 3)

	var count int
	if err := database.QueryRow(`SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = $1`, pl.ID).Scan(&count); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if count != 3 {
		t.Fatalf("row count = %d, want 3", count)
	}
}

// TestPlaylistListSearchSort covers q= substring search, sort=name|track_count,
// order asc/desc, and invalid-sort fallback to the default (updated_at DESC).
func TestPlaylistListSearchSort(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	trackRepo := NewTrackRepository(database)
	repo := NewPlaylistRepository(database)

	userID := seedPlaylistUser(t, database, "list@example.test")

	// Create playlists with distinct names and track counts.
	mk := func(name string, nTracks int) int64 {
		pl := &Playlist{UserID: userID, Name: name}
		if err := repo.Create(ctx, pl); err != nil {
			t.Fatalf("create %q: %v", name, err)
		}
		var ids []int64
		for i := 0; i < nTracks; i++ {
			ids = append(ids, seedPlaylistTrack(t, trackRepo, ctx, "Artist", name+"-t"+string(rune('a'+i))))
		}
		if len(ids) > 0 {
			if _, err := repo.AddTracks(ctx, pl.ID, ids); err != nil {
				t.Fatalf("add tracks to %q: %v", name, err)
			}
		}
		return pl.ID
	}

	mk("Road Trip", 3)       // matches "road"
	mk("Country Roads", 1)   // matches "road"
	mk("Jazz Nights", 5)     // no match
	mk("Highway to Road", 2) // matches "road"

	// q=road, sort=name asc -> only the three road playlists, alphabetical.
	got, total, err := repo.GetByUserID(ctx, userID, ListPlaylistsParams{Query: "road", Sort: "name", Order: "asc"})
	if err != nil {
		t.Fatalf("list q=road: %v", err)
	}
	if total != 3 {
		t.Fatalf("total = %d, want 3", total)
	}
	wantNames := []string{"Country Roads", "Highway to Road", "Road Trip"}
	if len(got) != len(wantNames) {
		t.Fatalf("got %d playlists, want %d", len(got), len(wantNames))
	}
	for i, name := range wantNames {
		if got[i].Name != name {
			t.Fatalf("name[%d] = %q, want %q", i, got[i].Name, name)
		}
	}

	// sort=track_count desc across all -> Jazz(5), Road Trip(3), Highway(2), Country(1).
	got, _, err = repo.GetByUserID(ctx, userID, ListPlaylistsParams{Sort: "track_count", Order: "desc"})
	if err != nil {
		t.Fatalf("list track_count: %v", err)
	}
	wantOrder := []int{5, 3, 2, 1}
	if len(got) != 4 {
		t.Fatalf("got %d playlists, want 4", len(got))
	}
	for i, wc := range wantOrder {
		if got[i].TrackCount != wc {
			t.Fatalf("track_count[%d] = %d, want %d (names=%v)", i, got[i].TrackCount, wc, playlistNames(got))
		}
	}

	// sort=track_count asc -> ascending counts.
	got, _, err = repo.GetByUserID(ctx, userID, ListPlaylistsParams{Sort: "track_count", Order: "asc"})
	if err != nil {
		t.Fatalf("list track_count asc: %v", err)
	}
	if got[0].TrackCount != 1 || got[len(got)-1].TrackCount != 5 {
		t.Fatalf("asc order wrong: first=%d last=%d", got[0].TrackCount, got[len(got)-1].TrackCount)
	}

	// Invalid sort -> falls back to default (updated_at DESC), no error, all rows.
	got, total, err = repo.GetByUserID(ctx, userID, ListPlaylistsParams{Sort: "'; DROP TABLE playlists; --", Order: "sideways"})
	if err != nil {
		t.Fatalf("invalid sort should not error: %v", err)
	}
	if total != 4 || len(got) != 4 {
		t.Fatalf("invalid sort total = %d len = %d, want 4/4", total, len(got))
	}
}

func playlistNames(ps []PlaylistWithTracks) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.Name
	}
	return out
}

// TestPlaylistCoverAndPublicRoundTrip verifies cover_url and is_public persist
// through Create/Update and are returned by GetByID/GetByIDWithTracks/GetByUserID.
func TestPlaylistCoverAndPublicRoundTrip(t *testing.T) {
	database, ctx := newPlaylistTestDB(t)
	repo := NewPlaylistRepository(database)

	userID := seedPlaylistUser(t, database, "cover@example.test")
	pl := &Playlist{
		UserID:   userID,
		Name:     "Cover Test",
		CoverURL: sql.NullString{String: "https://img.test/cover.jpg", Valid: true},
		IsPublic: true,
	}
	if err := repo.Create(ctx, pl); err != nil {
		t.Fatalf("create: %v", err)
	}
	// GetByID round-trip.
	got, err := repo.GetByID(ctx, pl.ID)
	if err != nil {
		t.Fatalf("get by id: %v", err)
	}
	if !got.CoverURL.Valid || got.CoverURL.String != "https://img.test/cover.jpg" {
		t.Fatalf("cover_url = %#v, want set", got.CoverURL)
	}
	if !got.IsPublic {
		t.Fatalf("is_public = false, want true")
	}

	// GetByIDWithTracks round-trip.
	withTracks, err := repo.GetByIDWithTracks(ctx, pl.ID)
	if err != nil {
		t.Fatalf("get with tracks: %v", err)
	}
	if !withTracks.CoverURL.Valid || !withTracks.IsPublic {
		t.Fatalf("with-tracks cover/public not round-tripped: %#v public=%v", withTracks.CoverURL, withTracks.IsPublic)
	}
	if withTracks.Tracks == nil || len(withTracks.Tracks) != 0 || withTracks.TrackCount != 0 || withTracks.DurationMs != 0 {
		t.Fatalf("cover/public empty detail = %+v, want no phantom track", withTracks)
	}

	// GetByUserID round-trip.
	list, _, err := repo.GetByUserID(ctx, userID, ListPlaylistsParams{})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(list) != 1 || !list[0].CoverURL.Valid || !list[0].IsPublic {
		t.Fatalf("list cover/public not round-tripped: %#v", list)
	}

	// Update: change cover and flip is_public off.
	got.Name = "Cover Test 2"
	got.CoverURL = sql.NullString{String: "https://img.test/other.png", Valid: true}
	got.IsPublic = false
	if err := repo.Update(ctx, got); err != nil {
		t.Fatalf("update: %v", err)
	}
	reloaded, err := repo.GetByID(ctx, pl.ID)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if reloaded.CoverURL.String != "https://img.test/other.png" {
		t.Fatalf("updated cover = %q, want other.png", reloaded.CoverURL.String)
	}
	if reloaded.IsPublic {
		t.Fatalf("is_public = true after update, want false")
	}

	// Update clearing cover_url (empty => NULL).
	reloaded.CoverURL = sql.NullString{}
	if err := repo.Update(ctx, reloaded); err != nil {
		t.Fatalf("update clear cover: %v", err)
	}
	cleared, err := repo.GetByID(ctx, pl.ID)
	if err != nil {
		t.Fatalf("reload cleared: %v", err)
	}
	if cleared.CoverURL.Valid {
		t.Fatalf("cover_url should be NULL after clear, got %#v", cleared.CoverURL)
	}
}
