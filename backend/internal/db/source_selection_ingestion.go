package db

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

// SourceSelectionIngestion owns the durable side of trusted ingestion. Redis
// receives work only after this package has persisted a decision and linked job.
type SourceSelectionIngestion struct {
	db        *DB
	decisions *SourceSelectionRepository
}

type SourceSelectionDownload struct {
	Decision  *SourceSelectionDecision
	Job       *download.DownloadJob
	Candidate download.SourceCandidate
}

type SourceSelectionDownloadEnqueuer interface {
	EnqueueSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error)
}

type SourceSelectionPlaylistDownloadEnqueuer interface {
	EnqueuePlaylistImportItemWithID(context.Context, string, string, download.SourceCandidate, string, int64, int64, int) (*download.DownloadJob, error)
}

func NewSourceSelectionIngestion(database *DB, decisions *SourceSelectionRepository) *SourceSelectionIngestion {
	return &SourceSelectionIngestion{db: database, decisions: decisions}
}

func (s *SourceSelectionIngestion) CreateTrustedDownload(ctx context.Context, userID uuid.UUID, origin string, candidate download.SourceCandidate, reason string) (*SourceSelectionDownload, error) {
	if s == nil || s.db == nil || s.decisions == nil {
		return nil, fmt.Errorf("source selection ingestion is unavailable")
	}
	decision, err := s.decisions.CreateTrustedSourceSelectionDecision(ctx, userID, origin, trustedCandidate(candidate, origin), reason)
	if err != nil {
		return nil, err
	}
	return s.CreateDownloadForDecision(ctx, userID, decision, candidate)
}

func (s *SourceSelectionIngestion) CreateDownloadForDecision(ctx context.Context, userID uuid.UUID, decision *SourceSelectionDecision, candidate download.SourceCandidate) (*SourceSelectionDownload, error) {
	if s == nil || s.db == nil || s.decisions == nil || decision == nil || decision.UserID != userID {
		return nil, fmt.Errorf("source selection decision is required")
	}
	metadata, err := json.Marshal(candidate.Metadata)
	if err != nil {
		return nil, fmt.Errorf("marshal trusted candidate metadata: %w", err)
	}
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), URL: candidate.SourceURL, SourceType: candidate.Provider, Status: download.StatusQueued, CandidateID: candidate.CandidateID, SourceID: candidate.SourceID, Title: candidate.Title, Artist: candidate.Artist, Album: candidate.Album, Uploader: candidate.Uploader, DurationMs: candidate.DurationMs, ThumbnailURL: candidate.ThumbnailURL, Metadata: candidate.Metadata}
	_, err = s.db.ExecContext(ctx, `INSERT INTO download_jobs (id, user_id, url, source_type, status, candidate_id, source_id, title, artist, album, uploader, duration_ms, thumbnail_url, metadata_json) VALUES ($1,$2,$3,$4,'queued',$5,$6,$7,$8,$9,$10,$11,$12,$13)`, job.ID, userID, job.URL, job.SourceType, job.CandidateID, job.SourceID, job.Title, job.Artist, job.Album, job.Uploader, job.DurationMs, job.ThumbnailURL, metadata)
	if err != nil {
		return nil, fmt.Errorf("create durable source-selection download job: %w", err)
	}
	if err := s.decisions.AttachDownloadJobForUser(ctx, userID, decision.ID, uuid.MustParse(job.ID)); err != nil {
		if cleanupErr := s.markUnlinkedFailed(ctx, userID, job.ID, fmt.Errorf("attach source selection decision: %w", err)); cleanupErr != nil {
			return nil, fmt.Errorf("attach source selection decision: %w; cleanup failed: %v", err, cleanupErr)
		}
		return nil, err
	}
	return &SourceSelectionDownload{Decision: decision, Job: job, Candidate: candidate}, nil
}

// markUnlinkedFailed cleans up a job created before decision attachment. It is
// intentionally not guarded by source_selection_decisions because attachment is
// the operation that failed.
func (s *SourceSelectionIngestion) markUnlinkedFailed(ctx context.Context, userID uuid.UUID, jobID string, cause error) error {
	result, err := s.db.ExecContext(ctx, `UPDATE download_jobs SET status = 'failed', error = $3, updated_at = clock_timestamp(), completed_at = clock_timestamp() WHERE id = $1 AND user_id = $2`, jobID, userID, cause.Error())
	if err != nil {
		return err
	}
	updated, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("verify unlinked job cleanup: %w", err)
	}
	if updated != 1 {
		return fmt.Errorf("unlinked job cleanup updated %d rows", updated)
	}
	return nil
}

func (s *SourceSelectionIngestion) EnqueueTrustedPlaylistDownload(ctx context.Context, persisted *SourceSelectionDownload, enqueuer SourceSelectionPlaylistDownloadEnqueuer, importJobID string, importItemID, playlistID int64, playlistPosition int) (*download.DownloadJob, error) {
	if persisted == nil || persisted.Job == nil || persisted.Decision == nil || enqueuer == nil {
		return nil, fmt.Errorf("persisted source-selection playlist download is required")
	}
	job, err := enqueuer.EnqueuePlaylistImportItemWithID(ctx, persisted.Job.ID, persisted.Job.UserID, persisted.Candidate, importJobID, importItemID, playlistID, playlistPosition)
	if err != nil {
		if persistErr := s.markFailed(ctx, persisted.Decision.UserID, persisted.Job.ID, err); persistErr != nil {
			return nil, fmt.Errorf("enqueue trusted playlist download: %w; persist failure: %v", err, persistErr)
		}
		return nil, err
	}
	return job, nil
}

func (s *SourceSelectionIngestion) EnqueueTrustedDownload(ctx context.Context, persisted *SourceSelectionDownload, enqueuer SourceSelectionDownloadEnqueuer) (*download.DownloadJob, error) {
	if persisted == nil || persisted.Job == nil || persisted.Decision == nil || enqueuer == nil {
		return nil, fmt.Errorf("persisted source-selection download is required")
	}
	job, err := enqueuer.EnqueueSourceCandidateWithID(ctx, persisted.Job.ID, persisted.Job.UserID, persisted.Candidate, nil)
	if err != nil {
		if persistErr := s.markFailed(ctx, persisted.Decision.UserID, persisted.Job.ID, err); persistErr != nil {
			return nil, fmt.Errorf("enqueue trusted download: %w; persist failure: %v", err, persistErr)
		}
		return nil, err
	}
	return job, nil
}

func (s *SourceSelectionIngestion) markFailed(ctx context.Context, userID uuid.UUID, jobID string, cause error) error {
	_, err := s.db.ExecContext(ctx, `UPDATE download_jobs AS j SET status = 'failed', error = $3, updated_at = clock_timestamp(), completed_at = clock_timestamp() WHERE j.id = $1 AND j.user_id = $2 AND EXISTS (SELECT 1 FROM source_selection_decisions AS d WHERE d.download_job_id = j.id AND d.user_id = j.user_id)`, jobID, userID, cause.Error())
	return err
}

func trustedCandidate(candidate download.SourceCandidate, origin string) TrustedSourceSelectionCandidate {
	return TrustedSourceSelectionCandidate{
		CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID,
		SourceURL: candidate.SourceURL, Title: candidate.Title, Downloadable: true,
		SourceQuality: &TrustedSourceSelectionQuality{Score: 100, Classification: origin, Recommendation: SourceSelectionActionAccepted, Confidence: 1, Reasons: []string{"server-normalized trusted ingestion"}, Provenance: origin},
	}
}
