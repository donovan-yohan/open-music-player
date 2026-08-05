package db

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// TrackMetadataFieldMaxLen mirrors the VARCHAR(500) columns on tracks and
// track_metadata_overrides. Callers validate against it before writing so an
// oversized field returns a 400 instead of a driver error.
const TrackMetadataFieldMaxLen = 500

// TrackMetadataOverride is one user's manual correction of a global track row.
//
// Tracks are shared across users, so corrections live here instead of mutating
// tracks.title/artist/album. A NULL field means "not overridden" and the canonical
// track value is used. These values are DISPLAY-LAYER ONLY: they must never be read
// by the MusicBrainz matcher, the identity hash, or any ingestion/enrichment path.
type TrackMetadataOverride struct {
	UserID    uuid.UUID
	TrackID   int64
	Title     sql.NullString
	Artist    sql.NullString
	Album     sql.NullString
	CreatedAt time.Time
	UpdatedAt time.Time
}

// TrackMetadataOverrideInput is the desired override state for one (user, track).
// It is a full replacement, not a merge: a nil field clears that field's override.
// All three nil deletes the row.
type TrackMetadataOverrideInput struct {
	Title  *string
	Artist *string
	Album  *string
}

// IsEmpty reports whether the input would leave no override at all.
func (in TrackMetadataOverrideInput) IsEmpty() bool {
	return in.Title == nil && in.Artist == nil && in.Album == nil
}

