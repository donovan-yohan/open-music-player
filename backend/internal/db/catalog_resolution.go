package db

import (
	"context"
	"fmt"

	"github.com/google/uuid"
)

const CatalogResolutionLimit = 20

// CatalogTrackCandidate deliberately excludes storage, source and other-owner facts.
// MBVerified is identity evidence, not a guarantee of playable bytes.
type CatalogTrackCandidate struct {
	TrackID    int64 `json:"trackId"`
	MBVerified bool  `json:"mbVerified"`
	InLibrary  bool  `json:"inLibrary"`
}

// ResolveCatalogRecording reads exact stored metadata and this user's membership in
// one statement/snapshot. One extra row detects truncation without counting all matches.
func (r *TrackRepository) ResolveCatalogRecording(ctx context.Context, recordingID, userID uuid.UUID) ([]CatalogTrackCandidate, bool, error) {
	if recordingID == uuid.Nil || userID == uuid.Nil {
		return nil, false, fmt.Errorf("recording and user identifiers must be non-nil")
	}
	rows, err := r.db.QueryContext(ctx, `SELECT t.id, t.mb_verified,
 EXISTS(SELECT 1 FROM user_library ul WHERE ul.track_id=t.id AND ul.user_id=$2)
 FROM tracks t WHERE t.mb_recording_id=$1 ORDER BY t.id LIMIT $3`, recordingID, userID, CatalogResolutionLimit+1)
	if err != nil {
		return nil, false, fmt.Errorf("resolve catalog recording: %w", err)
	}
	defer rows.Close()
	candidates := make([]CatalogTrackCandidate, 0)
	for rows.Next() {
		var c CatalogTrackCandidate
		if err := rows.Scan(&c.TrackID, &c.MBVerified, &c.InLibrary); err != nil {
			return nil, false, fmt.Errorf("scan catalog candidate: %w", err)
		}
		candidates = append(candidates, c)
	}
	if err := rows.Err(); err != nil {
		return nil, false, fmt.Errorf("read catalog candidates: %w", err)
	}
	truncated := len(candidates) > CatalogResolutionLimit
	if truncated {
		candidates = candidates[:CatalogResolutionLimit]
	}
	return candidates, truncated, nil
}
