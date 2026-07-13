package db

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

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

func TestSourceSelectionIngestionFailsUnlinkedJobWhenAttachmentConflicts(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "ingestion-attach@example.test")
	candidate := download.SourceCandidate{CandidateID: "youtube:direct", Provider: "youtube", SourceID: "direct", SourceURL: "https://www.youtube.com/watch?v=direct", Title: "Direct"}
	decision, err := repo.CreateTrustedSourceSelectionDecision(ctx, userID, SourceSelectionOriginDirectURL, trustedCandidate(candidate, SourceSelectionOriginDirectURL), "test")
	if err != nil {
		t.Fatal(err)
	}
	existingID := uuid.New()
	if _, err := database.ExecContext(ctx, `INSERT INTO download_jobs (id, user_id, url, source_type, status, candidate_id, source_id, title) VALUES ($1,$2,$3,$4,'queued',$5,$6,$7)`, existingID, userID, candidate.SourceURL, candidate.Provider, "youtube:existing", "existing", "Existing"); err != nil {
		t.Fatal(err)
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, existingID); err != nil {
		t.Fatal(err)
	}
	_, err = NewSourceSelectionIngestion(database, repo).CreateDownloadForDecision(ctx, userID, decision, candidate)
	if !errors.Is(err, ErrSourceSelectionConflict) {
		t.Fatalf("attachment error = %v", err)
	}
	var status, failure string
	if err := database.QueryRowContext(ctx, `SELECT status, error FROM download_jobs WHERE user_id = $1 AND candidate_id = $2`, userID, candidate.CandidateID).Scan(&status, &failure); err != nil {
		t.Fatal(err)
	}
	if status != download.StatusFailed || failure == "" {
		t.Fatalf("unlinked cleanup = (%q, %q)", status, failure)
	}
}

func TestSourceSelectionIngestionSurfacesMissingUnlinkedCleanup(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "ingestion-cleanup@example.test")
	err := NewSourceSelectionIngestion(database, repo).markUnlinkedFailed(ctx, userID, uuid.NewString(), errors.New("attach failed"))
	if err == nil || !strings.Contains(err.Error(), "updated 0 rows") {
		t.Fatalf("missing cleanup error = %v", err)
	}
}

var errEnqueueFailed = errors.New("redis unavailable")

type failingSourceSelectionEnqueuer struct{}

func (failingSourceSelectionEnqueuer) EnqueueSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error) {
	return nil, errEnqueueFailed
}
