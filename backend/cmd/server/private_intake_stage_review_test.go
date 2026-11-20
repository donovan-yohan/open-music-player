package main

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
)

func requireNoStagePublication(t *testing.T, ctx context.Context, pg *db.DB, m db.PrivateImportManifest, trackID int64) {
	t.Helper()
	var tracks, memberships, analysisRows, receipts int
	err := pg.QueryRowContext(ctx, `SELECT
		(SELECT count(*) FROM tracks WHERE id=$1 OR (private_owner_id=$2 AND source_file_hash=$4)),
		(SELECT count(*) FROM user_library WHERE user_id=$2 AND track_id=$1),
		(SELECT count(*) FROM track_analysis WHERE track_id=$1),
		(SELECT count(*) FROM private_import_receipts WHERE owner_id=$2 AND operation_id=$3)`, trackID, m.OwnerID, m.OperationID, m.SHA256).Scan(&tracks, &memberships, &analysisRows, &receipts)
	if err != nil || tracks != 0 || memberships != 0 || analysisRows != 0 || receipts != 0 {
		t.Fatalf("publication did not roll back: track=%d membership=%d analysis=%d receipt=%d err=%v", tracks, memberships, analysisRows, receipts, err)
	}
}

func waitPrivateIntakeSQL(t *testing.T, ctx context.Context, pg *db.DB, query string, args ...any) {
	t.Helper()
	ticker := time.NewTicker(15 * time.Millisecond)
	defer ticker.Stop()
	for {
		var ready bool
		if err := pg.QueryRowContext(ctx, query, args...).Scan(&ready); err != nil {
			t.Fatalf("waiting for SQL boundary: %v", err)
		}
		if ready {
			return
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatal("SQL boundary did not arrive")
		}
	}
}

