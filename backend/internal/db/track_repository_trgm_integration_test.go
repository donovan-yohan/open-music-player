package db

import (
	"encoding/json"
	"testing"
)

// TestTrigramFuzzySearchAgainstPostgres exercises the optional pg_trgm fuzzy fallback
// added for C2c.
//
//   - When pg_trgm can be enabled on the test database (database.TrigramEnabled), a typo
//     of a seeded artist that the FTS prefix path can never match must still be returned
//     via the similarity() fallback, and an exact match must still rank first.
//   - When the extension cannot be enabled (e.g. the runtime role lacks the privilege),
//     the FTS path must still return results for a real query and nothing must 500.
//
// Either way the server/migration must have started (newSearchTestDB calls Migrate,
// which treats pg_trgm as best-effort), so reaching this point already proves graceful
// degradation.
func TestTrigramFuzzySearchAgainstPostgres(t *testing.T) {
	database, ctx := newSearchTestDB(t)
	repo := NewTrackRepository(database)

	// Seed a track with a distinctive artist/title/album.
	radioheadTrack, _, err := repo.CreateTrackFromMetadata(ctx, "Radiohead", "Paranoid Android", "OK Computer", 383000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}
	// A second, unrelated track so the fuzzy match has to discriminate, not just return all.
	if _, _, err := repo.CreateTrackFromMetadata(ctx, "Miles Davis", "So What", "Kind of Blue", 544000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), "")); err != nil {
		t.Fatalf("seed second track: %v", err)
	}

	// FTS-only sanity: exact/prefix search must always work regardless of pg_trgm.
	tracks, total, err := repo.SearchRecordings(ctx, "Radiohead", 20, 0)
	if err != nil {
		t.Fatalf("SearchRecordings exact: %v", err)
	}
	if total == 0 || len(tracks) == 0 {
		t.Fatalf("exact FTS search matched nothing; want seeded Radiohead track")
	}
	if tracks[0].Artist.String != "Radiohead" {
		t.Fatalf("exact search first result artist = %q; want Radiohead", tracks[0].Artist.String)
	}

	if !database.TrigramEnabled {
		t.Log("pg_trgm NOT enabled on test DB: verified FTS path still returns results and does not error; fuzzy fallback skipped")
		// A query that FTS cannot match returns empty (no fallback, no error) — not a 500.
		got, gotTotal, err := repo.SearchRecordings(ctx, "Radiohede", 20, 0)
		if err != nil {
			t.Fatalf("typo search without pg_trgm errored: %v", err)
		}
		if gotTotal != 0 || len(got) != 0 {
			t.Fatalf("typo search without pg_trgm returned %d rows; want 0 (FTS unchanged)", len(got))
		}
		return
	}

	t.Log("pg_trgm enabled on test DB: exercising fuzzy fallback")

	// Typo of the artist: "Radiohede" does not share the "radiohead" lexeme, so FTS
	// returns nothing and the trigram fallback must surface the track.
	typoTracks, typoTotal, err := repo.SearchRecordings(ctx, "Radiohede", 20, 0)
	if err != nil {
		t.Fatalf("SearchRecordings typo: %v", err)
	}
	if typoTotal == 0 || len(typoTracks) == 0 {
		t.Fatalf("typo search 'Radiohede' matched nothing; want fuzzy match to seeded Radiohead track")
	}
	if typoTracks[0].Artist.String != "Radiohead" {
		t.Fatalf("typo fuzzy match artist = %q; want Radiohead", typoTracks[0].Artist.String)
	}

	// Typo via SearchArtists as well.
	artists, artistTotal, err := repo.SearchArtists(ctx, "Radiohede", 20, 0)
	if err != nil {
		t.Fatalf("SearchArtists typo: %v", err)
	}
	if artistTotal == 0 || len(artists) == 0 || artists[0].Name != "Radiohead" {
		t.Fatalf("SearchArtists typo returned %+v; want Radiohead", artists)
	}

	// Exact match still ranks first among fuzzy candidates: an exact query returns the
	// exact track ahead of any looser match.
	exact, _, err := repo.SearchRecordings(ctx, "Paranoid Android", 20, 0)
	if err != nil {
		t.Fatalf("SearchRecordings exact-title: %v", err)
	}
	if len(exact) == 0 || exact[0].Title != "Paranoid Android" {
		t.Fatalf("exact-title search first result = %+v; want Paranoid Android first", exact)
	}

	// Typo via SearchReleases must preserve the stable numeric album id selected
	// by the trigram fallback query.
	releases, releaseTotal, err := repo.SearchReleases(ctx, "OK Compoter", 20, 0)
	if err != nil {
		t.Fatalf("SearchReleases typo: %v", err)
	}
	if releaseTotal == 0 || len(releases) == 0 {
		t.Fatalf("SearchReleases typo matched nothing; want fuzzy album match")
	}
	if releases[0].ID != radioheadTrack.ID {
		t.Fatalf("SearchReleases typo ID = %d; want seeded track ID %d", releases[0].ID, radioheadTrack.ID)
	}
}
