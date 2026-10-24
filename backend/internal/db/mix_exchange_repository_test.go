package db

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// Hold INSERT itself behind an actual PostgreSQL relation lock, after source
// verification has run. Every competing mutation must remain blocked until the
// same transaction commits: this catches a second unlocked validation query.
func TestMixExchangeCreateVerifiedLocksSourcesThroughInsert(t *testing.T) {
	database, ctx, user, track, other, hash := seedExchangeAtomicTest(t)
	gate, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer gate.Rollback()
	if _, err := gate.ExecContext(ctx, `LOCK TABLE mix_plans IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	plan := exchangeAtomicPlan(user)
	createCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- NewMixExchangeRepository(database).CreateVerified(createCtx, plan, []MixExchangeSourceExpectation{{TrackID: track, SourceFileHash: hash, SourceEndMs: 6000}})
	}()
	waitExchangeQueryBlocked(t, database, "INSERT INTO mix_plans%")
	for _, mutation := range []struct {
		name, query string
		args        []any
	}{
		{"hash", `UPDATE tracks SET source_file_hash='changed' WHERE id=$1`, []any{track}},
		{"duration", `UPDATE tracks SET duration_ms=1 WHERE id=$1`, []any{track}},
		{"ownership delete", `DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, []any{user, track}},
		{"ownership transfer", `UPDATE user_library SET track_id=$1 WHERE user_id=$2 AND track_id=$3`, []any{other, user, track}},
		{"duplicate hash", `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, []any{hash, other}},
		{"duplicate membership", `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, []any{user, other + 1}},
	} {
		t.Run(mutation.name, func(t *testing.T) {
			tx, err := database.BeginTx(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			if _, err := tx.ExecContext(ctx, `SET LOCAL lock_timeout='150ms'`); err != nil {
				t.Fatal(err)
			}
			_, err = tx.ExecContext(ctx, mutation.query, mutation.args...)
			var pgErr *pq.Error
			if !errors.As(err, &pgErr) || pgErr.Code != "55P03" {
				t.Fatalf("source mutation was not fenced through INSERT: %v", err)
			}
		})
	}
	// Keep a genuine concurrent replacement pending, then let it commit only
	// after the plan's transaction releases its source row lock.
	updateCtx, cancelUpdate := context.WithTimeout(ctx, 8*time.Second)
	defer cancelUpdate()
	updated := make(chan error, 1)
	go func() {
		_, err := database.ExecContext(updateCtx, `UPDATE tracks SET source_file_hash='after-import' WHERE id=$1`, track)
		updated <- err
	}()
	waitExchangeQueryBlocked(t, database, "UPDATE tracks SET source_file_hash='after-import'%")
	var before string
	if err := database.QueryRowContext(ctx, `SELECT source_file_hash FROM tracks WHERE id=$1`, track).Scan(&before); err != nil || before != hash {
		t.Fatalf("source changed while INSERT was blocked: %q %v", before, err)
	}
	if err := gate.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := <-updated; err != nil {
		t.Fatal(err)
	}
	var after string
	if err := database.QueryRowContext(ctx, `SELECT source_file_hash FROM tracks WHERE id=$1`, track).Scan(&after); err != nil || after != "after-import" {
		t.Fatalf("replacement did not commit after import: %q %v", after, err)
	}
	stored, err := NewMixPlanRepository(database).GetByIDForUser(ctx, user, plan.ID)
	if err != nil || plan.Version != 1 || plan.CreatedAt.IsZero() || plan.UpdatedAt.IsZero() || stored == nil || stored.Version != plan.Version {
		t.Fatalf("atomic created plan/readback: %+v %+v %v", plan, stored, err)
	}
	var count int
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM user_library WHERE user_id=$1`, user).Scan(&count); err != nil || count != 2 {
		t.Fatalf("create changed audio grants: %d %v", count, err)
	}
}

// A membership insert that already holds the recipient FK lock must complete
// before verification takes its snapshot; otherwise that duplicate is a phantom.
func TestMixExchangeCreateVerifiedSeesInFlightDuplicateMembership(t *testing.T) {
	database, ctx, user, track, other, hash := seedExchangeAtomicTest(t)
	writer, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Rollback()
	if _, err := writer.ExecContext(ctx, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, user, other+1); err != nil {
		t.Fatal(err)
	}
	plan := exchangeAtomicPlan(user)
	createCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- NewMixExchangeRepository(database).CreateVerified(createCtx, plan, []MixExchangeSourceExpectation{{TrackID: track, SourceFileHash: hash, SourceEndMs: 6000}})
	}()
	waitExchangeQueryBlocked(t, database, "SELECT id FROM users%")
	if err := writer.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, ErrMixExchangeSourceMismatch) {
		t.Fatalf("in-flight duplicate was not revalidated: %v", err)
	}
	if plan.ID != uuid.Nil || plan.Version != 0 {
		t.Fatalf("failed create published metadata: %+v", plan)
	}
	var count int
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, user).Scan(&count); err != nil || count != 0 {
		t.Fatalf("duplicate race persisted plan: %d %v", count, err)
	}
}

func waitExchangeQueryBlocked(t *testing.T, database *DB, pattern string) {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		var blocked bool
		if err := database.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND query LIKE $1 AND wait_event_type='Lock')`, pattern).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("expected PostgreSQL lock wait for %q", pattern)
}