func privateIntakeStageAtSealExpiry(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 653)
	m := stageManifest(owner, a.data)
	uploadCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	seed := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, r io.Reader, n int64) error {
		if err := store.PutPrivateImportObject(ctx, key, r, n); err != nil {
			return err
		}
		cancel()
		return nil
	}}, ffmpeg)
	if r, err := seed.Import(uploadCtx, m, bytes.NewReader(a.data)); r != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("setup did not leave stored bytes: %v %v", r, err)
	}
	key := requireIntakeAttempt(t, ctx, pg, m, "stored")
	// An AFTER INSERT trigger sees all four writes, saves only the generated
	// row ID in a fixture sequence (non-transactional), and blocks the INSERT.
	if _, err := pg.ExecContext(ctx, `CREATE SEQUENCE fixture_stage_seal_track;
		CREATE FUNCTION fixture_stage_seal_hold() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
		IF NOT EXISTS (SELECT 1 FROM tracks WHERE id=NEW.track_id AND private_owner_id=NEW.owner_id)
			OR NOT EXISTS (SELECT 1 FROM user_library WHERE user_id=NEW.owner_id AND track_id=NEW.track_id)
			OR NOT EXISTS (SELECT 1 FROM track_analysis WHERE track_id=NEW.track_id)
			OR NOT EXISTS (SELECT 1 FROM private_import_receipts WHERE owner_id=NEW.owner_id AND operation_id=NEW.operation_id)
		THEN RAISE EXCEPTION 'fixture did not reach all four writes'; END IF;
		PERFORM setval('fixture_stage_seal_track', NEW.track_id);
		PERFORM pg_advisory_xact_lock(98442175);
		RETURN NEW; END $$;
		CREATE TRIGGER fixture_stage_seal_hold AFTER INSERT ON private_import_receipts FOR EACH ROW EXECUTE FUNCTION fixture_stage_seal_hold()`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := pg.ExecContext(cleanup, `DROP TRIGGER fixture_stage_seal_hold ON private_import_receipts; DROP FUNCTION fixture_stage_seal_hold(); DROP SEQUENCE fixture_stage_seal_track`); err != nil {
			t.Error(err)
		}
	})
	holder, err := pg.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback() }()
	if _, err := holder.ExecContext(ctx, `SELECT pg_advisory_xact_lock(98442175)`); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.ExecContext(ctx, `UPDATE private_import_attempts SET expires_at=clock_timestamp()+INTERVAL '4 seconds' WHERE owner_id=$1 AND operation_id=$2`, owner, m.OperationID); err != nil {
		t.Fatal(err)
	}
	type outcome struct {
		r *db.PrivateImportReceipt
		e error
	}
	result := make(chan outcome, 1)
	resume := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	go func() {
		r, err := resume.Recover(ctx, owner, m.OperationID)
		result <- outcome{r, err}
	}()
	waiting, stop := context.WithTimeout(ctx, 3*time.Second)
	defer stop()
	waitPrivateIntakeSQL(t, waiting, pg, `SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=0 AND objid=98442175 AND objsubid=1 AND NOT granted)`)
	var trackID int64
	var live bool
	if err := pg.QueryRowContext(ctx, `SELECT last_value, (SELECT expires_at>clock_timestamp() FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2)
		FROM fixture_stage_seal_track WHERE is_called`, owner, m.OperationID).Scan(&trackID, &live); err != nil || !live || trackID <= 0 {
		t.Fatalf("held receipt INSERT did not reach all writes while live: %v %d %v", live, trackID, err)
	}
	requireNoStagePublication(t, ctx, pg, m, trackID) // None visible while the transaction is held.
	waitPrivateIntakeSQL(t, ctx, pg, `SELECT expires_at<=clock_timestamp() FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, owner, m.OperationID)
	if err := holder.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case out := <-result:
		if out.r != nil || !errors.Is(out.e, db.ErrPrivateImportStageClosed) {
			t.Errorf("expired at seal: receipt=%v err=%v", out.r, out.e)
		}
	case <-ctx.Done():
		t.Fatal("receipt INSERT did not drain")
	}
	requireNoStagePublication(t, ctx, pg, m, trackID)
	requireIntakeAttempt(t, ctx, pg, m, "stored")
	requireIntakeObject(t, ctx, store, key, a.data)
	if n, err := resume.Collect(ctx, 8); err != nil || n != 1 {
		t.Fatalf("expired rolled-back attempt not collectible: %d %v", n, err)
	}
}

type stageAuthLossConnector struct {
	driver.Connector
	after func()
}

func (c stageAuthLossConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return stageAuthLossConn{Conn: conn, after: c.after}, nil
}

type stageAuthLossConn struct {
	driver.Conn
	after func()
}

var errStageAuthLost = errors.New("fixture consumed SQL ACK with generated key-detail sentinel")

func (c stageAuthLossConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	exec, ok := c.Conn.(driver.ExecerContext)
	if !ok {
		return nil, driver.ErrSkip
	}
	result, err := exec.ExecContext(ctx, query, args)
	if err == nil && strings.Contains(query, "SET phase='putting'") {
		c.after() // The actual SQL autocommit succeeded; withhold its ACK from the repository.
		return nil, errStageAuthLost
	}
	return result, err
}

func (c stageAuthLossConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if q, ok := c.Conn.(driver.QueryerContext); ok {
		return q.QueryContext(ctx, query, args)
	}
	return nil, driver.ErrSkip
}

func openStageAuthLossFixtureDB(t *testing.T, ctx context.Context, after func()) *db.DB {
	t.Helper()
	dsn, token := os.Getenv("OMP_PRIVATE_FENCE_TEST_DSN"), os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")
	parts := privateImportFixtureDSN.FindStringSubmatch(dsn)
	if len(parts) != 3 || parts[1] != parts[2] || !privateImportFixtureMarker.MatchString(token) || os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		t.Fatal("refusing non-disposable fixture DSN")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	connector, err := pq.NewConnector(dsn)
	if err != nil {
		t.Fatal("could not construct attested Postgres connector")
	}
	pool := sql.OpenDB(stageAuthLossConnector{Connector: connector, after: after})
	t.Cleanup(func() { _ = pool.Close() })
	pg := &db.DB{DB: pool}
	if err := pg.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	var name, role, comment string
	if err := pool.QueryRowContext(ctx, `SELECT current_database(), current_user, COALESCE(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname=current_database()`).Scan(&name, &role, &comment); err != nil || name != parts[1] || role != name || comment != "private-fence-fixture:"+token {
		t.Fatal("authorization-loss fixture attestation mismatch")
	}
	return pg
}

func privateIntakeStageLostAuthorizeAck(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 773)
	m := stageManifest(owner, a.data)
	upload, cancel := context.WithCancel(ctx)
	defer cancel()
	var committedKey string
	other := stageManifest(seedPrivateStageUser(t, pg, ctx), a.data)
	otherUploader := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, body io.Reader, n int64) error {
		if err := store.PutPrivateImportObject(ctx, key, body, n); err != nil {
			return err
		}
		return errors.New("fixture lost a real, different Put ACK")
	}}, ffmpeg)
	if r, err := otherUploader.Import(ctx, other, bytes.NewReader(a.data)); r != nil || !errors.Is(err, db.ErrPrivateImportStagePending) {
		t.Fatalf("setup did not retain actual sibling Put: %v %v", r, err)
	}
	siblingKey := requireIntakeAttempt(t, ctx, pg, other, "putting")
	authorizations := 0
	lost := openStageAuthLossFixtureDB(t, ctx, func() {
		authorizations++
		committedKey = requireIntakeAttempt(t, ctx, pg, m, "putting")
		cancel()
	})
	puts, deletes, reads := 0, 0, 0
	writer := newPrivateIntake(t, lost, stagedFixtureStore{Client: store,
		put:    func(context.Context, string, io.Reader, int64) error { puts++; return errors.New("unexpected Put") },
		delete: func(context.Context, string) error { deletes++; return errors.New("unexpected Delete") },
		stat: func(context.Context, string) (*storage.ObjectInfo, error) {
			reads++
			return nil, errors.New("unexpected Stat")
		},
		get: func(context.Context, string) (io.ReadCloser, *storage.ObjectInfo, error) {
			reads++
			return nil, nil, errors.New("unexpected Get")
		},
	}, ffmpeg)
	if r, err := writer.Import(upload, m, bytes.NewReader(a.data)); r != nil || !errors.Is(err, errStageAuthLost) || strings.Contains(err.Error(), errStageAuthLost.Error()) || authorizations != 1 || committedKey == "" || puts+deletes+reads != 0 {
		t.Errorf("did not keep distinct committed-authorize/lost-ACK custody: receipt=%v err=%v authorizations=%d put=%d delete=%d read=%d", r, err, authorizations, puts, deletes, reads)
	}
	if key := requireIntakeAttempt(t, ctx, pg, m, "refused"); key != committedKey {
		t.Fatal("settlement did not burn the exact undispatched attempt")
	}
	if _, err := store.StatObject(ctx, committedKey); !storage.IsObjectNotFound(err) {
		t.Fatal("undispatched attempt did not remain absent")
	}
	if r, err := writer.Import(ctx, m, neverReadPrivateIntake{t}); r != nil || !errors.Is(err, db.ErrPrivateImportStageClosed) {
		t.Fatalf("burned operation reopened: %v %v", r, err)
	}
	fresh := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	next := stageManifest(owner, a.data)
	if r, err := fresh.Import(ctx, next, bytes.NewReader(a.data)); r == nil || err != nil {
		t.Fatalf("no-Put settlement did not free owner capacity: %v %v", r, err)
	}
	if key := requireIntakeAttempt(t, ctx, pg, next, "winner"); key == committedKey {
		t.Fatal("fresh admission reused retired attempt key")
	}
	expirePrivateIntakeFixture(t, ctx, pg, other)
	if n, err := fresh.Collect(ctx, 8); n != 0 || err != nil {
		t.Fatalf("a genuine lost Put was made collectable: %d %v", n, err)
	}
	requireIntakeAttempt(t, ctx, pg, other, "quarantined")
	requireIntakeObject(t, ctx, store, siblingKey, a.data)
}

func privateIntakeStageReservationOnce(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 543)
	m := stageManifest(owner, a.data)
	grant, receipt, err := db.NewTrackRepository(pg).ReservePrivateImportStage(ctx, m)
	if grant == nil || receipt != nil || err != nil {
		t.Fatalf("reservation not admitted: %v %v", receipt, err)
	}
	copied := *grant
	in, err := grant.AuthorizePut(ctx, a.ms)
	if err != nil || in.ObjectKey() != requireIntakeAttempt(t, ctx, pg, m, "putting") {
		t.Fatalf("did not authorize exact attempt: %v", err)
	}
	if err := store.PutPrivateImportObject(ctx, in.ObjectKey(), bytes.NewReader(a.data), in.ByteLength); err != nil {
		t.Fatal("could not dispatch original Put")
	}
	if _, err := copied.AuthorizePut(ctx, a.ms); !errors.Is(err, db.ErrPrivateImportStageClosed) {
		t.Fatalf("copied grant re-entered the Put barrier: %v", err)
	}
	requireIntakeAttempt(t, ctx, pg, m, "putting")
	expirePrivateIntakeFixture(t, ctx, pg, m)
	collector := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	if n, err := collector.Collect(ctx, 8); n != 0 || err != nil {
		t.Fatalf("copied grant allowed collection of dispatched Put: %d %v", n, err)
	}
	requireIntakeAttempt(t, ctx, pg, m, "quarantined")
	requireIntakeObject(t, ctx, store, in.ObjectKey(), a.data)
}

func privateIntakeStageReceiptRace(t *testing.T, ctx context.Context, pg *db.DB, _ uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 937)
	ordinary := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	repo := db.NewTrackRepository(pg)
	for _, tc := range []struct {
		name  string
		stat  bool
		exact bool
	}{{"stat", true, true}, {"get", false, true}, {"stat_other_operation", true, false}, {"get_other_operation", false, false}} {
		t.Run(tc.name, func(t *testing.T) {
			owner := seedPrivateStageUser(t, pg, ctx)
			first := stageManifest(owner, a.data)
			winner, err := ordinary.Import(ctx, first, bytes.NewReader(a.data))
			if err != nil || winner == nil {
				t.Fatalf("missing canonical dedupe setup: %v %v", winner, err)
			}
			winnerKey := requireIntakeAttempt(t, ctx, pg, first, "winner")
			m := stageManifest(owner, a.data)
			grant, receipt, err := repo.ReservePrivateImportStage(ctx, m)
			if grant == nil || receipt != nil || err != nil {
				t.Fatalf("lost reservation before staged race setup: %v %v", receipt, err)
			}
			in, err := grant.AuthorizePut(ctx, a.ms)
			if err != nil {
				t.Fatal(err)
			}
			loserKey := requireIntakeAttempt(t, ctx, pg, m, "putting")
			if loserKey == winnerKey || loserKey != in.ObjectKey() {
				t.Fatal("dedupe setup did not reserve its own attempt key")
			}
			if err := store.PutPrivateImportObject(ctx, loserKey, bytes.NewReader(a.data), in.ByteLength); err != nil {
				t.Fatal("fixture could not stage loser bytes")
			}
			// Hold the positive S3 ACK before SQL so Recover's first GET,
			// like its Stat, addresses the loser (not the canonical winner).
			complete := func() {
				t.Helper()
				if err := repo.AcknowledgePrivateImportPut(ctx, in); err != nil {
					t.Fatal(err)
				}
			}
			if tc.stat {
				complete() // A stored object missing at Stat yields the byte error.
			}
			settle := func() {
				t.Helper()
				if !tc.stat {
					complete()
				}
				if !tc.exact {
					// Fixture-induced missing acknowledged object, not
					// production collection. The other operation's receipt
					// and exactly matching bytes are insufficient to recover.
					if err := store.DeleteObject(ctx, loserKey); err != nil {
						t.Fatal("could not remove the fixture-only losing object")
					}
					return
				}
				r, err := ordinary.Recover(ctx, owner, m.OperationID)
				if err != nil || r == nil || r.TrackID != winner.TrackID || r.OperationID != m.OperationID {
					t.Fatalf("concurrent recovery could not settle deduped attempt: %v %v", r, err)
				}
				winner = r
				if n, err := ordinary.Collect(ctx, 8); n != 1 || err != nil {
					t.Fatalf("concurrent cleanup did not remove the loser: %d %v", n, err)
				}
			}
			objects := stagedFixtureStore{Client: store}
			if tc.stat {
				objects.stat = func(ctx context.Context, key string) (*storage.ObjectInfo, error) {
					if key != loserKey {
						t.Fatal("expected stale Stat of exact loser")
					}
					settle()
					return store.StatObject(ctx, key)
				}
			} else {
				objects.get = func(ctx context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error) {
					if key != loserKey {
						t.Fatal("expected stale Get of exact loser")
					}
					settle()
					return store.GetObject(ctx, key)
				}
			}
			stale := newPrivateIntake(t, pg, objects, ffmpeg)
			r, err := stale.Recover(ctx, owner, m.OperationID)
			if tc.exact {
				if err != nil || r == nil || *r != *winner {
					t.Fatalf("raced read did not recover exact historical receipt: %v %v", r, err)
				}
			} else if r != nil || !errors.Is(err, processor.ErrPrivateImportBytes) || winner.OperationID == m.OperationID {
				t.Fatalf("missing object without exact receipt did not preserve its original error: %v %v", r, err)
			}
			requireIntakeObject(t, ctx, store, winnerKey, a.data)
		})
	}
}
