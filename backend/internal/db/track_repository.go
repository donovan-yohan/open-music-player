package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
)

var ErrTrackNotFound = errors.New("track not found")

type Track struct {
	ID            int64
	IdentityHash  string
	Title         string
	Artist        sql.NullString
	Album         sql.NullString
	DurationMs    sql.NullInt32
	Version       sql.NullString
	MBRecordingID *uuid.UUID
	MBReleaseID   *uuid.UUID
	MBArtistID    *uuid.UUID
	MBVerified    bool
	SourceURL     sql.NullString
	SourceType    sql.NullString
	StorageKey    sql.NullString
	FileSizeBytes sql.NullInt64
	MetadataJSON  json.RawMessage
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type Artist struct {
	Name       string
	MBArtistID *uuid.UUID
	TrackCount int
}

type Release struct {
	Name        string
	Artist      string
	MBReleaseID *uuid.UUID
	TrackCount  int
}

type TrackRepository struct {
	db *DB
}

func NewTrackRepository(db *DB) *TrackRepository {
	return &TrackRepository{db: db}
}

// SearchRecordings searches tracks by title with optional artist filter
func (r *TrackRepository) SearchRecordings(ctx context.Context, query string, limit, offset int) ([]Track, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	// Count total matches
	countQuery := `
		SELECT COUNT(*) FROM tracks
		WHERE title ILIKE $1 OR artist ILIKE $1 OR album ILIKE $1
	`
	var total int
	searchPattern := "%" + query + "%"
	if err := r.db.QueryRowContext(ctx, countQuery, searchPattern).Scan(&total); err != nil {
		return nil, 0, err
	}

	// Get paginated results
	selectQuery := `
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, created_at, updated_at
		FROM tracks
		WHERE title ILIKE $1 OR artist ILIKE $1 OR album ILIKE $1
		ORDER BY
			CASE WHEN title ILIKE $1 THEN 0 ELSE 1 END,
			title ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, searchPattern, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var tracks []Track
	for rows.Next() {
		var t Track
		err := rows.Scan(
			&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
			&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
			&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
			&t.MetadataJSON, &t.CreatedAt, &t.UpdatedAt,
		)
		if err != nil {
			return nil, 0, err
		}
		tracks = append(tracks, t)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return tracks, total, nil
}

// SearchArtists searches distinct artists by name
func (r *TrackRepository) SearchArtists(ctx context.Context, query string, limit, offset int) ([]Artist, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	searchPattern := "%" + query + "%"

	// Count distinct artists
	countQuery := `
		SELECT COUNT(DISTINCT artist) FROM tracks
		WHERE artist ILIKE $1 AND artist IS NOT NULL
	`
	var total int
	if err := r.db.QueryRowContext(ctx, countQuery, searchPattern).Scan(&total); err != nil {
		return nil, 0, err
	}

	// Get paginated results with track counts
	selectQuery := `
		SELECT artist, mb_artist_id, COUNT(*) as track_count
		FROM tracks
		WHERE artist ILIKE $1 AND artist IS NOT NULL
		GROUP BY artist, mb_artist_id
		ORDER BY
			CASE WHEN artist ILIKE $2 THEN 0 ELSE 1 END,
			track_count DESC,
			artist ASC
		LIMIT $3 OFFSET $4
	`

	exactPattern := query + "%"
	rows, err := r.db.QueryContext(ctx, selectQuery, searchPattern, exactPattern, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var artists []Artist
	for rows.Next() {
		var a Artist
		err := rows.Scan(&a.Name, &a.MBArtistID, &a.TrackCount)
		if err != nil {
			return nil, 0, err
		}
		artists = append(artists, a)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return artists, total, nil
}

// SearchReleases searches distinct albums/releases by name
func (r *TrackRepository) SearchReleases(ctx context.Context, query string, limit, offset int) ([]Release, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	searchPattern := "%" + query + "%"

	// Count distinct releases
	countQuery := `
		SELECT COUNT(DISTINCT album) FROM tracks
		WHERE album ILIKE $1 AND album IS NOT NULL
	`
	var total int
	if err := r.db.QueryRowContext(ctx, countQuery, searchPattern).Scan(&total); err != nil {
		return nil, 0, err
	}

	// Get paginated results with track counts
	selectQuery := `
		SELECT album, artist, mb_release_id, COUNT(*) as track_count
		FROM tracks
		WHERE album ILIKE $1 AND album IS NOT NULL
		GROUP BY album, artist, mb_release_id
		ORDER BY
			CASE WHEN album ILIKE $2 THEN 0 ELSE 1 END,
			track_count DESC,
			album ASC
		LIMIT $3 OFFSET $4
	`

	exactPattern := query + "%"
	rows, err := r.db.QueryContext(ctx, selectQuery, searchPattern, exactPattern, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var releases []Release
	for rows.Next() {
		var release Release
		var artist sql.NullString
		err := rows.Scan(&release.Name, &artist, &release.MBReleaseID, &release.TrackCount)
		if err != nil {
			return nil, 0, err
		}
		if artist.Valid {
			release.Artist = artist.String
		}
		releases = append(releases, release)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return releases, total, nil
}

// GetByID retrieves a track by its ID
func (r *TrackRepository) GetByID(ctx context.Context, id int64) (*Track, error) {
	query := `
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, created_at, updated_at
		FROM tracks
		WHERE id = $1
	`

	var t Track
	err := r.db.QueryRowContext(ctx, query, id).Scan(
		&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
		&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
		&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
		&t.MetadataJSON, &t.CreatedAt, &t.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrTrackNotFound
		}
		return nil, err
	}

	return &t, nil
}
