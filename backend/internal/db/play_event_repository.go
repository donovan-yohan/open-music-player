package db

import (
	"context"
	"database/sql"
	"encoding/json"
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

// PlayHistoryEvent is one raw play event joined with the played track. Unlike
// RecentlyPlayedTrack, this is not deduped: repeated plays of the same track are
// returned as separate rows.
type PlayHistoryEvent struct {
	ID          int64
	Track       Track
	PlayedAt    time.Time
	ContextType sql.NullString
	ContextID   sql.NullString
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
			   ta.status, COALESCE(` + analysisCompactSummaryExpression + `, '{}'::jsonb),
			   COALESCE(` + analysisCompactOverridesExpression + `, '{}'::jsonb),
			   ta.updated_at,
			   pe.last_played_at
		FROM (
			SELECT track_id, MAX(played_at) AS last_played_at
			FROM play_events
			WHERE user_id = $1
			GROUP BY track_id
		) pe
		JOIN tracks t ON t.id = pe.track_id
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
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
		var analysisOverrides json.RawMessage
		if err := rows.Scan(
			&rt.ID, &rt.IdentityHash, &rt.Title, &rt.Artist, &rt.Album, &rt.DurationMs, &rt.Version,
			&rt.MBRecordingID, &rt.MBReleaseID, &rt.MBArtistID, &rt.MBVerified,
			&rt.SourceURL, &rt.SourceType, &rt.StorageKey, &rt.FileSizeBytes,
			&rt.MetadataJSON, &rt.MetadataStatus, &rt.MetadataConfidence, &rt.MetadataProvenance,
			&rt.CoverArtURL, &rt.MetadataUserEdited, &rt.CreatedAt, &rt.UpdatedAt,
			&rt.AnalysisStatus, &rt.AnalysisSummary, &analysisOverrides, &rt.AnalysisUpdatedAt,
			&rt.LastPlayedAt,
		); err != nil {
			return nil, err
		}
		rt.AnalysisSummary, _ = projectCompactAnalysis(rt.AnalysisSummary, analysisOverrides)
		tracks = append(tracks, rt)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}

// PlayHistory returns the user's raw play events newest-first, preserving repeat
// listens and their optional playback context.
func (r *PlayEventRepository) PlayHistory(ctx context.Context, userID uuid.UUID, limit, offset int) ([]PlayHistoryEvent, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	query := `
		SELECT pe.id,
			   t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
			   t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at,
			   ta.status, COALESCE(` + analysisCompactSummaryExpression + `, '{}'::jsonb),
			   COALESCE(` + analysisCompactOverridesExpression + `, '{}'::jsonb),
			   ta.updated_at,
			   pe.played_at, pe.context_type, pe.context_id
		FROM play_events pe
		JOIN tracks t ON t.id = pe.track_id
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
		WHERE pe.user_id = $1
		ORDER BY pe.played_at DESC, pe.id DESC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, query, userID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []PlayHistoryEvent
	for rows.Next() {
		var event PlayHistoryEvent
		var analysisOverrides json.RawMessage
		if err := rows.Scan(
			&event.ID,
			&event.Track.ID, &event.Track.IdentityHash, &event.Track.Title, &event.Track.Artist, &event.Track.Album, &event.Track.DurationMs, &event.Track.Version,
			&event.Track.MBRecordingID, &event.Track.MBReleaseID, &event.Track.MBArtistID, &event.Track.MBVerified,
			&event.Track.SourceURL, &event.Track.SourceType, &event.Track.StorageKey, &event.Track.FileSizeBytes,
			&event.Track.MetadataJSON, &event.Track.MetadataStatus, &event.Track.MetadataConfidence, &event.Track.MetadataProvenance,
			&event.Track.CoverArtURL, &event.Track.MetadataUserEdited, &event.Track.CreatedAt, &event.Track.UpdatedAt,
			&event.Track.AnalysisStatus, &event.Track.AnalysisSummary, &analysisOverrides, &event.Track.AnalysisUpdatedAt,
			&event.PlayedAt, &event.ContextType, &event.ContextID,
		); err != nil {
			return nil, err
		}
		event.Track.AnalysisSummary, _ = projectCompactAnalysis(event.Track.AnalysisSummary, analysisOverrides)
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return events, nil
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
			   ta.status, COALESCE(` + analysisCompactSummaryExpression + `, '{}'::jsonb),
			   COALESCE(` + analysisCompactOverridesExpression + `, '{}'::jsonb),
			   ta.updated_at,
			   agg.play_count, agg.last_played_at
		FROM (
			SELECT track_id, COUNT(*) AS play_count, MAX(played_at) AS last_played_at
			FROM play_events
			WHERE user_id = $1 AND played_at >= NOW() - make_interval(days => $2)
			GROUP BY track_id
		) agg
		JOIN tracks t ON t.id = agg.track_id
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
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
		var analysisOverrides json.RawMessage
		if err := rows.Scan(
			&tt.ID, &tt.IdentityHash, &tt.Title, &tt.Artist, &tt.Album, &tt.DurationMs, &tt.Version,
			&tt.MBRecordingID, &tt.MBReleaseID, &tt.MBArtistID, &tt.MBVerified,
			&tt.SourceURL, &tt.SourceType, &tt.StorageKey, &tt.FileSizeBytes,
			&tt.MetadataJSON, &tt.MetadataStatus, &tt.MetadataConfidence, &tt.MetadataProvenance,
			&tt.CoverArtURL, &tt.MetadataUserEdited, &tt.CreatedAt, &tt.UpdatedAt,
			&tt.AnalysisStatus, &tt.AnalysisSummary, &analysisOverrides, &tt.AnalysisUpdatedAt,
			&tt.PlayCount, &tt.LastPlayedAt,
		); err != nil {
			return nil, err
		}
		tt.AnalysisSummary, _ = projectCompactAnalysis(tt.AnalysisSummary, analysisOverrides)
		tracks = append(tracks, tt)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}
