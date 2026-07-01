package db

import (
	"context"
	"database/sql"
	"time"

	"github.com/google/uuid"
)

// RecentlyPlayedTrack is a track surfaced by the recently-played listing, deduped
// so each track appears once at the time of its most recent play.
type RecentlyPlayedTrack struct {
	Track
	LastPlayedAt time.Time
}

// TopTrack is a track surfaced by the top-tracks listing along with its in-window
// play count and the time of its most recent play.
type TopTrack struct {
	Track
	PlayCount    int
	LastPlayedAt time.Time
}

// PlayEventRepository records play events and serves recently-played / top-track
// listings. All reads and writes are scoped to a single user.
type PlayEventRepository struct {
	db *DB
}

func NewPlayEventRepository(db *DB) *PlayEventRepository {
	return &PlayEventRepository{db: db}
}

// RecordPlay inserts a single play event with a server-set played_at. contextType
// and contextID are optional; empty strings are stored as SQL NULL.
func (r *PlayEventRepository) RecordPlay(ctx context.Context, userID uuid.UUID, trackID int64, contextType, contextID string) error {
	query := `
		INSERT INTO play_events (user_id, track_id, context_type, context_id)
		VALUES ($1, $2, $3, $4)
	`
	_, err := r.db.ExecContext(ctx, query,
		userID,
		trackID,
		sql.NullString{String: contextType, Valid: contextType != ""},
		sql.NullString{String: contextID, Valid: contextID != ""},
	)
	return err
}

// RecentlyPlayed returns the user's recently played tracks deduped by track (one
// row per track at its most recent play), newest first, honoring limit/offset.
func (r *PlayEventRepository) RecentlyPlayed(ctx context.Context, userID uuid.UUID, limit, offset int) ([]RecentlyPlayedTrack, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	query := `
		SELECT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
			   t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at,
			   pe.last_played_at
		FROM (
			SELECT track_id, MAX(played_at) AS last_played_at
			FROM play_events
			WHERE user_id = $1
			GROUP BY track_id
		) pe
		JOIN tracks t ON t.id = pe.track_id
		ORDER BY pe.last_played_at DESC, t.id DESC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, query, userID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tracks []RecentlyPlayedTrack
	for rows.Next() {
		var rt RecentlyPlayedTrack
		if err := rows.Scan(
			&rt.ID, &rt.IdentityHash, &rt.Title, &rt.Artist, &rt.Album, &rt.DurationMs, &rt.Version,
			&rt.MBRecordingID, &rt.MBReleaseID, &rt.MBArtistID, &rt.MBVerified,
			&rt.SourceURL, &rt.SourceType, &rt.StorageKey, &rt.FileSizeBytes,
			&rt.MetadataJSON, &rt.MetadataStatus, &rt.MetadataConfidence, &rt.MetadataProvenance,
			&rt.CoverArtURL, &rt.MetadataUserEdited, &rt.CreatedAt, &rt.UpdatedAt,
			&rt.LastPlayedAt,
		); err != nil {
			return nil, err
		}
		tracks = append(tracks, rt)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}

// TopTracks returns the user's most-played tracks within the trailing window of
// days, ordered by play count desc then most-recent play. Tracks with no plays in
// the window are absent.
func (r *PlayEventRepository) TopTracks(ctx context.Context, userID uuid.UUID, days, limit int) ([]TopTrack, error) {
	if days <= 0 {
		days = 30
	}
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	query := `
		SELECT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
			   t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at,
			   agg.play_count, agg.last_played_at
		FROM (
			SELECT track_id, COUNT(*) AS play_count, MAX(played_at) AS last_played_at
			FROM play_events
			WHERE user_id = $1 AND played_at >= NOW() - make_interval(days => $2)
			GROUP BY track_id
		) agg
		JOIN tracks t ON t.id = agg.track_id
		ORDER BY agg.play_count DESC, agg.last_played_at DESC, t.id DESC
		LIMIT $3
	`

	rows, err := r.db.QueryContext(ctx, query, userID, days, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tracks []TopTrack
	for rows.Next() {
		var tt TopTrack
		if err := rows.Scan(
			&tt.ID, &tt.IdentityHash, &tt.Title, &tt.Artist, &tt.Album, &tt.DurationMs, &tt.Version,
			&tt.MBRecordingID, &tt.MBReleaseID, &tt.MBArtistID, &tt.MBVerified,
			&tt.SourceURL, &tt.SourceType, &tt.StorageKey, &tt.FileSizeBytes,
			&tt.MetadataJSON, &tt.MetadataStatus, &tt.MetadataConfidence, &tt.MetadataProvenance,
			&tt.CoverArtURL, &tt.MetadataUserEdited, &tt.CreatedAt, &tt.UpdatedAt,
			&tt.PlayCount, &tt.LastPlayedAt,
		); err != nil {
			return nil, err
		}
		tracks = append(tracks, tt)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}
