package search

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"

	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
)

func postgresTestDSN() string {
	if dsn := os.Getenv("OMP_POSTGRES_TEST_DSN"); dsn != "" {
		return dsn
	}
	return os.Getenv("QA_DATABASE_URL")
}

func newUnifiedSearchTestHandlers(t *testing.T) (*Handlers, *db.TrackRepository, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres unified search integration tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &db.DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE tracks RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	trackRepo := db.NewTrackRepository(database)
	return NewHandlers(trackRepo), trackRepo, context.Background()
}

// TestUnifiedSearchReturnsSectionedBody proves GET /api/v1/search runs the three
// local searches and returns tracks, artists, and albums populated from a single
// request when the query matches a seeded track's title/artist/album.
func TestUnifiedSearchReturnsSectionedBody(t *testing.T) {
	h, trackRepo, ctx := newUnifiedSearchTestHandlers(t)

	// A single shared token so prefix matching lights up all three sections.
	track, _, err := trackRepo.CreateTrackFromMetadata(ctx,
		"Novaquest Band", "Novaquest Anthem", "Novaquest Sessions", 211000,
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/search?q=Novaquest", nil)
	w := httptest.NewRecorder()
	h.Search(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d (body: %s)", http.StatusOK, w.Code, w.Body.String())
	}

	var resp UnifiedSearchResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode unified response: %v", err)
	}

	if resp.Query != "Novaquest" {
		t.Errorf("expected query %q, got %q", "Novaquest", resp.Query)
	}
	if len(resp.Tracks) == 0 {
		t.Errorf("expected tracks section populated, got empty")
	}
	if len(resp.Artists) == 0 {
		t.Errorf("expected artists section populated, got empty")
	}
	if len(resp.Albums) == 0 {
		t.Errorf("expected albums section populated, got empty")
	}
	if len(resp.Albums) > 0 && resp.Albums[0].ID != track.ID {
		t.Errorf("album id = %d, want seeded track id %d", resp.Albums[0].ID, track.ID)
	}

	if len(resp.Tracks) > 0 {
		if resp.Tracks[0].Title != "Novaquest Anthem" {
			t.Errorf("unexpected track title: %q", resp.Tracks[0].Title)
		}
		if resp.Tracks[0].Artist != "Novaquest Band" {
			t.Errorf("unexpected track artist: %q", resp.Tracks[0].Artist)
		}
		if resp.Tracks[0].Album != "Novaquest Sessions" {
			t.Errorf("unexpected track album: %q", resp.Tracks[0].Album)
		}
	}
}

func TestSearchReleasesReturnsNumericAlbumID(t *testing.T) {
	h, trackRepo, ctx := newUnifiedSearchTestHandlers(t)

	track, _, err := trackRepo.CreateTrackFromMetadata(ctx,
		"Release API Band", "Release API Song", "Release API Album", 211000,
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/search/releases?q=Release+API", nil)
	w := httptest.NewRecorder()
	h.SearchReleases(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d (body: %s)", http.StatusOK, w.Code, w.Body.String())
	}

	var resp struct {
		Data   []ReleaseResponse `json:"data"`
		Total  int               `json:"total"`
		Limit  int               `json:"limit"`
		Offset int               `json:"offset"`
	}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode release search response: %v", err)
	}
	if resp.Total != 1 || len(resp.Data) != 1 {
		t.Fatalf("release search returned len=%d total=%d, want one album", len(resp.Data), resp.Total)
	}
	if resp.Data[0].ID != track.ID {
		t.Fatalf("release response id = %d, want seeded track id %d", resp.Data[0].ID, track.ID)
	}
}

// TestUnifiedSearchSpecialCharactersDoNotError proves tsquery-significant input
// is sanitized by buildPrefixTSQuery and never produces a 500.
func TestUnifiedSearchSpecialCharactersDoNotError(t *testing.T) {
	h, _, _ := newUnifiedSearchTestHandlers(t)

	for _, q := range []string{"AC/DC", "foo!", "a:b", "(x)", "foo &", "&|!:()", "back:in"} {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search?q="+url.QueryEscape(q), nil)
		w := httptest.NewRecorder()
		h.Search(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("Search(q=%q) = status %d; want 200 (body: %s)", q, w.Code, w.Body.String())
		}
	}
}
