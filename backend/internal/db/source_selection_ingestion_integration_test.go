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
	// Atomic custody now refuses before creating an unlinked job. Preserve
	// the conflicting original instead of manufacturing a failed extra row.
	var count int
	var status string
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM download_jobs WHERE user_id=$1`, userID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRowContext(ctx, `SELECT status FROM download_jobs WHERE id=$1`, existingID).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if count != 1 || status != download.StatusQueued {
		t.Fatalf("conflict changed acquisition custody: count=%d status=%s", count, status)
	}
}

func TestSourceSelectionIngestionReusesExactCanonicalAcquisition(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	user := seedSourceSelectionUser(t, database, "canonical-reuse@fixture.test")
	candidate := download.SourceCandidate{CandidateID: "youtube:canonical", Provider: "youtube", SourceID: "canonical", SourceURL: "https://fixture.invalid/canonical", Title: "Canonical"}
	ingestion := NewSourceSelectionIngestion(database, repo)
	first, err := ingestion.CreateTrustedDownload(ctx, user, SourceSelectionOriginDirectURL, candidate, "synthetic source")
	if err != nil {
		t.Fatal(err)
	}
	second, err := ingestion.CreateDownloadForDecision(ctx, user, first.Decision, candidate)
	if err != nil || second.Job.ID != first.Job.ID {
		t.Fatalf("canonical replay changed acquisition: %v", err)
	}
	var count int
	if err = database.QueryRow(`SELECT COUNT(*) FROM download_jobs WHERE user_id=$1`, user).Scan(&count); err != nil || count != 1 {
		t.Fatalf("duplicate canonical acquisition: %d %v", count, err)
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
