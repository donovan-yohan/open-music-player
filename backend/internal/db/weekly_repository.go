package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/weekly"
)

type WeeklyRepository struct{ db *DB }

func NewWeeklyRepository(database *DB) *WeeklyRepository { return &WeeklyRepository{database} }

// Update serializes only this account. No provider I/O is performed while locked.
func (r *WeeklyRepository) Update(ctx context.Context, user uuid.UUID, fn func(*weekly.State) error) error {
	if user == uuid.Nil {
		return fmt.Errorf("weekly account required")
	}
	tx, e := r.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	initial, _ := json.Marshal(weekly.NewState())
	if _, e = tx.ExecContext(ctx, `INSERT INTO weekly_profiles(user_id,state) VALUES($1,$2) ON CONFLICT(user_id) DO NOTHING`, user, string(initial)); e != nil {
		return e
	}
	var b []byte
	if e = tx.QueryRowContext(ctx, `SELECT state FROM weekly_profiles WHERE user_id=$1 FOR UPDATE`, user).Scan(&b); e != nil {
		return e
	}
	if len(b) > 2097152 {
		return fmt.Errorf("weekly state exceeds bound")
	}
	var state weekly.State
	if e = json.Unmarshal(b, &state); e != nil {
		return fmt.Errorf("decode weekly state: %w", e)
	}
	// Capture authoritative metadata while this account is locked, before fn
	// advances any speculative epoch or revisions. Never reread after rollback.
	limit := &weekly.Conflict{Code: "RESOURCE_LIMIT", Detail: "discovery preferences storage limit reached", ProfileEpoch: state.Epoch, PreferenceRevision: state.Revision, FilterRevision: state.FilterRevision}
	if e = fn(&state); e != nil {
		return e
	}
	b, e = json.Marshal(state)
	if e != nil {
		return e
	}
	if len(b) > 1800000 {
		return limit
	}
	if _, e = tx.ExecContext(ctx, `UPDATE weekly_profiles SET state=$2 WHERE user_id=$1`, user, string(b)); e != nil {
		return e
	}
	return tx.Commit()
}
func (r *WeeklyRepository) ArtistEvidence(ctx context.Context, user uuid.UUID, id string) (string, error) {
	var name string
	e := r.db.QueryRowContext(ctx, `SELECT t.artist FROM tracks t JOIN user_library ul ON ul.track_id=t.id WHERE ul.user_id=$1 AND t.mb_verified AND t.mb_artist_id=$2 AND t.artist IS NOT NULL AND length(t.artist) BETWEEN 1 AND 500 ORDER BY t.id LIMIT 1`, user, id).Scan(&name)
	if e == sql.ErrNoRows {
		return "", nil
	}
	return name, e
}
func (r *WeeklyRepository) History(ctx context.Context, user uuid.UUID, now time.Time) (weekly.History, error) {
	out := weekly.History{Short: map[string]string{}, Long: map[string]string{}}
	rows, e := r.db.QueryContext(ctx, `WITH eligible AS (
 SELECT t.mb_artist_id,t.artist,p.played_at,t.mb_verified FROM play_events p JOIN tracks t ON t.id=p.track_id
 WHERE p.user_id=$1 AND NOT p.skipped AND p.played_at >= $2 AND p.played_at <= $3
 ), grouped AS (SELECT mb_artist_id,MIN(artist) AS name,MAX(played_at) AS latest FROM eligible
 WHERE mb_verified AND mb_artist_id IS NOT NULL AND mb_artist_id<>'00000000-0000-0000-0000-000000000000'::uuid GROUP BY mb_artist_id)
 SELECT selected.mb_artist_id,selected.name,selected.latest,(SELECT COUNT(*) FROM eligible WHERE NOT mb_verified OR mb_artist_id IS NULL OR mb_artist_id='00000000-0000-0000-0000-000000000000'::uuid)
 FROM (SELECT 1) anchor LEFT JOIN (SELECT * FROM grouped ORDER BY latest DESC,mb_artist_id LIMIT 5) selected ON TRUE ORDER BY selected.latest DESC,selected.mb_artist_id`, user, now.AddDate(0, 0, -90), now)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.NullUUID
		var name sql.NullString
		var latest sql.NullTime
		if e = rows.Scan(&id, &name, &latest, &out.Unresolved); e != nil {
			return out, e
		}
		if !id.Valid {
			continue
		}
		if !latest.Valid {
			return out, fmt.Errorf("identified history artist missing timestamp")
		}
		out.Long[id.UUID.String()] = name.String
		if !latest.Time.Before(now.AddDate(0, 0, -30)) {
			out.Short[id.UUID.String()] = name.String
		}
	}
	return out, rows.Err()
}
func (r *WeeklyRepository) Eligibility(ctx context.Context, user uuid.UUID, ids []string, now time.Time) (weekly.Eligibility, error) {
	out := weekly.Eligibility{Owned: map[string]bool{}, Recent: map[string]bool{}}
	if len(ids) > 200 {
		return out, fmt.Errorf("weekly eligibility candidate bound")
	}
	rows, e := r.db.QueryContext(ctx, `SELECT DISTINCT t.mb_recording_id FROM user_library ul JOIN tracks t ON t.id=ul.track_id WHERE ul.user_id=$1 AND t.mb_recording_id=ANY($2::uuid[])`, user, pq.Array(ids))
	if e != nil {
		return out, e
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if e = rows.Scan(&id); e != nil {
			return out, e
		}
		out.Owned[id] = true
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	rows, e = r.db.QueryContext(ctx, `SELECT DISTINCT t.mb_recording_id FROM play_events p JOIN tracks t ON t.id=p.track_id WHERE p.user_id=$1 AND NOT p.skipped AND p.played_at >= $2 AND p.played_at <= $3 AND t.mb_recording_id=ANY($4::uuid[])`, user, now.AddDate(0, 0, -30), now, pq.Array(ids))
	if e != nil {
		return out, e
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if e = rows.Scan(&id); e != nil {
			return out, e
		}
		out.Recent[id] = true
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	e = r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM user_library ul JOIN tracks t ON t.id=ul.track_id WHERE ul.user_id=$1 AND (t.mb_recording_id IS NULL OR t.mb_recording_id='00000000-0000-0000-0000-000000000000'::uuid)`, user).Scan(&out.UnresolvedOwned)
	return out, e
}
