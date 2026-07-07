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

// trigramSearchThreshold is the minimum pg_trgm similarity() score a row must reach
// to be considered a fuzzy match. It is deliberately loose enough that a single-character
// typo of a stored title/artist still clears it, while filtering out unrelated rows. Exact
// matches score ~1.0 and therefore always rank first. Only used on the fuzzy fallback path
// (FTS returned nothing AND pg_trgm is installed); the FTS path is unaffected.
const trigramSearchThreshold = 0.3

type Track struct {
	ID                 int64
	IdentityHash       string
	Title              string
	Artist             sql.NullString
	Album              sql.NullString
	DurationMs         sql.NullInt32
	Version            sql.NullString
	MBRecordingID      *uuid.UUID
	MBReleaseID        *uuid.UUID
	MBArtistID         *uuid.UUID
	MBVerified         bool
	SourceURL          sql.NullString
	SourceType         sql.NullString
	StorageKey         sql.NullString
	FileSizeBytes      sql.NullInt64
	MetadataJSON       json.RawMessage
	MetadataStatus     sql.NullString
	MetadataConfidence sql.NullFloat64
	MetadataProvenance json.RawMessage
	CoverArtURL        sql.NullString
	MetadataUserEdited bool
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

type Artist struct {
	Name       string
	MBArtistID *uuid.UUID
	TrackCount int
}

type Release struct {
	ID          int64
	Name        string
	Artist      string
	MBReleaseID *uuid.UUID
	CoverArtURL sql.NullString
	TrackCount  int
}

type TrackRepository struct {
	db *DB
}

func NewTrackRepository(db *DB) *TrackRepository {
	return &TrackRepository{db: db}
}

// SearchRecordings searches tracks by title with optional artist filter using full-text search
func (r *TrackRepository) SearchRecordings(ctx context.Context, query string, limit, offset int) ([]Track, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	// Sanitize free-form input into a safe prefix-matching tsquery (see buildPrefixTSQuery).
	tsQuery := buildPrefixTSQuery(query)
	if tsQuery == "" {
		return []Track{}, 0, nil
	}

	// Single query with window function to get both results and total count
	selectQuery := `
		WITH search_results AS (
			SELECT id, identity_hash, title, artist, album, duration_ms, version,
				   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
				   source_url, source_type, storage_key, file_size_bytes,
				   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at,
				   ts_rank(to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')), to_tsquery('english', $1)) as rank,
				   COUNT(*) OVER() as total_count
			FROM tracks
			WHERE to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')) @@ to_tsquery('english', $1)
		)
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at, total_count
		FROM search_results
		ORDER BY rank DESC, title ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, tsQuery, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var tracks []Track
	var total int
	for rows.Next() {
		var t Track
		err := rows.Scan(
			&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
			&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
			&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
			&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
			&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt, &total,
		)
		if err != nil {
			return nil, 0, err
		}
		tracks = append(tracks, t)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	// Fuzzy fallback: when exact prefix FTS matched nothing and pg_trgm is available,
	// retry with a trigram similarity() match so a typo still surfaces the track. When
	// the extension is absent we return the (empty) FTS result unchanged.
	if total == 0 && r.db.TrigramEnabled {
		return r.searchRecordingsTrigram(ctx, query, limit, offset)
	}

	return tracks, total, nil
}

// searchRecordingsTrigram is the pg_trgm fuzzy fallback for SearchRecordings. It ranks
// tracks by the best similarity() across title/artist/album against the raw query and
// keeps only rows at or above trigramSearchThreshold. Callers must gate this on
// r.db.TrigramEnabled; it assumes the extension is installed.
func (r *TrackRepository) searchRecordingsTrigram(ctx context.Context, query string, limit, offset int) ([]Track, int, error) {
	q := strings.TrimSpace(query)
	if q == "" {
		return []Track{}, 0, nil
	}

	selectQuery := `
		WITH search_results AS (
			SELECT id, identity_hash, title, artist, album, duration_ms, version,
				   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
				   source_url, source_type, storage_key, file_size_bytes,
				   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
				   cover_art_url, metadata_user_edited, created_at, updated_at,
				   GREATEST(
					   similarity(COALESCE(title, ''), $1),
					   similarity(COALESCE(artist, ''), $1),
					   similarity(COALESCE(album, ''), $1)
				   ) as rank,
				   COUNT(*) OVER() as total_count
			FROM tracks
			WHERE GREATEST(
					  similarity(COALESCE(title, ''), $1),
					  similarity(COALESCE(artist, ''), $1),
					  similarity(COALESCE(album, ''), $1)
				  ) >= $4
		)
		SELECT id, identity_hash, title, artist, album, duration_ms, version,
			   mb_recording_id, mb_release_id, mb_artist_id, mb_verified,
			   source_url, source_type, storage_key, file_size_bytes,
			   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at, total_count
		FROM search_results
		ORDER BY rank DESC, title ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, q, limit, offset, trigramSearchThreshold)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var tracks []Track
	var total int
	for rows.Next() {
		var t Track
		err := rows.Scan(
			&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
			&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
			&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
			&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
			&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt, &total,
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

// SearchArtists searches distinct artists by name using full-text search
func (r *TrackRepository) SearchArtists(ctx context.Context, query string, limit, offset int) ([]Artist, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	// Sanitize free-form input into a safe prefix-matching tsquery (see buildPrefixTSQuery).
	tsQuery := buildPrefixTSQuery(query)
	if tsQuery == "" {
		return []Artist{}, 0, nil
	}

	// Single query with window function for total count
	selectQuery := `
		WITH artist_results AS (
			SELECT artist, mb_artist_id, COUNT(*) as track_count,
				   ts_rank(to_tsvector('english', artist), to_tsquery('english', $1)) as rank,
				   COUNT(*) OVER() as total_groups
			FROM tracks
			WHERE artist IS NOT NULL
				AND to_tsvector('english', artist) @@ to_tsquery('english', $1)
			GROUP BY artist, mb_artist_id
		)
		SELECT artist, mb_artist_id, track_count, total_groups
		FROM artist_results
		ORDER BY rank DESC, track_count DESC, artist ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, tsQuery, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var artists []Artist
	var total int
	for rows.Next() {
		var a Artist
		err := rows.Scan(&a.Name, &a.MBArtistID, &a.TrackCount, &total)
		if err != nil {
			return nil, 0, err
		}
		artists = append(artists, a)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	if total == 0 && r.db.TrigramEnabled {
		return r.searchArtistsTrigram(ctx, query, limit, offset)
	}

	return artists, total, nil
}

// searchArtistsTrigram is the pg_trgm fuzzy fallback for SearchArtists, ranking distinct
// artists by similarity() against the raw query. Callers must gate this on
// r.db.TrigramEnabled.
func (r *TrackRepository) searchArtistsTrigram(ctx context.Context, query string, limit, offset int) ([]Artist, int, error) {
	q := strings.TrimSpace(query)
	if q == "" {
		return []Artist{}, 0, nil
	}

	selectQuery := `
		WITH artist_results AS (
			SELECT artist, mb_artist_id, COUNT(*) as track_count,
				   MAX(similarity(artist, $1)) as rank,
				   COUNT(*) OVER() as total_groups
			FROM tracks
			WHERE artist IS NOT NULL
				AND similarity(artist, $1) >= $4
			GROUP BY artist, mb_artist_id
		)
		SELECT artist, mb_artist_id, track_count, total_groups
		FROM artist_results
		ORDER BY rank DESC, track_count DESC, artist ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, q, limit, offset, trigramSearchThreshold)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var artists []Artist
	var total int
	for rows.Next() {
		var a Artist
		if err := rows.Scan(&a.Name, &a.MBArtistID, &a.TrackCount, &total); err != nil {
			return nil, 0, err
		}
		artists = append(artists, a)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return artists, total, nil
}

// SearchReleases searches distinct albums/releases by name using full-text search
func (r *TrackRepository) SearchReleases(ctx context.Context, query string, limit, offset int) ([]Release, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	// Sanitize free-form input into a safe prefix-matching tsquery (see buildPrefixTSQuery).
	tsQuery := buildPrefixTSQuery(query)
	if tsQuery == "" {
		return []Release{}, 0, nil
	}

	// Single query with window function for total count
	selectQuery := `
		WITH release_results AS (
			SELECT MIN(id) as id, album, artist, mb_release_id, MAX(cover_art_url) as cover_art_url, COUNT(*) as track_count,
				   ts_rank(to_tsvector('english', album), to_tsquery('english', $1)) as rank,
				   COUNT(*) OVER() as total_groups
			FROM tracks
			WHERE album IS NOT NULL
				AND to_tsvector('english', album) @@ to_tsquery('english', $1)
			GROUP BY album, artist, mb_release_id
		)
		SELECT id, album, artist, mb_release_id, cover_art_url, track_count, total_groups
		FROM release_results
		ORDER BY rank DESC, track_count DESC, album ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, tsQuery, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var releases []Release
	var total int
	for rows.Next() {
		var release Release
		var artist sql.NullString
		err := rows.Scan(&release.ID, &release.Name, &artist, &release.MBReleaseID, &release.CoverArtURL, &release.TrackCount, &total)
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

	if total == 0 && r.db.TrigramEnabled {
		return r.searchReleasesTrigram(ctx, query, limit, offset)
	}

	return releases, total, nil
}

// searchReleasesTrigram is the pg_trgm fuzzy fallback for SearchReleases, ranking distinct
// albums by similarity() against the raw query. Callers must gate this on
// r.db.TrigramEnabled.
func (r *TrackRepository) searchReleasesTrigram(ctx context.Context, query string, limit, offset int) ([]Release, int, error) {
	q := strings.TrimSpace(query)
	if q == "" {
		return []Release{}, 0, nil
	}

	selectQuery := `
		WITH release_results AS (
			SELECT MIN(id) as id, album, artist, mb_release_id, MAX(cover_art_url) as cover_art_url, COUNT(*) as track_count,
				   MAX(similarity(album, $1)) as rank,
				   COUNT(*) OVER() as total_groups
			FROM tracks
			WHERE album IS NOT NULL
				AND similarity(album, $1) >= $4
			GROUP BY album, artist, mb_release_id
		)
		SELECT id, album, artist, mb_release_id, cover_art_url, track_count, total_groups
		FROM release_results
		ORDER BY rank DESC, track_count DESC, album ASC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, q, limit, offset, trigramSearchThreshold)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var releases []Release
	var total int
	for rows.Next() {
		var release Release
		var artist sql.NullString
		if err := rows.Scan(&release.ID, &release.Name, &artist, &release.MBReleaseID, &release.CoverArtURL, &release.TrackCount, &total); err != nil {
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
			   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at
		FROM tracks
		WHERE id = $1
	`

	var t Track
	err := r.db.QueryRowContext(ctx, query, id).Scan(
		&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
		&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
		&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
		&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
		&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt,
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
	MBRecordingID      *uuid.UUID
	MBReleaseID        *uuid.UUID
	MBArtistID         *uuid.UUID
	MBVerified         *bool
	ApplyMBIdentity    bool
	RespectUserEdits   bool
	MetadataJSON       json.RawMessage // For storing suggestions/provenance without replacing raw provider metadata
	MetadataStatus     string
	MetadataConfidence *float64
	// ClearMetadataConfidence explicitly clears stale confidence when a new
	// automatic match result has no current score.
	ClearMetadataConfidence bool
	MetadataProvenance      json.RawMessage
	CoverArtURL             string
	Title                   string
	Artist                  string
	Album                   string
	DurationMs              int
}

// UpdateMBMatch updates a track's MusicBrainz identifiers and verification status
func (r *TrackRepository) UpdateMBMatch(ctx context.Context, trackID int64, match *MBMatchUpdate) error {
	query := `
		UPDATE tracks
		SET mb_recording_id = CASE WHEN $15 AND (metadata_user_edited = FALSE OR $16 = FALSE) THEN $2 ELSE mb_recording_id END,
			mb_release_id = CASE WHEN $15 AND (metadata_user_edited = FALSE OR $16 = FALSE) THEN $3 ELSE mb_release_id END,
			mb_artist_id = CASE WHEN $15 AND (metadata_user_edited = FALSE OR $16 = FALSE) THEN $4 ELSE mb_artist_id END,
			mb_verified = CASE WHEN $5::boolean IS NOT NULL AND (metadata_user_edited = FALSE OR $16 = FALSE) THEN $5::boolean ELSE mb_verified END,
			metadata_json = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(metadata_json, '{}'::jsonb) || COALESCE($6::jsonb, '{}'::jsonb) ELSE metadata_json END,
			metadata_status = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(NULLIF($7, ''), metadata_status) ELSE metadata_status END,
			metadata_confidence = CASE
				WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN
					CASE
						WHEN $17 THEN NULL
						WHEN $8::double precision IS NOT NULL THEN $8::double precision
						ELSE metadata_confidence
					END
				ELSE metadata_confidence
			END,
			metadata_provenance = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(metadata_provenance, '{}'::jsonb) || COALESCE($9::jsonb, '{}'::jsonb) ELSE metadata_provenance END,
			cover_art_url = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(NULLIF($10, ''), cover_art_url) ELSE cover_art_url END,
			title = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(NULLIF($11, ''), title) ELSE title END,
			artist = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(NULLIF($12, ''), artist) ELSE artist END,
			album = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE THEN COALESCE(NULLIF($13, ''), album) ELSE album END,
			duration_ms = CASE WHEN (metadata_user_edited = FALSE OR $16 = FALSE) AND $14 > 0 THEN $14 ELSE duration_ms END,
			updated_at = NOW()
		WHERE id = $1
	`

	result, err := r.db.ExecContext(ctx, query,
		trackID,
		match.MBRecordingID,
		match.MBReleaseID,
		match.MBArtistID,
		match.MBVerified,
		nullableRawJSON(match.MetadataJSON),
		match.MetadataStatus,
		match.MetadataConfidence,
		nullableRawJSON(match.MetadataProvenance),
		match.CoverArtURL,
		match.Title,
		match.Artist,
		match.Album,
		match.DurationMs,
		match.ApplyMBIdentity,
		match.RespectUserEdits,
		match.ClearMetadataConfidence,
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

func nullableRawJSON(raw json.RawMessage) any {
	if len(raw) == 0 {
		return nil
	}
	return string(raw)
}

// ApplyAnalysisGenreHint stores the top analyzer genre hint on a track.
// It intentionally ignores MusicBrainz data and skips user-edited tracks so
// automatic analysis cannot overwrite sticky human metadata.
func (r *TrackRepository) ApplyAnalysisGenreHint(ctx context.Context, trackID int64, summary json.RawMessage) error {
	query := `
		WITH genre_hint AS (
			SELECT LEFT(NULLIF(btrim(CASE
					WHEN jsonb_typeof(hint) = 'object' THEN hint->>'value'
					WHEN jsonb_typeof(hint) = 'string' THEN hint #>> '{}'
					ELSE ''
				END), ''), 200) AS genre
			FROM jsonb_array_elements(CASE
				WHEN jsonb_typeof($2::jsonb->'genre_hints') = 'array' THEN $2::jsonb->'genre_hints'
				ELSE '[]'::jsonb
			END) WITH ORDINALITY AS hints(hint, ordinality)
			WHERE NULLIF(btrim(CASE
					WHEN jsonb_typeof(hint) = 'object' THEN hint->>'value'
					WHEN jsonb_typeof(hint) = 'string' THEN hint #>> '{}'
					ELSE ''
				END), '') IS NOT NULL
			ORDER BY CASE
				WHEN jsonb_typeof(hint) = 'object'
					AND (hint->>'confidence') ~ '^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
				THEN (hint->>'confidence')::double precision
			END DESC NULLS LAST, ordinality ASC
			LIMIT 1
		)
		UPDATE tracks
		SET genre = genre_hint.genre,
			updated_at = NOW()
		FROM genre_hint
		WHERE tracks.id = $1
			AND tracks.metadata_user_edited = FALSE
			AND genre_hint.genre IS NOT NULL
			AND tracks.genre IS DISTINCT FROM genre_hint.genre
	`
	_, err := r.db.ExecContext(ctx, query, trackID, nullableRawJSON(summary))
	return err
}

// MetadataUpdate contains the metadata fields to update from MusicBrainz
type MetadataUpdate struct {
	Title      string
	Artist     string
	Album      string
	DurationMs int
}

// UpdateMetadata updates a track's metadata fields (title, artist, album, duration)
func (r *TrackRepository) UpdateMetadata(ctx context.Context, trackID int64, update *MetadataUpdate) error {
	query := `
		UPDATE tracks
		SET title = COALESCE(NULLIF($2, ''), title),
			artist = COALESCE(NULLIF($3, ''), artist),
			album = COALESCE(NULLIF($4, ''), album),
			duration_ms = CASE WHEN $5 > 0 THEN $5 ELSE duration_ms END,
			metadata_user_edited = TRUE,
			updated_at = NOW()
		WHERE id = $1
	`

	result, err := r.db.ExecContext(ctx, query,
		trackID,
		update.Title,
		update.Artist,
		update.Album,
		update.DurationMs,
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
			   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at
		FROM tracks
		WHERE identity_hash = $1
	`

	var t Track
	err := r.db.QueryRowContext(ctx, query, identityHash).Scan(
		&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
		&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
		&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
		&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
		&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt,
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
			source_url, source_type, storage_key, file_size_bytes, metadata_json,
			metadata_status, metadata_confidence, metadata_provenance, cover_art_url, metadata_user_edited
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, COALESCE($16, 'provider'), $17, $18, $19, $20)
		RETURNING id, created_at, updated_at
	`

	err := r.db.QueryRowContext(ctx, query,
		track.IdentityHash, track.Title, track.Artist, track.Album, track.DurationMs, track.Version,
		track.MBRecordingID, track.MBReleaseID, track.MBArtistID, track.MBVerified,
		track.SourceURL, track.SourceType, track.StorageKey, track.FileSizeBytes, track.MetadataJSON,
		track.MetadataStatus, track.MetadataConfidence, track.MetadataProvenance, track.CoverArtURL, track.MetadataUserEdited,
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

// WithMetadataEnrichment sets deterministic/enrichment metadata on the track.
func WithMetadataEnrichment(status string, confidence *float64, provenance json.RawMessage, coverArtURL string) TrackOption {
	return func(t *Track) {
		t.MetadataStatus = sql.NullString{String: status, Valid: status != ""}
		if confidence != nil {
			t.MetadataConfidence = sql.NullFloat64{Float64: *confidence, Valid: true}
		}
		t.MetadataProvenance = provenance
		t.CoverArtURL = sql.NullString{String: coverArtURL, Valid: coverArtURL != ""}
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
			   metadata_json, metadata_status, metadata_confidence, metadata_provenance,
			   cover_art_url, metadata_user_edited, created_at, updated_at
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
			&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
			&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt,
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

func (r *TrackRepository) GetMaintenanceCandidates(ctx context.Context, includeMetadata, includeAnalysis bool, staleAfter time.Duration, limit int) ([]Track, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	if staleAfter <= 0 {
		staleAfter = 30 * time.Minute
	}

	query := `
		SELECT DISTINCT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
			   t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at
		FROM tracks t
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
		WHERE (
			$1::boolean
			AND t.mb_verified = FALSE
			AND t.metadata_user_edited = FALSE
			AND COALESCE(t.metadata_status, 'provider') IN ('provider', 'cleaned', 'failed', 'no_match', 'suggested')
		) OR (
			$2::boolean
			AND t.storage_key IS NOT NULL
			AND (
				ta.track_id IS NULL
				OR ta.status = 'failed'
				OR ta.status = 'stale'
				OR (ta.status IN ('pending', 'analyzing') AND ta.updated_at < NOW() - ($3::bigint * INTERVAL '1 second'))
			)
		)
		ORDER BY t.updated_at ASC, t.id ASC
		LIMIT $4
	`

	rows, err := r.db.QueryContext(ctx, query, includeMetadata, includeAnalysis, int64(staleAfter.Seconds()), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tracks []Track
	for rows.Next() {
		var t Track
		if err := rows.Scan(
			&t.ID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
			&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
			&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
			&t.MetadataJSON, &t.MetadataStatus, &t.MetadataConfidence, &t.MetadataProvenance,
			&t.CoverArtURL, &t.MetadataUserEdited, &t.CreatedAt, &t.UpdatedAt,
		); err != nil {
			return nil, err
		}
		tracks = append(tracks, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}
