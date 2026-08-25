package db

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

const nearbyTracksResultLimit = 100

// AffinityRank orders the harmonically feasible candidate set by personal
// listening affinity before the harmonic proximity tie-breaks.
type AffinityRank string

const (
	// AffinityRankOff is the pure harmonic ordering (BPM proximity first) used
	// by slice 1 and by users with no listening history.
	AffinityRankOff AffinityRank = ""
	// AffinityRankHistory orders by history affinity desc, then BPM proximity,
	// then title, then track id.
	AffinityRankHistory AffinityRank = "history"
)

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
//
// With rank = AffinityRankHistory the harmonic feasible set is re-ordered by
// listening affinity: each non-skipped play event contributes
// exp(-age_seconds / half_life_seconds), summed per track (track-level
// weighting only — artist-level counts are folded in via the same track rows,
// so no extra join is needed for this schema). The exponential recency decay
// means a recently-played track outranks an equally-played older one, and
// tracks with zero plays score 0, below anything with plays. Users with an
// empty play_events history all score 0 and fall back to the pure harmonic
// ordering deterministically.
func (r *LibraryRepository) NearbyTracks(
	ctx context.Context,
	userID uuid.UUID,
	bpm, tolerance float64,
	camelotCandidates []string,
	rank AffinityRank,
) ([]NearbyTrack, error) {
	if math.IsNaN(bpm) || math.IsInf(bpm, 0) || bpm <= 0 ||
		math.IsNaN(tolerance) || math.IsInf(tolerance, 0) || tolerance < 0 ||
		len(camelotCandidates) == 0 {
		return nil, ErrInvalidNearbyTrackQuery
	}
	if rank != AffinityRankOff && rank != AffinityRankHistory {
		return nil, ErrInvalidNearbyTrackQuery
	}

	lower := bpm - tolerance
	upper := bpm + tolerance

	// affinity_expr is NULL for tracks with no play events; NULLS LAST puts
	// every never-played track after played ones while keeping one stable SQL
	// shape for both ranking modes.
	const affinityExpr = `(
		SELECT SUM(EXP(-EXTRACT(EPOCH FROM (NOW() - pe.played_at)) / $8))
		FROM play_events pe
		WHERE pe.user_id = ul.user_id AND pe.track_id = t.id AND NOT pe.skipped
	)`

	orderClause := "ABS(ta.effective_bpm - $6), t.title ASC, t.id ASC"
	args := []any{userID, AnalysisStatusAnalyzed, pq.Array(camelotCandidates), lower, upper, bpm, nearbyTracksResultLimit}
	if rank == AffinityRankHistory {
		orderClause = affinityExpr + " DESC NULLS LAST, ABS(ta.effective_bpm - $6), t.title ASC, t.id ASC"
		args = append(args, affinityHalfLifeSeconds)
	}

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
		ORDER BY `+orderClause+`
		LIMIT $7
	`, args...)
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

// AffinityHalfLife is the documented recency-decay constant of the history
// ranking: one play event's contribution halves every 24 hours of age.
const affinityHalfLifeSeconds float64 = 24 * 60 * 60

// AffinityHalfLife exposes the decay constant for API documentation/tests.
func AffinityHalfLife() time.Duration {
	return time.Duration(affinityHalfLifeSeconds * float64(time.Second))
}
