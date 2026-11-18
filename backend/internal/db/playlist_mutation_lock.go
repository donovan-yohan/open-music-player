package db

import (
	"context"
	"database/sql"
	"errors"
)

// All ordinary membership writers share snapshot acceptance's playlist lock.
func lockPlaylistMutation(ctx context.Context, tx *sql.Tx, id int64) error {
	var found int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM playlists WHERE id=$1 FOR UPDATE`, id).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrPlaylistNotFound
	}
	return err
}
