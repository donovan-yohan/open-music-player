package db

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

var ErrPlaylistNotFound = errors.New("playlist not found")
var ErrPlaylistNotOwned = errors.New("playlist not owned by user")
var ErrTrackNotInPlaylist = errors.New("track not in playlist")
var ErrTrackAlreadyInPlaylist = errors.New("track already in playlist")

type Playlist struct {
	ID          int64
	UserID      uuid.UUID
	Name        string
	Description sql.NullString
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type PlaylistTrack struct {
	PlaylistID int64
	TrackID    int64
	Position   int
	AddedAt    time.Time
}

type PlaylistWithTracks struct {
	Playlist
	Tracks     []Track
	TrackCount int
	DurationMs int64
}

type PlaylistRepository struct {
	db *DB
}

func NewPlaylistRepository(db *DB) *PlaylistRepository {
	return &PlaylistRepository{db: db}
}

// Create inserts a new playlist into the database.
func (r *PlaylistRepository) Create(ctx context.Context, playlist *Playlist) error {
	query := `
		INSERT INTO playlists (user_id, name, description)
		VALUES ($1, $2, $3)
		RETURNING id, created_at, updated_at
	`

	err := r.db.QueryRowContext(ctx, query,
		playlist.UserID, playlist.Name, playlist.Description,
	).Scan(&playlist.ID, &playlist.CreatedAt, &playlist.UpdatedAt)

	return err
}

// GetByID retrieves a playlist by its ID.
func (r *PlaylistRepository) GetByID(ctx context.Context, id int64) (*Playlist, error) {
	query := `
		SELECT id, user_id, name, description, created_at, updated_at
		FROM playlists
		WHERE id = $1
	`

	var p Playlist
	err := r.db.QueryRowContext(ctx, query, id).Scan(
		&p.ID, &p.UserID, &p.Name, &p.Description, &p.CreatedAt, &p.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrPlaylistNotFound
		}
		return nil, err
	}

	return &p, nil
}

