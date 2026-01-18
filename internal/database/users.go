package database

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/openmusicplayer/openmusicplayer/internal/models"
)

var ErrUserNotFound = errors.New("user not found")
var ErrDuplicateEmail = errors.New("email already exists")

func (db *DB) CreateUser(ctx context.Context, email, passwordHash string) (*models.User, error) {
	user := &models.User{
		Email:        email,
		PasswordHash: passwordHash,
	}

	query := `
		INSERT INTO users (email, password_hash, created_at, updated_at)
		VALUES ($1, $2, NOW(), NOW())
		RETURNING id, created_at, updated_at
	`

	err := db.QueryRowContext(ctx, query, email, passwordHash).Scan(
		&user.ID, &user.CreatedAt, &user.UpdatedAt,
	)
	if err != nil {
		if err.Error() == `pq: duplicate key value violates unique constraint "users_email_key"` {
			return nil, ErrDuplicateEmail
		}
		return nil, err
	}

	return user, nil
}

func (db *DB) GetUserByEmail(ctx context.Context, email string) (*models.User, error) {
	user := &models.User{}

	query := `
		SELECT id, email, password_hash, created_at, updated_at
		FROM users
		WHERE email = $1
	`

	err := db.QueryRowContext(ctx, query, email).Scan(
		&user.ID, &user.Email, &user.PasswordHash, &user.CreatedAt, &user.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrUserNotFound
		}
		return nil, err
	}

	return user, nil
}

func (db *DB) GetUserByID(ctx context.Context, id int64) (*models.User, error) {
	user := &models.User{}

	query := `
		SELECT id, email, password_hash, created_at, updated_at
		FROM users
		WHERE id = $1
	`

	err := db.QueryRowContext(ctx, query, id).Scan(
		&user.ID, &user.Email, &user.PasswordHash, &user.CreatedAt, &user.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrUserNotFound
		}
		return nil, err
	}

	return user, nil
}

func (db *DB) StoreRefreshToken(ctx context.Context, userID int64, token string, expiresAt time.Time) error {
	query := `
		INSERT INTO refresh_tokens (user_id, token, expires_at, created_at)
		VALUES ($1, $2, $3, NOW())
	`

	_, err := db.ExecContext(ctx, query, userID, token, expiresAt)
	return err
}

func (db *DB) GetRefreshToken(ctx context.Context, token string) (*models.RefreshToken, error) {
	rt := &models.RefreshToken{}

	query := `
		SELECT id, user_id, token, expires_at, created_at
		FROM refresh_tokens
		WHERE token = $1
	`

	err := db.QueryRowContext(ctx, query, token).Scan(
		&rt.ID, &rt.UserID, &rt.Token, &rt.ExpiresAt, &rt.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}

	return rt, nil
}

func (db *DB) DeleteRefreshToken(ctx context.Context, token string) error {
	query := `DELETE FROM refresh_tokens WHERE token = $1`
	_, err := db.ExecContext(ctx, query, token)
	return err
}

func (db *DB) DeleteUserRefreshTokens(ctx context.Context, userID int64) error {
	query := `DELETE FROM refresh_tokens WHERE user_id = $1`
	_, err := db.ExecContext(ctx, query, userID)
	return err
}
