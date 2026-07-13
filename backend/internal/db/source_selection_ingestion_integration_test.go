package db

import (
	"context"
	"errors"
	"testing"

	"github.com/openmusicplayer/backend/internal/download"
)

func TestSourceSelectionIngestionPersistsDecisionJobLinkAndEnqueueFailure(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "ingestion@example.test")
	ingestion := NewSourceSelectionIngestion(database, repo)
	candidate := download.SourceCandidate{CandidateID: "youtube:direct", Provider: "youtube", SourceID: "direct", SourceURL: "https://www.youtube.com/watch?v=direct", Title: "Direct", Metadata: map[string]interface{}{}}
	persisted, err := ingestion.CreateTrustedDownload(ctx, userID, SourceSelectionOriginDirectURL, candidate, "server-normalized authenticated direct/share URL")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := repo.GetDecisionForUser(ctx, userID, persisted.Decision.ID)
	if err != nil || !decision.DownloadJobID.Valid || decision.DownloadJobID.UUID.String() != persisted.Job.ID {
		t.Fatalf("decision/job link = %+v, %v", decision, err)
	}
	if _, err := ingestion.EnqueueTrustedDownload(ctx, persisted, failingSourceSelectionEnqueuer{}); !errors.Is(err, errEnqueueFailed) {
		t.Fatalf("enqueue failure = %v", err)
	}
	var status, failure string
	if err := database.QueryRowContext(ctx, `SELECT status, error FROM download_jobs WHERE id = $1`, persisted.Job.ID).Scan(&status, &failure); err != nil {
		t.Fatal(err)
	}
	if status != download.StatusFailed || failure != errEnqueueFailed.Error() {
		t.Fatalf("durable enqueue failure = (%q, %q)", status, failure)
	}
}

var errEnqueueFailed = errors.New("redis unavailable")

type failingSourceSelectionEnqueuer struct{}

func (failingSourceSelectionEnqueuer) EnqueueSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error) {
	return nil, errEnqueueFailed
}
