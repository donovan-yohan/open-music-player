package db

import (
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

// TestSourceSelectionDownloadInsertOmitsTargetPlaylist pins the current
// contract: the durable row this path writes has no playlist destination.
//
// This is not a wish, it is the state the guard depends on. If someone adds
// target_playlist_id to the INSERT, this test fails and forces them to revisit
// checkPersistablePlaylistTarget in the same change instead of leaving a guard
// that refuses work the INSERT can now do.
func TestSourceSelectionDownloadInsertOmitsTargetPlaylist(t *testing.T) {
	if strings.Contains(sourceSelectionDownloadJobInsert, "target_playlist_id") {
		t.Fatal("the insert now writes target_playlist_id; relax checkPersistablePlaylistTarget in the same change")
	}
}

// TestSourceSelectionDownloadInsertBindsEveryColumn catches the other half of
// the silent-drop family: a column added to the list without a matching value,
// or the reverse. Postgres would reject that at runtime, in a durable write
// that only the import path exercises.
func TestSourceSelectionDownloadInsertBindsEveryColumn(t *testing.T) {
	columns := parenthesizedList(t, sourceSelectionDownloadJobInsert, "INSERT INTO download_jobs ")
	values := parenthesizedList(t, sourceSelectionDownloadJobInsert, "VALUES ")
	if len(columns) != len(values) {
		t.Fatalf("insert lists %d columns but %d values:\n%s", len(columns), len(values), sourceSelectionDownloadJobInsert)
	}
	if len(columns) != 14 {
		t.Fatalf("insert writes %d columns, want the 14 this path persists: %v", len(columns), columns)
	}
}

// parenthesizedList returns the comma-separated items of the parenthesized
// group that follows prefix.
func parenthesizedList(t *testing.T, query, prefix string) []string {
	t.Helper()
	start := strings.Index(query, prefix)
	if start < 0 {
		t.Fatalf("query does not contain %q:\n%s", prefix, query)
	}
	rest := query[start+len(prefix):]
	open := strings.Index(rest, "(")
	closed := strings.Index(rest, ")")
	if open != 0 || closed < 0 {
		t.Fatalf("no parenthesized group after %q:\n%s", prefix, query)
	}
	items := strings.Split(rest[1:closed], ",")
	for i := range items {
		items[i] = strings.TrimSpace(items[i])
	}
	return items
}

// TestNewSourceSelectionDownloadJobCarriesNoPlaylistTarget documents why the
// guard never fires today: a source candidate has no playlist fields to copy,
// so the production path is always persistable.
func TestNewSourceSelectionDownloadJobCarriesNoPlaylistTarget(t *testing.T) {
	job := newSourceSelectionDownloadJob(uuid.New(), download.SourceCandidate{
		CandidateID:  "candidate-1",
		Provider:     "youtube",
		SourceID:     "source-1",
		SourceURL:    "https://example.test/watch",
		Title:        "A track",
		Artist:       "An artist",
		Album:        "An album",
		Uploader:     "An uploader",
		DurationMs:   240000,
		ThumbnailURL: "https://example.test/thumb.jpg",
		Metadata:     map[string]interface{}{"k": "v"},
	})

	if job.PlaylistID != 0 || job.PlaylistPosition != 0 {
		t.Fatalf("job = %+v, want no playlist target from a source candidate", job)
	}
	if err := checkPersistablePlaylistTarget(job); err != nil {
		t.Fatalf("the production job is not persistable: %v", err)
	}
	if job.Status != download.StatusQueued {
		t.Fatalf("status = %q, want %q", job.Status, download.StatusQueued)
	}
	if _, err := uuid.Parse(job.ID); err != nil {
		t.Fatalf("job ID %q is not a UUID: %v", job.ID, err)
	}
}

func TestCheckPersistablePlaylistTargetRejectsADroppedTarget(t *testing.T) {
	cases := []struct {
		name    string
		job     *download.DownloadJob
		wantErr bool
	}{
		{name: "nil job", job: nil},
		{name: "no target", job: &download.DownloadJob{ID: "job-1"}},
		{name: "import item without a target", job: &download.DownloadJob{ID: "job-2", PlaylistImportItemID: 9}},
		{name: "playlist target", job: &download.DownloadJob{ID: "job-3", PlaylistID: 7}, wantErr: true},
		{name: "playlist position only", job: &download.DownloadJob{ID: "job-4", PlaylistPosition: 3}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := checkPersistablePlaylistTarget(tc.job)
			if tc.wantErr != (err != nil) {
				t.Fatalf("error = %v, wantErr = %v", err, tc.wantErr)
			}
			if !tc.wantErr {
				return
			}
			if !errors.Is(err, ErrDownloadPlaylistTargetUnsupported) {
				t.Fatalf("error %v does not wrap ErrDownloadPlaylistTargetUnsupported", err)
			}
			// The message has to tell the next person what to change, not just
			// that something was refused.
			if !strings.Contains(err.Error(), "target_playlist_id") {
				t.Fatalf("error %q does not name the missing column", err)
			}
		})
	}
}

// TestPlaylistImportJobsStayPersistable keeps the guard honest about the one
// caller that exists: a playlist import routes its destination through
// playlist_import_items, so its jobs must continue to pass.
func TestPlaylistImportJobsStayPersistable(t *testing.T) {
	job := &download.DownloadJob{
		ID:                   "import-job",
		PlaylistImportJobID:  uuid.NewString(),
		PlaylistImportItemID: 42,
	}
	if err := checkPersistablePlaylistTarget(job); err != nil {
		t.Fatalf("a playlist import job was refused: %v", err)
	}
}
