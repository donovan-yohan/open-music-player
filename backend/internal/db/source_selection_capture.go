package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

// CreateSourceSessionTx lets a bounded capability owner commit its binding and
// the ordinary server-owned discovery snapshot in the SAME SQL transaction.
func CreateSourceSessionTx(ctx context.Context, tx *sql.Tx, session *SourceSelectionSession) error {
	if err := validateSession(session); err != nil {
		return err
	}
	return tx.QueryRowContext(ctx, `INSERT INTO source_selection_sessions(id,user_id,query,context,candidates,expires_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING created_at`, session.ID, session.UserID, session.Query, session.Context, session.Candidates, session.ExpiresAt).Scan(&session.CreatedAt)
}

func CapturedSourceTx(ctx context.Context, tx *sql.Tx, userID, sessionID uuid.UUID, candidateID string, now time.Time) (json.RawMessage, time.Time, error) {
	var snapshot json.RawMessage
	var expires time.Time
	err := tx.QueryRowContext(ctx, `SELECT candidates,expires_at FROM source_selection_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE`, sessionID, userID).Scan(&snapshot, &expires)
	if err != nil {
		return nil, expires, err
	}
	if !now.Before(expires) {
		return nil, expires, ErrSourceSelectionSessionNotFound
	}
	candidates, _, err := validateCandidatesSnapshot(snapshot, "")
	if err != nil {
		return nil, expires, err
	}
	selected, ok := candidates[candidateID]
	if !ok {
		return nil, expires, ErrInvalidSourceSelection
	}
	return selected, expires, nil
}

// CreateCapturedSourceDownloadTx is an atomic publication: one neutral discovery
// decision and either exact stored-source membership OR one durable job. Redis
// is an idempotent projection after commit, recoverable by the existing lifecycle.
// The caller holds its authority/consent rows and owns the outer transaction.
func CreateCapturedSourceDownloadTx(ctx context.Context, tx *sql.Tx, userID, sessionID, decisionID, jobID uuid.UUID, candidateID string, expected json.RawMessage, now time.Time) (int64, bool, error) {
	selected, _, err := CapturedSourceTx(ctx, tx, userID, sessionID, candidateID, now)
	if err != nil {
		return 0, false, err
	}
	var a, b any
	if json.Unmarshal(selected, &a) != nil || json.Unmarshal(expected, &b) != nil {
		return 0, false, ErrInvalidSourceSelection
	}
	aa, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	if string(aa) != string(bb) {
		return 0, false, ErrSourceSelectionConflict
	}
	candidate, err := candidateFromPersistedSelection(selected)
	if err != nil {
		return 0, false, err
	}
	var track int64
	err = tx.QueryRowContext(ctx, `SELECT t.id FROM tracks t JOIN track_sources s ON s.track_id=t.id WHERE s.provider=$1 AND (($2<>'' AND s.source_id=$2) OR s.source_url=$3) AND COALESCE(t.storage_key,'')<>'' ORDER BY t.id LIMIT 1 FOR SHARE OF t,s`, candidate.Provider, candidate.SourceID, candidate.SourceURL).Scan(&track)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, false, err
	}
	stored := err == nil
	if stored {
		if _, err = tx.ExecContext(ctx, `INSERT INTO user_library(user_id,track_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, userID, track); err != nil {
			return 0, false, err
		}
	} else {
		job := newSourceSelectionDownloadJob(userID, candidate)
		metadata, _ := json.Marshal(candidate.Metadata)
		if _, err = tx.ExecContext(ctx, sourceSelectionDownloadJobInsert, jobID, userID, job.URL, job.SourceType, job.CandidateID, job.SourceID, job.Title, job.Artist, job.Album, job.Uploader, job.DurationMs, job.ThumbnailURL, metadata); err != nil {
			return 0, false, err
		}
	}
	var trackArg, jobArg any
	if stored {
		trackArg = track
	} else {
		jobArg = jobID
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO source_selection_decisions(id,session_id,session_owner_id,user_id,selected_candidate_id,action,origin,selected_candidate,source_quality,download_job_id,track_id) VALUES($1,$2,$3,$3,$4,'selected','discovery',$5,'{}',$6,$7)`, decisionID, sessionID, userID, candidateID, selected, jobArg, trackArg)
	return track, !stored, err
}

// SourceCandidateFromCapture exposes only the validated existing recovery decoder.
func SourceCandidateFromCapture(snapshot json.RawMessage) (download.SourceCandidate, error) {
	return candidateFromPersistedSelection(snapshot)
}
