package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
)

// DJPin is a user's pinned "vibe envelope" captured from a lineup block: an
// energy band plus the unioned normalized genre hints of the block's candidate
// tracks at pin time. A pin lives for at most 24 hours; readers treat expired
// pins as absent and delete them lazily.
type DJPin struct {
	UserID    uuid.UUID
	BlockID   string
	EnergyLow float64
	EnergyHi  float64
	Genres    []string
	CreatedAt time.Time
	ExpiresAt time.Time
}

// DJPinRepository stores one vibe pin per user. Writes are user-scoped upserts;
// reads ignore (and lazily delete) expired rows.
type DJPinRepository struct {
	db *DB
}

func NewDJPinRepository(db *DB) *DJPinRepository {
	return &DJPinRepository{db: db}
}

// UpsertDJPin stores the pin, replacing any existing pin for the user.
func (r *DJPinRepository) UpsertDJPin(ctx context.Context, pin DJPin) error {
	genresJSON, err := json.Marshal(pin.Genres)
	if err != nil {
		return err
	}
	if genresJSON == nil {
		genresJSON = []byte("[]")
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT INTO dj_pins (user_id, block_id, energy_low, energy_high, genres, created_at, expires_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, NOW(), $6)
		ON CONFLICT (user_id) DO UPDATE SET
			block_id = EXCLUDED.block_id,
			energy_low = EXCLUDED.energy_low,
			energy_high = EXCLUDED.energy_high,
			genres = EXCLUDED.genres,
			created_at = EXCLUDED.created_at,
			expires_at = EXCLUDED.expires_at
	`, pin.UserID, pin.BlockID, pin.EnergyLow, pin.EnergyHi, string(genresJSON), pin.ExpiresAt)
	return err
}

// GetDJPin returns the user's unexpired pin, or nil when none exists. Expired
// pins are deleted lazily on read and reported as absent.
func (r *DJPinRepository) GetDJPin(ctx context.Context, userID uuid.UUID) (*DJPin, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT user_id, block_id, energy_low, energy_high, genres, created_at, expires_at
		FROM dj_pins
		WHERE user_id = $1 AND expires_at > NOW()
	`, userID)

	var pin DJPin
	var genresJSON []byte
	if err := row.Scan(&pin.UserID, &pin.BlockID, &pin.EnergyLow, &pin.EnergyHi, &genresJSON, &pin.CreatedAt, &pin.ExpiresAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			_, _ = r.db.ExecContext(ctx, `DELETE FROM dj_pins WHERE user_id = $1 AND expires_at <= NOW()`, userID)
			return nil, nil
		}
		return nil, err
	}
	if err := json.Unmarshal(genresJSON, &pin.Genres); err != nil {
		return nil, err
	}
	return &pin, nil
}

// DeleteDJPin removes the user's pin. Deleting a missing pin is not an error.
func (r *DJPinRepository) DeleteDJPin(ctx context.Context, userID uuid.UUID) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM dj_pins WHERE user_id = $1`, userID)
	return err
}
