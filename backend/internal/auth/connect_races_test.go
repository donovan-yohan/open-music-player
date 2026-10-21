package auth

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestConnectRefreshLogoutRaceAgainstPostgres(t *testing.T) {
	database, s, user := connectAuthDB(t)
	ctx := context.Background()
	for i := 0; i < 15; i++ {
		initial, err := s.generateTokens(ctx, user)
		if err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		done := make(chan error, 1)
		refreshed := make(chan *AuthResponse, 1)
		go func() { <-start; pair, err := s.Refresh(ctx, initial.RefreshToken); refreshed <- pair; done <- err }()
		close(start)
		if err = s.Logout(ctx, user.ID); err != nil {
			t.Fatal(err)
		}
		pair, err := <-refreshed, <-done
		if err != nil && !errors.Is(err, ErrInvalidToken) {
			t.Fatal(err)
		}
		if pair != nil {
			claims, err := s.ValidateAccessToken(pair.AccessToken)
			if err != nil {
				t.Fatal(err)
			}
			if err = s.WithConnectGeneration(ctx, user.ID, claims.ConnectGeneration, func() error { return nil }); !errors.Is(err, ErrInvalidToken) {
				t.Fatalf("refresh survived logout: %v", err)
			}
			if _, err = s.Refresh(ctx, pair.RefreshToken); !errors.Is(err, ErrInvalidToken) {
				t.Fatalf("rotated refresh survived logout: %v", err)
			}
		}
		var active int
		if err = database.QueryRow(`SELECT count(*) FROM refresh_tokens WHERE user_id=$1 AND NOT revoked`, user.ID).Scan(&active); err != nil || active != 0 {
			t.Fatalf("active refresh rows=%d err=%v", active, err)
		}
	}
}

func TestConnectIssuanceLockOrderAgainstPostgres(t *testing.T) {
	database, s, user := connectAuthDB(t)
	ctx := context.Background()
	pair, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	// Freeze logout at its user-row serialization point. Refresh's preliminary
	// token lookup may see an active token but must block then revalidate it.
	tx, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`UPDATE users SET connect_auth_generation=connect_auth_generation+1 WHERE id=$1`, user.ID); err != nil {
		t.Fatal(err)
	}
	outcome := make(chan error, 1)
	go func() { _, err := s.Refresh(ctx, pair.RefreshToken); outcome <- err }()
	select {
	case err := <-outcome:
		t.Fatalf("refresh bypassed user lock: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	if _, err = tx.Exec(`UPDATE refresh_tokens SET revoked=TRUE WHERE user_id=$1`, user.ID); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if err = <-outcome; !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("refresh resurrected after logout=%v", err)
	}
}

func TestConnectLogoutRollbackAgainstPostgres(t *testing.T) {
	database, s, user := connectAuthDB(t)
	ctx := context.Background()
	pair, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = database.Exec(`CREATE FUNCTION reject_revoke() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test rejection'; END $$; CREATE TRIGGER reject_revoke BEFORE UPDATE ON refresh_tokens FOR EACH ROW EXECUTE FUNCTION reject_revoke()`); err != nil {
		t.Fatal(err)
	}
	if err = s.Logout(ctx, user.ID); err == nil {
		t.Fatal("logout reported success when revocation failed")
	}
	var generation int64
	if err = database.QueryRow(`SELECT connect_auth_generation FROM users WHERE id=$1`, user.ID).Scan(&generation); err != nil || generation != 0 {
		t.Fatalf("partial logout generation=%d err=%v", generation, err)
	}
	stored, err := db.NewTokenRepository(database).GetByHash(ctx, hashToken(pair.RefreshToken))
	if err != nil || stored.Revoked {
		t.Fatalf("partial revocation=%v %v", stored, err)
	}
}

func TestConnectIssueRollbackAgainstPostgres(t *testing.T) {
	database, s, user := connectAuthDB(t)
	ctx := context.Background()
	pair, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	repo := db.NewTokenRepository(database)
	err = repo.IssueForUser(ctx, user.ID, hashToken(pair.RefreshToken), func(user *db.User) (*db.RefreshToken, error) {
		return &db.RefreshToken{ID: uuid.New(), UserID: user.ID, TokenHash: "", ExpiresAt: time.Now()}, fmt.Errorf("sign failure")
	})
	if err == nil {
		t.Fatal("issuance unexpectedly succeeded")
	}
	if _, err = s.Refresh(ctx, pair.RefreshToken); err != nil {
		t.Fatalf("failed issuance burned old token: %v", err)
	}
}
