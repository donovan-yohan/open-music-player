package db

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// RadarSeeds counts unresolved distinct listened tracks, not guessed artists.
// Events and identities cover the entire server window, independent of Home paging.
type RadarSeeds struct {
	Artists               []uuid.UUID
	Available             int
	Events                int
	UnresolvedTracks      int
	UnlinkedLibraryTracks int
}

func (r *PlayEventRepository) RecentArtistSeeds(ctx context.Context, user uuid.UUID, since, through time.Time, limit int) (RadarSeeds, error) {
	var out RadarSeeds
	if user == uuid.Nil || limit < 1 || limit > 5 || !since.Before(through) {
		return out, fmt.Errorf("invalid radar seed scope")
	}
	rows, err := r.db.QueryContext(ctx, `
 WITH listened AS (
  SELECT p.track_id,p.played_at,t.mb_artist_id,t.mb_verified
  FROM play_events p JOIN tracks t ON t.id=p.track_id
  WHERE p.user_id=$1 AND t.private_owner_id IS NULL AND NOT p.skipped AND p.played_at >= $2 AND p.played_at <= $3
 ), artists AS (
  SELECT mb_artist_id,MAX(played_at) AS latest FROM listened
  WHERE mb_verified AND mb_artist_id IS NOT NULL AND mb_artist_id <> '00000000-0000-0000-0000-000000000000'::uuid
  GROUP BY mb_artist_id
 ), selected AS (SELECT * FROM artists ORDER BY latest DESC,mb_artist_id LIMIT $4)
 SELECT selected.mb_artist_id,(SELECT COUNT(*) FROM artists),(SELECT COUNT(*) FROM listened),
  (SELECT COUNT(DISTINCT track_id) FROM listened WHERE NOT mb_verified OR mb_artist_id IS NULL OR mb_artist_id='00000000-0000-0000-0000-000000000000'::uuid),
  (SELECT COUNT(*) FROM user_library ul JOIN tracks t ON t.id=ul.track_id WHERE ul.user_id=$1 AND t.private_owner_id IS NULL AND (t.mb_recording_id IS NULL OR t.mb_recording_id='00000000-0000-0000-0000-000000000000'::uuid))
 FROM (SELECT 1) anchor LEFT JOIN selected ON TRUE ORDER BY selected.latest DESC,selected.mb_artist_id`, user, since, through, limit)
	if err != nil {
		return out, fmt.Errorf("read radar seeds: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.NullUUID
		if err = rows.Scan(&id, &out.Available, &out.Events, &out.UnresolvedTracks, &out.UnlinkedLibraryTracks); err != nil {
			return RadarSeeds{}, err
		}
		if id.Valid {
			out.Artists = append(out.Artists, id.UUID)
		}
	}
	return out, rows.Err()
}

// Discovery membership is any linked shared current-account row, irrespective of verification,
// edition, numeric copies or resolver ambiguity. No global catalog projection.
func (r *LibraryRepository) OwnedRecordingIDs(ctx context.Context, user uuid.UUID, ids []uuid.UUID) (map[uuid.UUID]bool, error) {
	if user == uuid.Nil || len(ids) > 200 {
		return nil, fmt.Errorf("invalid radar membership scope")
	}
	out := make(map[uuid.UUID]bool)
	if len(ids) == 0 {
		return out, nil
	}
	values := make([]string, len(ids))
	for i, id := range ids {
		if id == uuid.Nil {
			return nil, fmt.Errorf("invalid recording")
		}
		values[i] = id.String()
	}
	rows, err := r.db.QueryContext(ctx, `SELECT DISTINCT t.mb_recording_id FROM user_library ul JOIN tracks t ON t.id=ul.track_id WHERE ul.user_id=$1 AND t.private_owner_id IS NULL AND t.mb_recording_id=ANY($2::uuid[])`, user, pq.Array(values))
	if err != nil {
		return nil, fmt.Errorf("read radar membership: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		if err = rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}
