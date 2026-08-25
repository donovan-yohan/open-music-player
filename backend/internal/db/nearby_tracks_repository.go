package db

import (
	"context"
	"database/sql"
	"errors"
	"math"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

const nearbyTracksResultLimit = 100

var ErrInvalidNearbyTrackQuery = errors.New("invalid nearby track query")

// NearbyTrack is a library-scoped track candidate with the effective analyzer
// values used to place it in the harmonic search bucket.
type NearbyTrack struct {
	ID               int64
	Title            string
	Artist           sql.NullString
	Album            sql.NullString
	EffectiveBPM     float64
	EffectiveCamelot string
}

// NearbyTracks returns at most 100 analyzed tracks from the caller's library.
// The predicate is intentionally expressed over track_analysis's stored
// effective fields so PostgreSQL can use idx_track_analysis_effective_camelot_bpm
// instead of loading a user's whole library into Go.
func (r *LibraryRepository) NearbyTracks(
	ctx context.Context,
	userID uuid.UUID,
	bpm, tolerance float64,
	camelotCandidates []string,
) ([]NearbyTrack, error) {
	if math.IsNaN(bpm) || math.IsInf(bpm, 0) || bpm <= 0 ||
		math.IsNaN(tolerance) || math.IsInf(tolerance, 0) || tolerance < 0 ||
		len(camelotCandidates) == 0 {
		return nil, ErrInvalidNearbyTrackQuery
	}

	lower := bpm - tolerance
	upper := bpm + tolerance
	rows, err := r.db.QueryContext(ctx, `
		SELECT t.id,
			COALESCE(tmo.title, t.title) AS title,
			COALESCE(tmo.artist, t.artist) AS artist,
			COALESCE(tmo.album, t.album) AS album,
			ta.effective_bpm,
			ta.effective_camelot
		FROM track_analysis ta
		JOIN user_library ul ON ul.track_id = ta.track_id
		JOIN tracks t ON t.id = ta.track_id
		LEFT JOIN track_metadata_overrides tmo
			ON tmo.track_id = t.id AND tmo.user_id = ul.user_id
		WHERE ul.user_id = $1
			AND ta.status = $2
			AND ta.effective_camelot = ANY($3)
			AND ta.effective_bpm BETWEEN $4 AND $5
		ORDER BY ABS(ta.effective_bpm - $6), t.title ASC, t.id ASC
		LIMIT $7
	`, userID, AnalysisStatusAnalyzed, pq.Array(camelotCandidates), lower, upper, bpm, nearbyTracksResultLimit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	tracks := make([]NearbyTrack, 0)
	for rows.Next() {
		var track NearbyTrack
		if err := rows.Scan(
			&track.ID,
			&track.Title,
			&track.Artist,
			&track.Album,
			&track.EffectiveBPM,
			&track.EffectiveCamelot,
		); err != nil {
			return nil, err
		}
		tracks = append(tracks, track)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}
