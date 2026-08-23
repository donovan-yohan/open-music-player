package db

import (
	"context"
	"testing"
	"time"
)

func newDJPinTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres DJ-pin integration tests")
	}
	database, ctx := newPlayEventTestDB(t)
	if _, err := database.Exec(`TRUNCATE TABLE dj_pins`); err != nil {
		t.Fatalf("truncate dj_pins: %v", err)
	}
	return database, ctx
}

func TestDJPinUpsertGetDeleteLifecycle(t *testing.T) {
	database, ctx := newDJPinTestDB(t)
	repo := NewDJPinRepository(database)
	user := seedPlayUser(t, database, "dj-pin-lifecycle@example.test")

	pin := DJPin{
		UserID:    user,
		BlockID:   "on-repeat",
		EnergyLow: 0.4,
		EnergyHi:  0.6,
		Genres:    []string{"house", "techno"},
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	if err := repo.UpsertDJPin(ctx, pin); err != nil {
		t.Fatalf("upsert pin: %v", err)
	}

	got, err := repo.GetDJPin(ctx, user)
	if err != nil || got == nil {
		t.Fatalf("get pin = %#v, %v; want stored pin", got, err)
	}
	if got.BlockID != pin.BlockID || got.EnergyLow != pin.EnergyLow || got.EnergyHi != pin.EnergyHi {
		t.Fatalf("stored pin = %#v, want %#v", got, pin)
	}
	if len(got.Genres) != 2 || got.Genres[0] != "house" || got.Genres[1] != "techno" {
		t.Fatalf("stored genres = %v, want [house techno]", got.Genres)
	}

	// Replace: one row per user, newest wins.
	replacement := DJPin{
		UserID:    user,
		BlockID:   "flashback",
		EnergyLow: 0.1,
		EnergyHi:  0.3,
		Genres:    nil,
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	if err := repo.UpsertDJPin(ctx, replacement); err != nil {
		t.Fatalf("replace pin: %v", err)
	}
	got, err = repo.GetDJPin(ctx, user)
	if err != nil || got == nil || got.BlockID != "flashback" {
		t.Fatalf("pin after replace = %#v, %v; want flashback", got, err)
	}
	var count int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM dj_pins WHERE user_id = $1`, user).Scan(&count); err != nil {
		t.Fatalf("count pins: %v", err)
	}
	if count != 1 {
		t.Fatalf("dj_pins rows for user = %d, want 1", count)
	}

	if err := repo.DeleteDJPin(ctx, user); err != nil {
		t.Fatalf("delete pin: %v", err)
	}
	got, err = repo.GetDJPin(ctx, user)
	if err != nil || got != nil {
		t.Fatalf("pin after delete = %#v, %v; want nil, nil", got, err)
	}
	// Deleting a missing pin is not an error.
	if err := repo.DeleteDJPin(ctx, user); err != nil {
		t.Fatalf("delete missing pin: %v", err)
	}
}

func TestDJPinExpiryIgnoredAndLazilyDeleted(t *testing.T) {
	database, ctx := newDJPinTestDB(t)
	repo := NewDJPinRepository(database)
	user := seedPlayUser(t, database, "dj-pin-expiry@example.test")

	expired := DJPin{
		UserID:    user,
		BlockID:   "fresh-finds",
		EnergyLow: 0.2,
		EnergyHi:  0.9,
		Genres:    []string{},
		CreatedAt: time.Now().UTC().Add(-48 * time.Hour),
		ExpiresAt: time.Now().UTC().Add(-time.Minute),
	}
	if err := repo.UpsertDJPin(ctx, expired); err != nil {
		t.Fatalf("seed expired pin: %v", err)
	}

	got, err := repo.GetDJPin(ctx, user)
	if err != nil || got != nil {
		t.Fatalf("expired pin read = %#v, %v; want nil, nil", got, err)
	}
	var count int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM dj_pins WHERE user_id = $1`, user).Scan(&count); err != nil {
		t.Fatalf("count pins: %v", err)
	}
	if count != 0 {
		t.Fatalf("expired pin rows after read = %d, want 0 (lazy delete)", count)
	}
}

func TestDJPinUserScoping(t *testing.T) {
	database, ctx := newDJPinTestDB(t)
	repo := NewDJPinRepository(database)
	userA := seedPlayUser(t, database, "dj-pin-a@example.test")
	userB := seedPlayUser(t, database, "dj-pin-b@example.test")

	pin := DJPin{
		UserID:    userA,
		BlockID:   "on-repeat",
		EnergyLow: 0.5,
		EnergyHi:  0.7,
		Genres:    []string{"techno"},
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	if err := repo.UpsertDJPin(ctx, pin); err != nil {
		t.Fatalf("upsert pin for A: %v", err)
	}

	got, err := repo.GetDJPin(ctx, userB)
	if err != nil || got != nil {
		t.Fatalf("B read A's pin = %#v, %v; want nil, nil", got, err)
	}

	if err := repo.DeleteDJPin(ctx, userB); err != nil {
		t.Fatalf("B delete: %v", err)
	}
	got, err = repo.GetDJPin(ctx, userA)
	if err != nil || got == nil {
		t.Fatalf("A's pin after B delete = %#v, %v; want intact", got, err)
	}
	if _, err := database.Exec(`DELETE FROM dj_pins WHERE user_id = $1`, userA); err != nil {
		t.Fatalf("cleanup: %v", err)
	}
}