// GetByIDWithTracks retrieves a playlist with all its tracks in a single query.
func (r *PlaylistRepository) GetByIDWithTracks(ctx context.Context, id int64) (*PlaylistWithTracks, error) {
	// Single query to get playlist info and all tracks
	query := `
		SELECT p.id, p.user_id, p.name, p.description, p.created_at, p.updated_at,
			   t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
			   t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
			   t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
			   t.metadata_json, t.created_at, t.updated_at
		FROM playlists p
		LEFT JOIN playlist_tracks pt ON p.id = pt.playlist_id
		LEFT JOIN tracks t ON pt.track_id = t.id
		WHERE p.id = $1
		ORDER BY pt.position ASC
	`

	rows, err := r.db.QueryContext(ctx, query, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result *PlaylistWithTracks
	var tracks []Track
	var totalDuration int64

	for rows.Next() {
		var p Playlist
		var t Track
		var trackID sql.NullInt64

		err := rows.Scan(
			&p.ID, &p.UserID, &p.Name, &p.Description, &p.CreatedAt, &p.UpdatedAt,
			&trackID, &t.IdentityHash, &t.Title, &t.Artist, &t.Album, &t.DurationMs, &t.Version,
			&t.MBRecordingID, &t.MBReleaseID, &t.MBArtistID, &t.MBVerified,
			&t.SourceURL, &t.SourceType, &t.StorageKey, &t.FileSizeBytes,
			&t.MetadataJSON, &t.CreatedAt, &t.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}

		// Initialize playlist on first row
		if result == nil {
			result = &PlaylistWithTracks{Playlist: p}
		}

		// Add track if present (LEFT JOIN may return NULL for empty playlists)
		if trackID.Valid {
			t.ID = trackID.Int64
			tracks = append(tracks, t)
			if t.DurationMs.Valid {
				totalDuration += int64(t.DurationMs.Int32)
			}
		}
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	if result == nil {
		return nil, ErrPlaylistNotFound
	}

	result.Tracks = tracks
	result.TrackCount = len(tracks)
	result.DurationMs = totalDuration

	return result, nil
}

// GetByUserID retrieves all playlists for a user with a single optimized query.
func (r *PlaylistRepository) GetByUserID(ctx context.Context, userID uuid.UUID, limit, offset int) ([]PlaylistWithTracks, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}

	// Single query with window function for total count (eliminates separate COUNT query)
	selectQuery := `
		SELECT p.id, p.user_id, p.name, p.description, p.created_at, p.updated_at,
			   COALESCE(COUNT(pt.track_id), 0) as track_count,
			   COALESCE(SUM(t.duration_ms), 0) as total_duration,
			   COUNT(*) OVER() as total_playlists
		FROM playlists p
		LEFT JOIN playlist_tracks pt ON p.id = pt.playlist_id
		LEFT JOIN tracks t ON pt.track_id = t.id
		WHERE p.user_id = $1
		GROUP BY p.id
		ORDER BY p.updated_at DESC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, selectQuery, userID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var playlists []PlaylistWithTracks
	var total int
	for rows.Next() {
		var p PlaylistWithTracks
		err := rows.Scan(
			&p.ID, &p.UserID, &p.Name, &p.Description, &p.CreatedAt, &p.UpdatedAt,
			&p.TrackCount, &p.DurationMs, &total,
		)
		if err != nil {
			return nil, 0, err
		}
		playlists = append(playlists, p)
	}

	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return playlists, total, nil
}

// Update updates a playlist's name and description.
func (r *PlaylistRepository) Update(ctx context.Context, playlist *Playlist) error {
	query := `
		UPDATE playlists
		SET name = $1, description = $2, updated_at = NOW()
		WHERE id = $3
		RETURNING updated_at
	`

	err := r.db.QueryRowContext(ctx, query,
		playlist.Name, playlist.Description, playlist.ID,
	).Scan(&playlist.UpdatedAt)

	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrPlaylistNotFound
		}
		return err
	}

	return nil
}

// Delete removes a playlist and all its track associations.
func (r *PlaylistRepository) Delete(ctx context.Context, id int64) error {
	query := `DELETE FROM playlists WHERE id = $1`

	result, err := r.db.ExecContext(ctx, query, id)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return ErrPlaylistNotFound
	}

	return nil
}

// AddTrack adds a track to a playlist at the end.
func (r *PlaylistRepository) AddTrack(ctx context.Context, playlistID, trackID int64) error {
	// Get the next position
	var maxPosition sql.NullInt32
	posQuery := `SELECT MAX(position) FROM playlist_tracks WHERE playlist_id = $1`
	if err := r.db.QueryRowContext(ctx, posQuery, playlistID).Scan(&maxPosition); err != nil {
		return err
	}

	nextPosition := 0
	if maxPosition.Valid {
		nextPosition = int(maxPosition.Int32) + 1
	}

	query := `
		INSERT INTO playlist_tracks (playlist_id, track_id, position)
		VALUES ($1, $2, $3)
	`

	_, err := r.db.ExecContext(ctx, query, playlistID, trackID, nextPosition)
	if err != nil {
		if isUniqueViolation(err) {
			return ErrTrackAlreadyInPlaylist
		}
		return err
	}

	// Update playlist's updated_at
	_, err = r.db.ExecContext(ctx, `UPDATE playlists SET updated_at = NOW() WHERE id = $1`, playlistID)
	return err
}

// AddTracks adds multiple tracks to a playlist.
func (r *PlaylistRepository) AddTracks(ctx context.Context, playlistID int64, trackIDs []int64) error {
	if len(trackIDs) == 0 {
		return nil
	}

	// Get the next position
	var maxPosition sql.NullInt32
	posQuery := `SELECT MAX(position) FROM playlist_tracks WHERE playlist_id = $1`
	if err := r.db.QueryRowContext(ctx, posQuery, playlistID).Scan(&maxPosition); err != nil {
		return err
	}

	nextPosition := 0
	if maxPosition.Valid {
		nextPosition = int(maxPosition.Int32) + 1
	}

	// Insert all tracks
	for i, trackID := range trackIDs {
		query := `
			INSERT INTO playlist_tracks (playlist_id, track_id, position)
			VALUES ($1, $2, $3)
			ON CONFLICT (playlist_id, track_id) DO NOTHING
		`
		_, err := r.db.ExecContext(ctx, query, playlistID, trackID, nextPosition+i)
		if err != nil {
			return err
		}
	}

	// Update playlist's updated_at
	_, err := r.db.ExecContext(ctx, `UPDATE playlists SET updated_at = NOW() WHERE id = $1`, playlistID)
	return err
}

// RemoveTrack removes a track from a playlist and reorders remaining tracks.
func (r *PlaylistRepository) RemoveTrack(ctx context.Context, playlistID, trackID int64) error {
	// Get the position of the track being removed
	var position int
	posQuery := `SELECT position FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`
	err := r.db.QueryRowContext(ctx, posQuery, playlistID, trackID).Scan(&position)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrTrackNotInPlaylist
		}
		return err
	}

	// Delete the track
	deleteQuery := `DELETE FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`
	_, err = r.db.ExecContext(ctx, deleteQuery, playlistID, trackID)
	if err != nil {
		return err
	}

	// Reorder tracks after the removed one
	reorderQuery := `
		UPDATE playlist_tracks
		SET position = position - 1
		WHERE playlist_id = $1 AND position > $2
	`
	_, err = r.db.ExecContext(ctx, reorderQuery, playlistID, position)
	if err != nil {
		return err
	}

	// Update playlist's updated_at
	_, err = r.db.ExecContext(ctx, `UPDATE playlists SET updated_at = NOW() WHERE id = $1`, playlistID)
	return err
}

// ReorderTrack moves a track to a new position within the playlist.
func (r *PlaylistRepository) ReorderTrack(ctx context.Context, playlistID, trackID int64, newPosition int) error {
	// Get the current position
	var currentPosition int
	posQuery := `SELECT position FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`
	err := r.db.QueryRowContext(ctx, posQuery, playlistID, trackID).Scan(&currentPosition)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrTrackNotInPlaylist
		}
		return err
	}

	if currentPosition == newPosition {
		return nil // No change needed
	}

	// Get the max position to validate newPosition
	var maxPosition int
	maxQuery := `SELECT COALESCE(MAX(position), 0) FROM playlist_tracks WHERE playlist_id = $1`
	if err := r.db.QueryRowContext(ctx, maxQuery, playlistID).Scan(&maxPosition); err != nil {
		return err
	}

	if newPosition < 0 {
		newPosition = 0
	}
	if newPosition > maxPosition {
		newPosition = maxPosition
	}

	// Shift other tracks
	if newPosition < currentPosition {
		// Moving up: shift tracks between newPosition and currentPosition down
		shiftQuery := `
			UPDATE playlist_tracks
			SET position = position + 1
			WHERE playlist_id = $1 AND position >= $2 AND position < $3
		`
		_, err = r.db.ExecContext(ctx, shiftQuery, playlistID, newPosition, currentPosition)
	} else {
		// Moving down: shift tracks between currentPosition and newPosition up
		shiftQuery := `
			UPDATE playlist_tracks
			SET position = position - 1
			WHERE playlist_id = $1 AND position > $2 AND position <= $3
		`
		_, err = r.db.ExecContext(ctx, shiftQuery, playlistID, currentPosition, newPosition)
	}
	if err != nil {
		return err
	}

	// Update the track's position
	updateQuery := `UPDATE playlist_tracks SET position = $1 WHERE playlist_id = $2 AND track_id = $3`
	_, err = r.db.ExecContext(ctx, updateQuery, newPosition, playlistID, trackID)
	if err != nil {
		return err
	}

	// Update playlist's updated_at
	_, err = r.db.ExecContext(ctx, `UPDATE playlists SET updated_at = NOW() WHERE id = $1`, playlistID)
	return err
}
