package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// CatalogMembership is a committed membership acknowledgement, not a media grant.
type CatalogMembership struct {
	RecordingMBID string    `json:"recordingMbid"`
	UserID        uuid.UUID `json:"userId"`
	TrackID       int64     `json:"trackId"`
	Status        string    `json:"status"`
	AddedAt       time.Time `json:"addedAt"`
}

type CatalogMembershipRefusal string

func (e CatalogMembershipRefusal) Error() string { return string(e) }

const (
	CatalogTargetUnavailable CatalogMembershipRefusal = "TARGET_UNAVAILABLE"
	CatalogTargetMismatch    CatalogMembershipRefusal = "TARGET_MISMATCH"
	CatalogNeedsReview       CatalogMembershipRefusal = "NEEDS_REVIEW"
)

// AddCatalogMembership locks only the selected track FOR UPDATE: unlike KEY SHARE,
// this excludes non-key MBID/verification updates through membership commit. The
// following READ COMMITTED statement admits exactly one matching row at its own
// snapshot. Concurrent new competing evidence after that snapshot is not excluded;
// later resolver reads may therefore report ambiguity. No predicate-lock claim is
// made. The selected identity remains protected, regardless of other writers.
func (r *LibraryRepository) AddCatalogMembership(ctx context.Context, userID, recordingID uuid.UUID, trackID int64) (CatalogMembership, error) {
	result := CatalogMembership{RecordingMBID: recordingID.String(), UserID: userID, TrackID: trackID, Status: "member"}
	if userID == uuid.Nil || recordingID == uuid.Nil || trackID <= 0 {
		return CatalogMembership{}, fmt.Errorf("non-nil user/recording and positive track required")
	}
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return CatalogMembership{}, fmt.Errorf("begin catalog membership: %w", err)
	}
	defer tx.Rollback()
	var recording uuid.NullUUID
	var verified bool
	err = tx.QueryRowContext(ctx, `SELECT mb_recording_id, mb_verified FROM tracks WHERE id=$1 FOR UPDATE`, trackID).Scan(&recording, &verified)
	if errors.Is(err, sql.ErrNoRows) {
		return CatalogMembership{}, CatalogTargetUnavailable
	}
	if err != nil {
		return CatalogMembership{}, fmt.Errorf("lock catalog target: %w", err)
	}
	if !recording.Valid || recording.UUID != recordingID {
		return CatalogMembership{}, CatalogTargetMismatch
	}
	if !verified {
		return CatalogMembership{}, CatalogNeedsReview
	}
	var ambiguous bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM tracks WHERE mb_recording_id=$1 AND id<>$2)`, recordingID, trackID).Scan(&ambiguous); err != nil {
		return CatalogMembership{}, fmt.Errorf("check catalog evidence: %w", err)
	}
	if ambiguous {
		return CatalogMembership{}, CatalogNeedsReview
	}
	// DO NOTHING preserves added_at and any existing membership state. The selected
	// track lock serializes identical requests. Lock the resulting membership too,
	// so a concurrent ordinary removal cannot retire it before this commit.
	if _, err = tx.ExecContext(ctx, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2) ON CONFLICT (user_id,track_id) DO NOTHING`, userID, trackID); err != nil {
		return CatalogMembership{}, fmt.Errorf("insert catalog membership: %w", err)
	}
	if err = tx.QueryRowContext(ctx, `SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2 FOR UPDATE`, userID, trackID).Scan(&result.AddedAt); err != nil {
		return CatalogMembership{}, fmt.Errorf("read catalog membership: %w", err)
	}
	if err = tx.Commit(); err != nil {
		return CatalogMembership{}, fmt.Errorf("commit catalog membership: %w", err)
	}
	return result, nil
}
