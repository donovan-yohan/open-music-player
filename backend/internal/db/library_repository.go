package db

import (
	"context"
	"database/sql"
	"errors"
	"strings"
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
	AddedAt time.Time
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

	// Use full-text search for search queries
	if opts.Search != "" {
		tsQuery := strings.Join(strings.Fields(opts.Search), " & ")
		if tsQuery != "" {
			tsQuery = tsQuery + ":*"
			baseCondition += " AND to_tsvector('english', COALESCE(t.title, '') || ' ' || COALESCE(t.artist, '') || ' ' || COALESCE(t.album, '')) @@ to_tsquery('english', $" + itoa(argIndex) + ")"
			args = append(args, tsQuery)
			argIndex++
		}
	}

	if opts.MBVerified != nil {
		baseCondition += " AND t.mb_verified = $" + itoa(argIndex)
		args = append(args, *opts.MBVerified)
		argIndex++
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
	}

	// Single query with window function for total count (eliminates separate COUNT query)
	selectQuery := `
		SELECT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.created_at, t.updated_at, ul.added_at,
			   COUNT(*) OVER() as total_count
		FROM user_library ul
		JOIN tracks t ON ul.track_id = t.id
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
		err := rows.Scan(
			&lt.ID, &lt.IdentityHash, &lt.Title, &lt.Artist, &lt.Album, &lt.DurationMs, &lt.Version,
			&lt.MBRecordingID, &lt.MBReleaseID, &lt.MBArtistID, &lt.MBVerified,
			&lt.SourceURL, &lt.SourceType, &lt.StorageKey, &lt.FileSizeBytes,
			&lt.MetadataJSON, &lt.CreatedAt, &lt.UpdatedAt, &lt.AddedAt, &total,
		)
		if err != nil {
			return nil, 0, err
		}
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

// LibraryQueryOptions contains options for querying the user library.
type LibraryQueryOptions struct {
	Limit      int
	Offset     int
	SortBy     string // "added_at", "title", "artist"
	SortOrder  string // "asc", "desc"
	Search     string // Search query for title/artist/album
	MBVerified *bool  // Filter by MusicBrainz verification status
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
