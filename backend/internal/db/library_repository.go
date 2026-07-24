package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
)

var ErrTrackAlreadyInLibrary = errors.New("track already in library")
var ErrTrackNotInLibrary = errors.New("track not in library")

type LibraryEntry struct {
	UserID  uuid.UUID
	TrackID int64
	AddedAt time.Time
}

type LibraryTrack struct {
	Track
	AddedAt           time.Time
	AnalysisStatus    sql.NullString
	AnalysisSummary   json.RawMessage
	AnalysisUpdatedAt sql.NullTime
	IsLiked           bool
	Genre             sql.NullString
}

type LibraryRepository struct {
	db *DB
}

func NewLibraryRepository(db *DB) *LibraryRepository {
	return &LibraryRepository{db: db}
}

// GetUserLibrary retrieves tracks in a user's library with pagination, sorting, and filtering.
// Uses full-text search for search queries and window functions for efficient count.
func (r *LibraryRepository) GetUserLibrary(ctx context.Context, userID uuid.UUID, opts LibraryQueryOptions) ([]LibraryTrack, int, error) {
	if opts.Limit <= 0 {
		opts.Limit = 20
	}
	if opts.Limit > 100 {
		opts.Limit = 100
	}

	// Build query with optional search filter
	baseCondition := "ul.user_id = $1"
	args := []interface{}{userID}
	argIndex := 2

	// Use full-text search for search queries (sanitized; see buildPrefixTSQuery).
	if opts.Search != "" {
		tsQuery := buildPrefixTSQuery(opts.Search)
		if tsQuery == "" {
			// The search term had no searchable lexemes (e.g. punctuation only). Return
			// no matches rather than silently dropping the filter and listing the whole
			// library — this mirrors the track/artist/release search paths.
			return []LibraryTrack{}, 0, nil
		}
		baseCondition += " AND to_tsvector('english', COALESCE(t.title, '') || ' ' || COALESCE(t.artist, '') || ' ' || COALESCE(t.album, '')) @@ to_tsquery('english', $" + itoa(argIndex) + ")"
		args = append(args, tsQuery)
		argIndex++
	}

	if opts.MBVerified != nil {
		baseCondition += " AND t.mb_verified = $" + itoa(argIndex)
		args = append(args, *opts.MBVerified)
		argIndex++
	}

	// Genre filter. The literal "Unknown" is the display bucket for tracks with no
	// stored genre, so it matches rows where genre IS NULL OR genre = ''. Any other
	// value is an exact match against t.genre.
	if opts.Genre != "" {
		if opts.Genre == "Unknown" {
			baseCondition += " AND (t.genre IS NULL OR t.genre = '')"
		} else {
			baseCondition += " AND t.genre = $" + itoa(argIndex)
			args = append(args, opts.Genre)
			argIndex++
		}
	}

	// Exact-match artist/album filters back the local artist/album listing pages.
	if opts.Artist != "" {
		baseCondition += " AND t.artist = $" + itoa(argIndex)
		args = append(args, opts.Artist)
		argIndex++
	}
	if opts.Album != "" {
		baseCondition += " AND t.album = $" + itoa(argIndex)
		args = append(args, opts.Album)
		argIndex++
	}

	// Liked-only filter. This narrows the library listing to liked tracks; because
	// GetUserLibrary is scoped to user_library, a liked track that is not in the
	// library is intentionally not returned here. The standalone "Liked Songs"
	// collection (every favorite regardless of membership) is a separate endpoint
	// (roadmap C11b). Ordering still follows the library sort (added_at/title/artist);
	// like-time ordering via idx_track_favorites_user_created lands with that endpoint.
	if opts.Liked {
		baseCondition += " AND EXISTS (SELECT 1 FROM track_favorites tf WHERE tf.user_id = ul.user_id AND tf.track_id = t.id)"
	}

	// Determine sort order
	orderBy := "ul.added_at DESC" // default
	switch opts.SortBy {
	case "added_at":
		if opts.SortOrder == "asc" {
			orderBy = "ul.added_at ASC"
		} else {
			orderBy = "ul.added_at DESC"
		}
	case "title":
		if opts.SortOrder == "desc" {
			orderBy = "t.title DESC"
		} else {
			orderBy = "t.title ASC"
		}
	case "artist":
		if opts.SortOrder == "desc" {
			orderBy = "t.artist DESC NULLS LAST"
		} else {
			orderBy = "t.artist ASC NULLS LAST"
		}
	case "duration":
		if opts.SortOrder == "desc" {
			orderBy = "t.duration_ms DESC NULLS LAST"
		} else {
			orderBy = "t.duration_ms ASC NULLS LAST"
		}
	}

	// Single query with window function for total count (eliminates separate COUNT query)
	selectQuery := `
		SELECT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.codec, t.bitrate_kbps, t.sample_rate_hz, t.channels, t.content_type,
			   t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
			   t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at, ul.added_at,
			   ta.status, COALESCE(` + analysisCompactSummaryExpression + `, '{}'::jsonb) AS analysis_summary,
			   COALESCE(` + analysisCompactOverridesExpression + `, '{}'::jsonb) AS analysis_overrides,
			   ta.updated_at AS analysis_updated_at,
			   EXISTS(SELECT 1 FROM track_favorites tf WHERE tf.user_id = ul.user_id AND tf.track_id = t.id) AS is_liked,
			   t.genre,
			   COUNT(*) OVER() as total_count
		FROM user_library ul
		JOIN tracks t ON ul.track_id = t.id
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
		WHERE ` + baseCondition + `
		ORDER BY ` + orderBy + `
		LIMIT $` + itoa(argIndex) + ` OFFSET $` + itoa(argIndex+1)

	args = append(args, opts.Limit, opts.Offset)

	rows, err := r.db.QueryContext(ctx, selectQuery, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var tracks []LibraryTrack
	var total int
	for rows.Next() {
		var lt LibraryTrack
		var analysisOverrides json.RawMessage
		err := rows.Scan(
			&lt.ID, &lt.IdentityHash, &lt.Title, &lt.Artist, &lt.Album, &lt.DurationMs, &lt.Version,
			&lt.MBRecordingID, &lt.MBReleaseID, &lt.MBArtistID, &lt.MBVerified,
			&lt.SourceURL, &lt.SourceType, &lt.StorageKey, &lt.FileSizeBytes,
			&lt.Codec, &lt.BitrateKbps, &lt.SampleRateHz, &lt.Channels, &lt.ContentType,
			&lt.MetadataJSON, &lt.MetadataStatus, &lt.MetadataConfidence, &lt.MetadataProvenance,
			&lt.CoverArtURL, &lt.MetadataUserEdited, &lt.CreatedAt, &lt.UpdatedAt, &lt.AddedAt,
			&lt.AnalysisStatus, &lt.AnalysisSummary, &analysisOverrides, &lt.AnalysisUpdatedAt, &lt.IsLiked, &lt.Genre, &total,
		)
		if err != nil {
			return nil, 0, err
		}
		lt.AnalysisSummary, _ = projectCompactAnalysis(lt.AnalysisSummary, analysisOverrides)
		tracks = append(tracks, lt)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return tracks, total, nil
}

// AddTrackToLibrary adds a track to a user's library.
func (r *LibraryRepository) AddTrackToLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (*LibraryEntry, error) {
	query := `
		INSERT INTO user_library (user_id, track_id, added_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (user_id, track_id) DO NOTHING
		RETURNING user_id, track_id, added_at
	`

	var entry LibraryEntry
	err := r.db.QueryRowContext(ctx, query, userID, trackID).Scan(&entry.UserID, &entry.TrackID, &entry.AddedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// ON CONFLICT DO NOTHING returns no rows if already exists
			return nil, ErrTrackAlreadyInLibrary
		}
		return nil, err
	}

	return &entry, nil
}

// RemoveTrackFromLibrary removes a track from a user's library.
func (r *LibraryRepository) RemoveTrackFromLibrary(ctx context.Context, userID uuid.UUID, trackID int64) error {
	query := `
		DELETE FROM user_library
		WHERE user_id = $1 AND track_id = $2
	`

	result, err := r.db.ExecContext(ctx, query, userID, trackID)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return ErrTrackNotInLibrary
	}

	return nil
}

