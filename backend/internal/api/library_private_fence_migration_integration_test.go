package api

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

func TestLibraryFenceMigrationUnderLibraryReader(t *testing.T) {
	database := privateFenceTestDB(t)
	setupCtx, cancelSetup := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
	defer cancelSetup()
	owner, other := uuid.New(), uuid.New()
	if _, err := database.ExecContext(setupCtx, `INSERT INTO users(id,email,username,password_hash)
		VALUES ($1,$2,'owner','fixture'),($3,$4,'other','fixture')`, owner, owner.String()+"@example.test", other, other.String()+"@example.test"); err != nil {
		t.Fatal(err)
	}
	var shared, private int64
	if err := database.QueryRowContext(setupCtx, `INSERT INTO tracks(identity_hash,title) VALUES($1,'Shared fixture') RETURNING id`, uuid.NewString()).Scan(&shared); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRowContext(setupCtx, `INSERT INTO tracks(identity_hash,title,private_owner_id,source_file_hash,file_size_bytes,storage_key)
		VALUES($1,'Private fixture',$2,'sha256:'||repeat('a',64),42,$3) RETURNING id`, uuid.NewString(), owner, uuid.NewString()).Scan(&private); err != nil {
		t.Fatal(err)
	}
	cancelSetup()
	for _, tc := range []struct {
		name, drift string
	}{
		{name: "current"},
		{name: "missing", drift: `DROP TRIGGER trg_user_library_visible_track ON user_library`},
		{name: "disabled", drift: `ALTER TABLE user_library DISABLE TRIGGER trg_user_library_visible_track`},
		{name: "wrong_events", drift: `DROP TRIGGER trg_user_library_visible_track ON user_library;
			CREATE TRIGGER trg_user_library_visible_track AFTER UPDATE ON user_library
			FOR EACH ROW EXECUTE FUNCTION enforce_user_library_visible_track()`},
		{name: "wrong_condition", drift: `DROP TRIGGER trg_user_library_visible_track ON user_library;
			CREATE TRIGGER trg_user_library_visible_track AFTER INSERT OR UPDATE ON user_library
			FOR EACH ROW WHEN (false) EXECUTE FUNCTION enforce_user_library_visible_track()`},
		{name: "wrong_function_body", drift: `CREATE OR REPLACE FUNCTION enforce_user_library_visible_track()
			RETURNS trigger AS 'BEGIN RETURN NULL; END;' LANGUAGE plpgsql`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			if tc.drift != "" {
				if _, err := database.ExecContext(ctx, tc.drift); err != nil {
					t.Fatal(err)
				}
			}
			triggerOID := func() int64 {
				t.Helper()
				var oid int64
				if err := database.QueryRowContext(ctx, `SELECT oid FROM pg_trigger
					WHERE tgrelid='user_library'::regclass AND tgname='trg_user_library_visible_track'`).Scan(&oid); err != nil {
					t.Fatal(err)
				}
				return oid
			}
			var originalOID int64
			if tc.drift == "" {
				originalOID = triggerOID()
			}
			reader, err := database.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Rollback()
			var readerPID, libraryCount, trackCount int
			if err := reader.QueryRowContext(ctx, `SELECT pg_backend_pid(), count(*) FROM user_library`).Scan(&readerPID, &libraryCount); err != nil {
				t.Fatal(err)
			}
			var holdsLibrary, holdsTracks bool
			if err := database.QueryRowContext(ctx, `SELECT
				COALESCE(bool_or(relation='user_library'::regclass AND mode='AccessShareLock'),false),
				COALESCE(bool_or(relation='tracks'::regclass),false)
				FROM pg_locks WHERE pid=$1 AND granted`, readerPID).Scan(&holdsLibrary, &holdsTracks); err != nil || !holdsLibrary || holdsTracks {
				t.Fatalf("reader must hold only the first relation: Library=%v tracks=%v err=%v", holdsLibrary, holdsTracks, err)
			}
			result := make(chan error, 1)
			go func() { result <- database.Migrate() }()
			drained := false
			defer func() {
				// Release the reader before draining migration, including on a failed assertion.
				_ = reader.Rollback()
				if !drained {
					select {
					case <-result:
					case <-ctx.Done():
						t.Error("migration did not settle after releasing the reader")
					}
				}
			}()
			await := func(observeReader bool) {
				t.Helper()
				tick := time.NewTicker(10 * time.Millisecond)
				defer tick.Stop()
				for {
					select {
					case err := <-result:
						drained = true
						if err != nil {
							t.Fatalf("startup migration: %v", err)
						}
						if observeReader {
							t.Log("witness: migration completed while the Library reader transaction was held")
						}
						return
					case <-tick.C:
						if !observeReader {
							continue
						}
						var waitsOnLibrary, holdsTracks bool
						if err := database.QueryRowContext(ctx, `SELECT count(*) > 0, COALESCE(bool_or(EXISTS (
							SELECT FROM pg_locks track WHERE track.pid=lib.pid AND track.granted
							AND track.relation='tracks'::regclass AND track.mode='AccessExclusiveLock')), false)
							FROM pg_locks lib WHERE lib.relation='user_library'::regclass AND NOT lib.granted
							AND $1 = ANY(pg_blocking_pids(lib.pid))`, readerPID).Scan(&waitsOnLibrary, &holdsTracks); err != nil {
							t.Fatal(err)
						}
						if waitsOnLibrary {
							t.Logf("witness: migration waits on held Library read; tracks AccessExclusive granted=%v", holdsTracks)
							if holdsTracks {
								_, err := reader.ExecContext(ctx, `LOCK TABLE tracks IN ACCESS SHARE MODE NOWAIT`)
								var pgErr *pq.Error
								if !errors.As(err, &pgErr) || pgErr.Code != "55P03" {
									t.Fatalf("expected the reader's tracks AccessShare to be refused, got %v", err)
								}
								t.Fatal("lock inversion: startup holds tracks AccessExclusive while waiting on user_library; reader's tracks AccessShare refused (55P03)")
							}
							if tc.drift == "" {
								t.Fatal("startup rewrites the current trigger behind a Library reader")
							}
							return
						}
					case <-ctx.Done():
						t.Fatal("neither migration completion nor Library lock wait observed")
					}
				}
			}
			await(true)
			if err := reader.QueryRowContext(ctx, `SELECT count(*) FROM tracks`).Scan(&trackCount); err != nil {
				t.Fatalf("Library reader could not continue to tracks: %v", err)
			}
			if err := reader.Commit(); err != nil {
				t.Fatal(err)
			}
			if !drained {
				await(false)
			}
			if tc.drift == "" && triggerOID() != originalOID {
				t.Fatal("startup replaced the current trigger")
			}
			membership := `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`
			var pgErr *pq.Error
			if _, err := database.ExecContext(ctx, membership, other, private); !errors.As(err, &pgErr) || pgErr.Code != "23503" || pgErr.Constraint != "user_library_visible_track" {
				t.Fatalf("foreign INSERT not fenced at startup completion: %v", err)
			}
			if _, err := database.ExecContext(ctx, membership+`,($3,$4) ON CONFLICT (user_id,track_id) DO UPDATE SET added_at=excluded.added_at`, owner, private, other, shared); err != nil {
				t.Fatalf("owner/private and ordinary shared memberships must remain writable: %v", err)
			}
			if _, err := database.ExecContext(ctx, `UPDATE user_library SET track_id=$1 WHERE user_id=$2 AND track_id=$3`, private, other, shared); !errors.As(err, &pgErr) || pgErr.Code != "23503" || pgErr.Constraint != "user_library_visible_track" {
				t.Fatalf("foreign UPDATE not fenced at startup completion: %v", err)
			}
		})
	}
}
