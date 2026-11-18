package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

// sourceSelectionDownloadJobInsert persists the durable row for a trusted
// source-selection download.
//
// It deliberately omits download_jobs.target_playlist_id, the column the
// processor reads to append a finished download to a playlist the user picked
// (see processor.attachTargetPlaylistTrack). The only caller of
// CreateDownloadForDecision is the playlist import service, and an import
// carries its destination through playlist_import_items, so there is nothing
// for this path to store. queue.createDurableDownloadJob has the 16-column
// shape for the path that does need it; unifying the two is a bigger change
// than the absent requirement justifies.
//
// The hazard of that choice is that a playlist target arriving here later
// would be dropped silently and the track would land in the library only,
// which is indistinguishable from success. checkPersistablePlaylistTarget
// exists to turn that into a loud failure instead.
const sourceSelectionDownloadJobInsert = `INSERT INTO download_jobs (id, user_id, url, source_type, status, candidate_id, source_id, title, artist, album, uploader, duration_ms, thumbnail_url, metadata_json) VALUES ($1,$2,$3,$4,'queued',$5,$6,$7,$8,$9,$10,$11,$12,$13)`

// ErrDownloadPlaylistTargetUnsupported reports that a download job carries a
// playlist destination this ingestion path cannot persist.
var ErrDownloadPlaylistTargetUnsupported = errors.New("source-selection ingestion cannot persist a playlist target")

// checkPersistablePlaylistTarget rejects a job whose playlist destination
// sourceSelectionDownloadJobInsert would not write.
//
// Nothing reaches this today: download.SourceCandidate has no playlist fields,
// so newSourceSelectionDownloadJob cannot produce one. That is exactly why the
// guard is here — a future caller that adds a playlist target to this path has
// no other signal that the column is missing, and would otherwise ship a
// download that quietly forgets where the user wanted the track to go.
func checkPersistablePlaylistTarget(job *download.DownloadJob) error {
	if job == nil || (job.PlaylistID == 0 && job.PlaylistPosition == 0) {
		return nil
	}
	return fmt.Errorf(
		"%w: job %s targets playlist %d position %d; add target_playlist_id to sourceSelectionDownloadJobInsert before routing a playlist download through this path",
		ErrDownloadPlaylistTargetUnsupported, job.ID, job.PlaylistID, job.PlaylistPosition,
	)
}

// newSourceSelectionDownloadJob builds the durable job for a trusted
// source-selection download. It is split out from CreateDownloadForDecision so
// the fields that do and do not survive the INSERT can be asserted directly.
func newSourceSelectionDownloadJob(userID uuid.UUID, candidate download.SourceCandidate) *download.DownloadJob {
	return &download.DownloadJob{
		ID:           uuid.NewString(),
		UserID:       userID.String(),
		URL:          candidate.SourceURL,
		SourceType:   candidate.Provider,
		Status:       download.StatusQueued,
		CandidateID:  candidate.CandidateID,
		SourceID:     candidate.SourceID,
		Title:        candidate.Title,
		Artist:       candidate.Artist,
		Album:        candidate.Album,
		Uploader:     candidate.Uploader,
		DurationMs:   candidate.DurationMs,
		ThumbnailURL: candidate.ThumbnailURL,
		Metadata:     candidate.Metadata,
	}
}

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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var prior uuid.NullUUID
	if err = tx.QueryRowContext(ctx, `SELECT download_job_id FROM source_selection_decisions WHERE id=$1 AND user_id=$2 FOR UPDATE`, decision.ID, userID).Scan(&prior); err != nil {
		return nil, err
	}
	job := newSourceSelectionDownloadJob(userID, candidate)
	if prior.Valid {
		// Idempotency reuses the original acquisition, never a conflicting job
		// that happens to be attached to the same decision.
		var owner uuid.UUID
		var cid, sid, provider, sourceURL sql.NullString
		if err = tx.QueryRowContext(ctx, `SELECT user_id,candidate_id,source_id,source_type,url FROM download_jobs WHERE id=$1`, prior.UUID).Scan(&owner, &cid, &sid, &provider, &sourceURL); err != nil {
			return nil, fmt.Errorf("load durable acquisition: %w", err)
		}
		if owner != userID || cid.String != candidate.CandidateID || sid.String != candidate.SourceID || provider.String != candidate.Provider || strings.TrimSpace(sourceURL.String) != strings.TrimSpace(candidate.SourceURL) {
			return nil, ErrSourceSelectionConflict
		}
		job.ID = prior.UUID.String()
	} else {
		if err = checkPersistablePlaylistTarget(job); err != nil {
			return nil, err
		}
		if _, err = tx.ExecContext(ctx, sourceSelectionDownloadJobInsert, job.ID, userID, job.URL, job.SourceType, job.CandidateID, job.SourceID, job.Title, job.Artist, job.Album, job.Uploader, job.DurationMs, job.ThumbnailURL, metadata); err != nil {
			return nil, err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE source_selection_decisions SET download_job_id=$3 WHERE id=$1 AND user_id=$2`, decision.ID, userID, job.ID); err != nil {
			return nil, err
		}
	}
	// Persist import custody in the same decision/job transaction, before recovery
	// could observe an apparently generic download.
	if _, err = tx.ExecContext(ctx, `UPDATE playlist_import_items SET download_job_id=$2,status='queued',updated_at=clock_timestamp() WHERE selection_decision_id=$1 AND (download_job_id IS NULL OR download_job_id=$2)`, decision.ID, job.ID); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
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
	// Link before Redis publication so boot recovery always sees the exact import item.
	result, err := s.db.ExecContext(ctx, `UPDATE playlist_import_items i SET download_job_id=$2,status='queued',updated_at=clock_timestamp() FROM playlist_import_jobs j WHERE i.id=$1 AND i.import_job_id=j.id AND j.id=$3 AND j.playlist_id=$4 AND j.user_id=$5 AND (i.download_job_id IS NULL OR i.download_job_id=$2)`, importItemID, persisted.Job.ID, importJobID, playlistID, persisted.Decision.UserID)
	if err != nil {
		return nil, err
	}
	n, err := result.RowsAffected()
	if err != nil || n != 1 {
		return nil, fmt.Errorf("playlist acquisition link was not admitted")
	}
	var job *download.DownloadJob
	if recoverer, ok := enqueuer.(interface {
		EnsurePlaylistImportItemWithID(context.Context, string, string, download.SourceCandidate, string, int64, int64, int) (*download.DownloadJob, error)
	}); ok {
		job, err = recoverer.EnsurePlaylistImportItemWithID(ctx, persisted.Job.ID, persisted.Job.UserID, persisted.Candidate, importJobID, importItemID, playlistID, playlistPosition)
	} else {
		job, err = enqueuer.EnqueuePlaylistImportItemWithID(ctx, persisted.Job.ID, persisted.Job.UserID, persisted.Candidate, importJobID, importItemID, playlistID, playlistPosition)
	}

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