// IsTrackInLibrary checks if a track is in a user's library.
func (r *LibraryRepository) IsTrackInLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (bool, error) {
	query := `
		SELECT EXISTS(
			SELECT 1 FROM user_library
			WHERE user_id = $1 AND track_id = $2
		)
	`

	var exists bool
	err := r.db.QueryRowContext(ctx, query, userID, trackID).Scan(&exists)
	if err != nil {
		return false, err
	}

	return exists, nil
}

// AddFavorite marks a track as liked ("Liked Songs") for a user. Idempotent:
// liking an already-liked track is a no-op success. Favorites are membership +
// timestamp only and do NOT change user_library membership.
func (r *LibraryRepository) AddFavorite(ctx context.Context, userID uuid.UUID, trackID int64) error {
	query := `
		INSERT INTO track_favorites (user_id, track_id, created_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (user_id, track_id) DO NOTHING
	`
	_, err := r.db.ExecContext(ctx, query, userID, trackID)
	return err
}

// RemoveFavorite unlikes a track for a user. Idempotent: unliking a track that
// is not liked is a no-op success. Does NOT change user_library membership.
func (r *LibraryRepository) RemoveFavorite(ctx context.Context, userID uuid.UUID, trackID int64) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM track_favorites WHERE user_id = $1 AND track_id = $2`, userID, trackID)
	return err
}

// IsFavorite reports whether a track is liked by a user.
func (r *LibraryRepository) IsFavorite(ctx context.Context, userID uuid.UUID, trackID int64) (bool, error) {
	var exists bool
	err := r.db.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM track_favorites WHERE user_id = $1 AND track_id = $2)`,
		userID, trackID).Scan(&exists)
	return exists, err
}

// LibraryQueryOptions contains options for querying the user library.
type LibraryQueryOptions struct {
	Limit      int
	Offset     int
	SortBy     string // "added_at", "title", "artist", "duration"
	SortOrder  string // "asc", "desc"
	Search     string // Search query for title/artist/album
	MBVerified *bool  // Filter by MusicBrainz verification status
	Liked      bool   // When true, return only liked tracks
	Genre      string // Exact genre match; "Unknown" matches NULL/empty genre
	Artist     string // Exact artist match (local artist listing)
	Album      string // Exact album match (local album listing)
}

// itoa converts an integer to a string (simple implementation to avoid importing strconv)
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var result []byte
	for n > 0 {
		result = append([]byte{byte('0' + n%10)}, result...)
		n /= 10
	}
	return string(result)
}