// NormalizeOverrideField trims a caller-supplied override value. An absent value,
// or one that is blank after trimming, normalizes to nil ("not overridden") so that
// clearing a field and sending whitespace behave identically.
func NormalizeOverrideField(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

// Normalized returns the input with every field trimmed and blanks collapsed to nil.
func (in TrackMetadataOverrideInput) Normalized() TrackMetadataOverrideInput {
	return TrackMetadataOverrideInput{
		Title:  NormalizeOverrideField(in.Title),
		Artist: NormalizeOverrideField(in.Artist),
		Album:  NormalizeOverrideField(in.Album),
	}
}

// TooLongField returns the name of the first field exceeding the column width, or
// "" when every field fits.
func (in TrackMetadataOverrideInput) TooLongField() string {
	for _, f := range []struct {
		name  string
		value *string
	}{
		{"title", in.Title},
		{"artist", in.Artist},
		{"album", in.Album},
	} {
		if f.value != nil && len([]rune(*f.value)) > TrackMetadataFieldMaxLen {
			return f.name
		}
	}
	return ""
}

type TrackMetadataOverrideRepository struct {
	db *DB
}

func NewTrackMetadataOverrideRepository(db *DB) *TrackMetadataOverrideRepository {
	return &TrackMetadataOverrideRepository{db: db}
}

// Set upserts the caller's override for one track. Input is a full replacement:
// nil fields clear that field, and an entirely empty input deletes the row and
// returns (nil, nil) so the caller can report "back to canonical".
func (r *TrackMetadataOverrideRepository) Set(ctx context.Context, userID uuid.UUID, trackID int64, input TrackMetadataOverrideInput) (*TrackMetadataOverride, error) {
	normalized := input.Normalized()
	if normalized.IsEmpty() {
		if err := r.Delete(ctx, userID, trackID); err != nil {
			return nil, err
		}
		return nil, nil
	}

	const query = `
		INSERT INTO track_metadata_overrides (user_id, track_id, title, artist, album, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
		ON CONFLICT (user_id, track_id) DO UPDATE
		SET title = EXCLUDED.title,
			artist = EXCLUDED.artist,
			album = EXCLUDED.album,
			updated_at = NOW()
		RETURNING user_id, track_id, title, artist, album, created_at, updated_at`

	var override TrackMetadataOverride
	err := r.db.QueryRowContext(ctx, query,
		userID, trackID,
		overrideFieldArg(normalized.Title),
		overrideFieldArg(normalized.Artist),
		overrideFieldArg(normalized.Album),
	).Scan(
		&override.UserID, &override.TrackID,
		&override.Title, &override.Artist, &override.Album,
		&override.CreatedAt, &override.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &override, nil
}

// Delete removes the caller's override for a track. Deleting a missing row is a
// no-op so "reset to original" is idempotent.
func (r *TrackMetadataOverrideRepository) Delete(ctx context.Context, userID uuid.UUID, trackID int64) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM track_metadata_overrides WHERE user_id = $1 AND track_id = $2`,
		userID, trackID)
	return err
}

// Get returns the caller's override for one track, or (nil, nil) when unset.
func (r *TrackMetadataOverrideRepository) Get(ctx context.Context, userID uuid.UUID, trackID int64) (*TrackMetadataOverride, error) {
	var override TrackMetadataOverride
	err := r.db.QueryRowContext(ctx, `
		SELECT user_id, track_id, title, artist, album, created_at, updated_at
		FROM track_metadata_overrides
		WHERE user_id = $1 AND track_id = $2`, userID, trackID).Scan(
		&override.UserID, &override.TrackID,
		&override.Title, &override.Artist, &override.Album,
		&override.CreatedAt, &override.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &override, nil
}

// GetForTracks batches the override lookup for a page of tracks. The returned map
// only contains track IDs that actually have an override.
func (r *TrackMetadataOverrideRepository) GetForTracks(ctx context.Context, userID uuid.UUID, trackIDs []int64) (map[int64]TrackMetadataOverride, error) {
	result := make(map[int64]TrackMetadataOverride)
	unique := positiveUniqueTrackIDs(trackIDs)
	if len(unique) == 0 {
		return result, nil
	}

	rows, err := r.db.QueryContext(ctx, `
		SELECT user_id, track_id, title, artist, album, created_at, updated_at
		FROM track_metadata_overrides
		WHERE user_id = $1 AND track_id = ANY($2::bigint[])`, userID, pq.Array(unique))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var override TrackMetadataOverride
		if err := rows.Scan(
			&override.UserID, &override.TrackID,
			&override.Title, &override.Artist, &override.Album,
			&override.CreatedAt, &override.UpdatedAt,
		); err != nil {
			return nil, err
		}
		result[override.TrackID] = override
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

// ApplyToTracks overlays the caller's overrides onto already-loaded tracks in place.
//
// This is the display-layer merge used by handlers that read tracks through the
// shared (user-agnostic) repository queries. Repository reads stay canonical on
// purpose so matcher/ingestion callers never see edited values.
func (r *TrackMetadataOverrideRepository) ApplyToTracks(ctx context.Context, userID uuid.UUID, tracks []*Track) error {
	if len(tracks) == 0 {
		return nil
	}
	ids := make([]int64, 0, len(tracks))
	for _, t := range tracks {
		if t != nil {
			ids = append(ids, t.ID)
		}
	}
	overrides, err := r.GetForTracks(ctx, userID, ids)
	if err != nil {
		return err
	}
	if len(overrides) == 0 {
		return nil
	}
	for _, t := range tracks {
		if t == nil {
			continue
		}
		if override, ok := overrides[t.ID]; ok {
			ApplyMetadataOverride(t, &override)
		}
	}
	return nil
}

// ApplyMetadataOverride overlays one override on one track and marks the track as
// user-edited for the caller. A nil override leaves the track untouched.
func ApplyMetadataOverride(track *Track, override *TrackMetadataOverride) {
	if track == nil || override == nil {
		return
	}
	if override.Title.Valid {
		track.Title = override.Title.String
	}
	if override.Artist.Valid {
		track.Artist = override.Artist
	}
	if override.Album.Valid {
		track.Album = override.Album
	}
	track.HasMetadataOverride = true
}

func overrideFieldArg(value *string) interface{} {
	if value == nil {
		return nil
	}
	return *value
}

func positiveUniqueTrackIDs(ids []int64) []int64 {
	unique := make([]int64, 0, len(ids))
	for _, id := range dedupeInt64(ids) {
		if id > 0 {
			unique = append(unique, id)
		}
	}
	return unique
}
