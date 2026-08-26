package search

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// TestSearchAppliesPerUserMetadataOverrides proves the search endpoints render the
// requesting user's manual metadata corrections (issue #344) while the underlying
// repository search — the one the matcher and ingestion share — stays canonical.
func TestSearchAppliesPerUserMetadataOverrides(t *testing.T) {
	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres search metadata override integration tests")
	}

	// Issue #407: refuse a DSN aimed at a protected (dogfood) database
	// before a single statement can reach it.
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
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
	if err := database.CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE track_metadata_overrides, tracks, users RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	ctx := context.Background()
	trackRepo := db.NewTrackRepository(database)
	overrideRepo := db.NewTrackMetadataOverrideRepository(database)
	handlers := NewHandlersWithMetadataOverrides(trackRepo, overrideRepo)

	editorID := uuid.New()
	otherID := uuid.New()
	for _, seed := range []struct {
		id    uuid.UUID
		email string
	}{{editorID, "search-override-editor@example.test"}, {otherID, "search-override-other@example.test"}} {
		if _, err := database.Exec(
			`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, 'search', 'x')`,
			seed.id, seed.email); err != nil {
			t.Fatalf("seed user %s: %v", seed.email, err)
		}
	}

	track, _, err := trackRepo.CreateTrackFromMetadata(ctx,
		"Overridecast Channel", "Overridecast Raw Upload", "Overridecast Uploads", 205000,
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track: %v", err)
	}

	editedTitle := "Overridecast Clean Edit"
	if _, err := overrideRepo.Set(ctx, editorID, track.ID, db.TrackMetadataOverrideInput{
		Title: &editedTitle,
	}); err != nil {
		t.Fatalf("seed override: %v", err)
	}

	search := func(t *testing.T, userID *uuid.UUID) RecordingResponse {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search/recordings?q=Overridecast", nil)
		if userID != nil {
			req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
				UserID: *userID,
				Email:  "search-override@example.test",
			}))
		}
		rec := httptest.NewRecorder()
		handlers.SearchRecordings(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("search status = %d; body=%s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Data []RecordingResponse `json:"data"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatalf("decode search response: %v", err)
		}
		if len(resp.Data) != 1 {
			t.Fatalf("search returned %d recordings, want 1", len(resp.Data))
		}
		return resp.Data[0]
	}

	t.Run("editor sees the override", func(t *testing.T) {
		got := search(t, &editorID)
		if got.Title != editedTitle {
			t.Fatalf("title = %q, want %q", got.Title, editedTitle)
		}
		if got.Artist != "Overridecast Channel" {
			t.Fatalf("artist = %q, want the canonical value (no artist override)", got.Artist)
		}
		if !got.HasMetadataOverride {
			t.Fatal("edited result should report hasMetadataOverride")
		}
	})

	t.Run("other user sees canonical values", func(t *testing.T) {
		got := search(t, &otherID)
		if got.Title != "Overridecast Raw Upload" {
			t.Fatalf("title = %q, want the canonical value", got.Title)
		}
		if got.HasMetadataOverride {
			t.Fatal("other user should not see an override flag")
		}
	})

	t.Run("repository search stays canonical", func(t *testing.T) {
		tracks, _, err := trackRepo.SearchRecordings(ctx, "Overridecast", 10, 0)
		if err != nil {
			t.Fatalf("repository search: %v", err)
		}
		if len(tracks) != 1 {
			t.Fatalf("repository search returned %d tracks, want 1", len(tracks))
		}
		if tracks[0].Title != "Overridecast Raw Upload" || tracks[0].HasMetadataOverride {
			t.Fatalf("repository read leaked a display override: %+v", tracks[0])
		}
	})
}
