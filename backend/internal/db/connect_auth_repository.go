package db

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// WithConnectGeneration holds a shared user lock through a feature operation.
// Logout/issuance use the exclusive same lock. No Redis write can race past logout.
func (r *UserRepository) WithConnectGeneration(ctx context.Context, id uuid.UUID, generation int64, operation func() error) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var current int64
	if err = tx.QueryRowContext(ctx, `SELECT connect_auth_generation FROM users WHERE id=$1 FOR SHARE`, id).Scan(&current); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrUserNotFound
		}
		return err
	}
	if generation < 0 || current != generation {
		return ErrTokenRevoked
	}
	if err = operation(); err != nil {
		return err
	}
	return tx.Commit()
}

// IssueForUser is the single issuance boundary: user first, then optional old
// refresh token. Revalidation and rotation cannot mint post-logout authority.
func (r *TokenRepository) IssueForUser(ctx context.Context, id uuid.UUID, oldHash string, build func(*User) (*RefreshToken, error)) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	user := &User{}
	err = tx.QueryRowContext(ctx, `SELECT id,email,username,password_hash,created_at,updated_at,connect_auth_generation FROM users WHERE id=$1 FOR UPDATE`, id).Scan(&user.ID, &user.Email, &user.Username, &user.PasswordHash, &user.CreatedAt, &user.UpdatedAt, &user.ConnectAuthGeneration)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrUserNotFound
		}
		return err
	}
	if oldHash != "" {
		var tokenID uuid.UUID
		var revoked bool
		var expires time.Time
		err = tx.QueryRowContext(ctx, `SELECT id,revoked,expires_at FROM refresh_tokens WHERE user_id=$1 AND token_hash=$2 FOR UPDATE`, id, oldHash).Scan(&tokenID, &revoked, &expires)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrTokenNotFound
		}
		if err != nil {
			return err
		}
		if revoked {
			return ErrTokenRevoked
		}
		if !time.Now().Before(expires) {
			return ErrTokenExpired
		}
		if _, err = tx.ExecContext(ctx, `UPDATE refresh_tokens SET revoked=TRUE WHERE id=$1`, tokenID); err != nil {
			return err
		}
	}
	token, err := build(user)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO refresh_tokens(id,user_id,token_hash,expires_at,created_at,revoked) VALUES($1,$2,$3,$4,$5,FALSE)`, token.ID, user.ID, token.TokenHash, token.ExpiresAt, token.CreatedAt); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *TokenRepository) RevokeAllAndAdvanceConnectGeneration(ctx context.Context, id uuid.UUID) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE users SET connect_auth_generation=connect_auth_generation+1 WHERE id=$1`, id)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrUserNotFound
	}
	if _, err = tx.ExecContext(ctx, `UPDATE refresh_tokens SET revoked=TRUE WHERE user_id=$1 AND revoked=FALSE`, id); err != nil {
		return err
	}
	return tx.Commit()
}
