package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

var ErrTrackNotFound = errors.New("track not found")
var ErrDuplicateTrack = errors.New("track with this identity hash already exists")

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

// MBMatchUpdate contains the MusicBrainz match data to update
type MBMatchUpdate struct {
	MBRecordingID *uuid.UUID
	MBReleaseID   *uuid.UUID
	MBArtistID    *uuid.UUID
	MBVerified    bool
	MetadataJSON  json.RawMessage // For storing suggestions when unverified
}

// UpdateMBMatch updates a track's MusicBrainz identifiers and verification status
func (r *TrackRepository) UpdateMBMatch(ctx context.Context, trackID int64, match *MBMatchUpdate) error {
	query := `
		UPDATE tracks
		SET mb_recording_id = $2,
			mb_release_id = $3,
			mb_artist_id = $4,
			mb_verified = $5,
			metadata_json = COALESCE($6, metadata_json),
			updated_at = NOW()
		WHERE id = $1
	`

	result, err := r.db.ExecContext(ctx, query,
		trackID,
		match.MBRecordingID,
		match.MBReleaseID,
		match.MBArtistID,
		match.MBVerified,
		match.MetadataJSON,
	)
	if err != nil {
		return err
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrTrackNotFound
	}

	return nil
}

// GetByIdentityHash retrieves a track by its identity hash.
func (r *TrackRepository) GetByIdentityHash(ctx context.Context, identityHash string) (*Track, error) {
	query := `
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, created_at, updated_at
		FROM tracks
		WHERE identity_hash = $1
	`

	var t Track
	err := r.db.QueryRowContext(ctx, query, identityHash).Scan(
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

// Create inserts a new track into the database.
// Returns ErrDuplicateTrack if a track with the same identity hash already exists.
func (r *TrackRepository) Create(ctx context.Context, track *Track) error {
	query := `
		INSERT INTO tracks (
			identity_hash, title, artist, album, duration_ms, version,
			mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			source_url, source_type, storage_key, file_size_bytes, metadata_json
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
		RETURNING id, created_at, updated_at
	`

	err := r.db.QueryRowContext(ctx, query,
		track.IdentityHash, track.Title, track.Artist, track.Album, track.DurationMs, track.Version,
		track.MBRecordingID, track.MBReleaseID, track.MBArtistID, track.MBVerified,
		track.SourceURL, track.SourceType, track.StorageKey, track.FileSizeBytes, track.MetadataJSON,
	).Scan(&track.ID, &track.CreatedAt, &track.UpdatedAt)

	if err != nil {
		// Check for unique constraint violation on identity_hash
		if strings.Contains(err.Error(), "duplicate key") ||
			strings.Contains(err.Error(), "unique constraint") ||
			strings.Contains(err.Error(), "idx_tracks_identity_hash") {
			return ErrDuplicateTrack
		}
		return err
	}

	return nil
}

// CreateOrGet attempts to create a new track, but if a track with the same
// identity hash already exists, it returns the existing track instead.
// The second return value indicates whether a new track was created (true)
// or an existing track was returned (false).
func (r *TrackRepository) CreateOrGet(ctx context.Context, track *Track) (*Track, bool, error) {
	// First, try to get existing track by identity hash
	existing, err := r.GetByIdentityHash(ctx, track.IdentityHash)
	if err == nil {
		// Track already exists, return it
		return existing, false, nil
	}
	if !errors.Is(err, ErrTrackNotFound) {
		// Unexpected error
		return nil, false, err
	}

	// Track doesn't exist, try to create it
	if err := r.Create(ctx, track); err != nil {
		if errors.Is(err, ErrDuplicateTrack) {
			// Race condition: another process created the track
			// Try to fetch it again
			existing, err = r.GetByIdentityHash(ctx, track.IdentityHash)
			if err != nil {
				return nil, false, err
			}
			return existing, false, nil
		}
		return nil, false, err
	}

	return track, true, nil
}

// CreateTrackFromMetadata creates a track from raw metadata, handling normalization
// and identity hash calculation automatically. Returns the created or existing track.
func (r *TrackRepository) CreateTrackFromMetadata(ctx context.Context, artist, title, album string, durationMs int, opts ...TrackOption) (*Track, bool, error) {
	// Parse metadata and extract version
	identity := ParseTrackMetadata(artist, title, album, durationMs)

	// Calculate identity hash
	identityHash := CalculateIdentityHashFromTrack(identity)

	// Create track with normalized data
	track := &Track{
		IdentityHash: identityHash,
		Title:        identity.Title,
		Artist:       sql.NullString{String: artist, Valid: artist != ""},
		Album:        sql.NullString{String: album, Valid: album != ""},
		DurationMs:   sql.NullInt32{Int32: int32(durationMs), Valid: durationMs > 0},
		Version:      sql.NullString{String: identity.Version, Valid: identity.Version != ""},
	}

	// Apply optional fields
	for _, opt := range opts {
		opt(track)
	}

	return r.CreateOrGet(ctx, track)
}

// TrackOption is a functional option for configuring a track during creation.
type TrackOption func(*Track)

// WithMusicBrainzIDs sets MusicBrainz IDs on the track.
func WithMusicBrainzIDs(recordingID, releaseID, artistID *uuid.UUID) TrackOption {
	return func(t *Track) {
		t.MBRecordingID = recordingID
		t.MBReleaseID = releaseID
		t.MBArtistID = artistID
		if recordingID != nil || releaseID != nil || artistID != nil {
			t.MBVerified = true
		}
	}
}

// WithSource sets the source URL and type on the track.
func WithSource(sourceURL, sourceType string) TrackOption {
	return func(t *Track) {
		t.SourceURL = sql.NullString{String: sourceURL, Valid: sourceURL != ""}
		t.SourceType = sql.NullString{String: sourceType, Valid: sourceType != ""}
	}
}

// WithStorage sets the storage key and file size on the track.
func WithStorage(storageKey string, fileSizeBytes int64) TrackOption {
	return func(t *Track) {
		t.StorageKey = sql.NullString{String: storageKey, Valid: storageKey != ""}
		t.FileSizeBytes = sql.NullInt64{Int64: fileSizeBytes, Valid: fileSizeBytes > 0}
	}
}

// WithMetadata sets additional metadata JSON on the track.
func WithMetadata(metadata json.RawMessage) TrackOption {
	return func(t *Track) {
		t.MetadataJSON = metadata
	}
}

// GetUnverifiedTracks returns tracks without MB verification for batch processing
func (r *TrackRepository) GetUnverifiedTracks(ctx context.Context, limit, offset int) ([]Track, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	countQuery := `SELECT COUNT(*) FROM tracks WHERE mb_verified = FALSE`
	var total int
	if err := r.db.QueryRowContext(ctx, countQuery).Scan(&total); err != nil {
		return nil, 0, err
	}

	selectQuery := `
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, created_at, updated_at
		FROM tracks
		WHERE mb_verified = FALSE
		ORDER BY created_at DESC
		LIMIT $1 OFFSET $2
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, limit, offset)
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