func exchangeAtomicPlan(user uuid.UUID) *MixPlan {
	return &MixPlan{UserID: user, SchemaVersion: 1, Name: "Atomic import", Payload: []byte(`{"schemaVersion":1,"name":"Atomic import","clips":[]}`), Summary: []byte(`{"clipCount":0,"trackIds":[],"durationMs":0}`)}
}

func seedExchangeAtomicTest(t *testing.T) (*DB, context.Context, uuid.UUID, int64, int64, string) {
	t.Helper()
	database, ctx := newGuardedTestDB(t, "set OMP_POSTGRES_TEST_DSN for atomic exchange tests", "TRUNCATE TABLE mix_plans, user_library, tracks, users RESTART IDENTITY CASCADE")
	user := uuid.New()
	if _, err := database.ExecContext(ctx, `INSERT INTO users(id,email,username,password_hash) VALUES ($1,$2,'exchange','x')`, user, user.String()+"@example.test"); err != nil {
		t.Fatal(err)
	}
	hash := "sha256:" + strings.Repeat("a", 64)
	var ids [3]int64
	for i := range ids {
		h := hash
		if i == 1 {
			h = "sha256:" + strings.Repeat("b", 64)
		}
		if err := database.QueryRowContext(ctx, `INSERT INTO tracks(identity_hash,title,source_file_hash,duration_ms) VALUES ($1,$2,$3,20000) RETURNING id`, uuid.NewString(), fmt.Sprint("source", i), h).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
		if i < 2 {
			if _, err := database.ExecContext(ctx, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, user, ids[i]); err != nil {
				t.Fatal(err)
			}
		}
	}
	return database, ctx, user, ids[0], ids[1], hash
}

func TestMixExchangeRepositoryResolvesOnlyRecipientLibrarySources(t *testing.T) {
	database, ctx := newGuardedTestDB(t, "set OMP_POSTGRES_TEST_DSN for mix exchange tests", "TRUNCATE TABLE user_library, tracks, users RESTART IDENTITY CASCADE")
	owner, recipient := uuid.New(), uuid.New()
	for _, user := range []uuid.UUID{owner, recipient} {
		if _, err := database.ExecContext(ctx, `INSERT INTO users (id,email,username,password_hash) VALUES ($1,$2,'exchange','x')`, user, user.String()+"@example.test"); err != nil {
			t.Fatal(err)
		}
	}
	hash := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	var first, second int64
	for i, id := range []*int64{&first, &second} {
		if err := database.QueryRowContext(ctx, `INSERT INTO tracks (identity_hash,title,source_file_hash,duration_ms) VALUES ($1,'source',$2,20000) RETURNING id`, uuid.NewString(), hash).Scan(id); err != nil {
			t.Fatal(err)
		}
		user := owner
		if i == 1 {
			user = recipient
		}
		if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id,track_id) VALUES ($1,$2)`, user, *id); err != nil {
			t.Fatal(err)
		}
	}
	repo := NewMixExchangeRepository(database)
	rows, err := repo.FindSourcesByHashes(ctx, recipient, []string{hash, hash})
	if err != nil || len(rows) != 1 || rows[0].TrackID != second || rows[0].SourceFileHash != hash || !rows[0].DurationMs.Valid || rows[0].DurationMs.Int64 != 20000 {
		t.Fatalf("recipient resolution = %+v, %v", rows, err)
	}
	rows, err = repo.FindSourcesByTrackIDs(ctx, recipient, []int64{first, second})
	if err != nil || len(rows) != 1 || rows[0].TrackID != second {
		t.Fatalf("export ownership = %+v, %v", rows, err)
	}
	if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id,track_id) VALUES ($1,$2)`, recipient, first); err != nil {
		t.Fatal(err)
	}
	rows, err = repo.FindSourcesByHashes(ctx, recipient, []string{hash})
	if err != nil || len(rows) != 2 {
		t.Fatalf("ambiguous matches must remain visible = %+v, %v", rows, err)
	}
	for _, hashes := range [][]string{nil, {"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}} {
		rows, err = repo.FindSourcesByHashes(ctx, recipient, hashes)
		if err != nil || len(rows) != 0 {
			t.Fatalf("missing resolution = %+v, %v", rows, err)
		}
	}
	rows, err = repo.FindSourcesByTrackIDs(ctx, recipient, nil)
	if err != nil || len(rows) != 0 {
		t.Fatalf("empty track resolution = %+v, %v", rows, err)
	}
}
