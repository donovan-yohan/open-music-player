package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
	"github.com/minio/minio-go/v7"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
)

type stagedFixtureStore struct {
	*storage.Client
	put    func(context.Context, string, io.Reader, int64) error
	delete func(context.Context, string) error
	get    func(context.Context, string) (io.ReadCloser, *storage.ObjectInfo, error)
	stat   func(context.Context, string) (*storage.ObjectInfo, error)
	absent func(context.Context, string) bool
}

func (s stagedFixtureStore) VerifyPrivateImportObjectAbsent(ctx context.Context, key string) bool {
	if s.absent != nil {
		return s.absent(ctx, key)
	}
	return s.Client.VerifyPrivateImportObjectAbsent(ctx, key)
}

func (s stagedFixtureStore) StatObject(ctx context.Context, key string) (*storage.ObjectInfo, error) {
	if s.stat != nil {
		return s.stat(ctx, key)
	}
	return s.Client.StatObject(ctx, key)
}

func (s stagedFixtureStore) GetObject(ctx context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error) {
	if s.get != nil {
		return s.get(ctx, key)
	}
	return s.Client.GetObject(ctx, key)
}

func (s stagedFixtureStore) PutPrivateImportObject(ctx context.Context, key string, audio io.Reader, size int64) error {
	if s.put != nil {
		return s.put(ctx, key, audio, size)
	}
	return s.Client.PutPrivateImportObject(ctx, key, audio, size)
}

func (s stagedFixtureStore) DeletePrivateImportObject(ctx context.Context, key string) error {
	if s.delete != nil {
		return s.delete(ctx, key)
	}
	return s.Client.DeletePrivateImportObject(ctx, key)
}

func privateIntakeEnv(t *testing.T) (context.Context, *db.DB, *storage.Client, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	t.Cleanup(cancel)
	pg := openPrivateImportFixtureDB(t, ctx)
	store := privateImportObjectStore(t, ctx)
	if err := pg.Migrate(); err != nil {
		t.Fatal(err)
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Fatal("requires fixture ffmpeg")
	}
	return ctx, pg, store, ffmpeg
}

func seedPrivateStageUser(t *testing.T, pg *db.DB, ctx context.Context) uuid.UUID {
	t.Helper()
	owner := seedPrivateImportUser(t, pg, ctx)
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		// The pool already passed DSN and exact fixture marker attestation.
		// Forget only the generated owner's test rows so permanent charge
		// cannot leak between scenarios; never reset a table or touch S3 here.
		if err := pg.CheckDatabaseNotProtected(cleanup); err != nil {
			t.Error(err)
			return
		}
		var marked bool
		if err := pg.QueryRowContext(cleanup, `SELECT current_user=current_database() AND shobj_description(oid,'pg_database')=$1 FROM pg_database WHERE datname=current_database()`, "private-fence-fixture:"+os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")).Scan(&marked); err != nil || !marked {
			t.Error("stage scenario cleanup refused: fixture marker did not match")
			return
		}
		if _, err := pg.ExecContext(cleanup, `DELETE FROM private_import_attempts WHERE owner_id=$1`, owner); err != nil {
			t.Error("could not release only this scenario's generated fixture rows")
		}
	})
	return owner
}

func stageManifest(owner uuid.UUID, data []byte) db.PrivateImportManifest {
	return db.PrivateImportManifest{OwnerID: owner, OperationID: uuid.New(), SHA256: fixtureSHA256(data), ByteLength: int64(len(data)), Title: "Generated tone"}
}

func newPrivateIntake(t *testing.T, pg *db.DB, store stagedFixtureStore, ffmpeg string) *processor.PrivateImportIntake {
	t.Helper()
	svc, err := processor.NewPrivateImportIntake(db.NewTrackRepository(pg), store, t.TempDir(), ffmpeg)
	if err != nil {
		t.Fatal(err)
	}
	return svc
}

func requireIntakeAttempt(t *testing.T, ctx context.Context, database *db.DB, m db.PrivateImportManifest, expected string) string {
	t.Helper()
	var attempt uuid.UUID
	var phase string
	if err := database.QueryRowContext(ctx, `SELECT attempt_id,phase FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, m.OwnerID, m.OperationID).Scan(&attempt, &phase); err != nil || phase != expected {
		t.Fatalf("exact attempt phase=%q, want %q: %v", phase, expected, err)
	}
	return (db.PrivateImportIntent{OwnerID: m.OwnerID, AttemptID: attempt}).ObjectKey()
}

func requireIntakeObject(t *testing.T, ctx context.Context, store *storage.Client, key string, data []byte) {
	t.Helper()
	body, info, err := store.GetObject(ctx, key)
	if err != nil {
		t.Fatal("exact fixture object unavailable")
	}
	defer body.Close()
	actual, err := io.ReadAll(io.LimitReader(body, int64(len(data))+1))
	if err != nil || !bytes.Equal(actual, data) || info.Size != int64(len(data)) || info.ContentType != "audio/mpeg" {
		t.Fatalf("fixture object readback mismatch: size=%d type=%q", info.Size, info.ContentType)
	}
}

func TestPrivateIntakeStage(t *testing.T) {
	ctx, pg, store, ffmpeg := privateIntakeEnv(t)
	// SeaweedFS's pinned disposable fixture supports this one bucket per
	// run. SQL capacity stays global, with per-scenario generated owners.
	for _, sc := range []struct {
		name string
		run  func(*testing.T, context.Context, *db.DB, uuid.UUID, *storage.Client, string)
	}{
		{"PermanentlyUncertainWriteStaysQuarantined", privateIntakeStageQuarantine},
		{"GlobalCapacity", privateIntakeStageGlobalCapacity},
		{"AdmissionProbeAndReceipt", privateIntakeStageAdmission},
		{"PutBeforeCommitRecoveryAndCleanup", privateIntakeStageRecovery},
		{"ExpiredCommitCannotRaceCleanup", privateIntakeStageExpiredCommit},
		{"LateAcknowledgementAndCleanupRetry", privateIntakeStageLateAck},
		{"ObservedPutRecoveryDoesNotReplay", privateIntakeStageUnacknowledged},
		{"CopiedGrantCannotCancelDispatchedPut", privateIntakeStageReservationOnce},
		{"ExpiryRecheckedAtSeal", privateIntakeStageAtSealExpiry},
		{"LostAuthorizeAckWithoutPut", privateIntakeStageLostAuthorizeAck},
		{"ConcurrentDedupeReceiptRecovery", privateIntakeStageReceiptRace},
	} {
		t.Run(sc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			t.Cleanup(cancel)
			sc.run(t, ctx, pg, seedPrivateStageUser(t, pg, ctx), store, ffmpeg)
		})
	}
}

func privateIntakeStageGlobalCapacity(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 839)
	for i := 0; i < 4; i++ {
		if i != 0 {
			owner = seedPrivateStageUser(t, pg, ctx)
		}
		m := stageManifest(owner, a.data)
		if _, _, err := db.NewTrackRepository(pg).ReservePrivateImportStage(ctx, m); err != nil {
			t.Fatalf("global slot %d unexpectedly charged, or rejected: %v", i+1, err)
		}
		requireIntakeAttempt(t, ctx, pg, m, "reserved")
	}
	svc := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	if r, err := svc.Import(ctx, stageManifest(seedPrivateStageUser(t, pg, ctx), a.data), neverReadPrivateIntake{t}); r != nil || !errors.Is(err, db.ErrPrivateImportStageCapacity) {
		t.Fatalf("fifth owner passed the global capacity fence: %v %v", r, err)
	}
}
func privateIntakeStageAdmission(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a, b := privateImportMP3(t, ctx, 541), privateImportMP3(t, ctx, 911)
	if len(a.data) != len(b.data) || a.hash == b.hash {
		t.Fatal("changed bytes control must have the same length and a different digest")
	}
	var good db.PrivateImportManifest
	puts := 0
	svc := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, audio io.Reader, size int64) error {
		puts++
		if good.OperationID != uuid.Nil && requireIntakeAttempt(t, ctx, pg, good, "putting") != key {
			t.Fatal("Put did not consume its durable exact attempt")
		}
		return store.PutPrivateImportObject(ctx, key, audio, size)
	}}, ffmpeg)
	preamble := append([]byte("#EXTM3U\nhttp://127.0.0.1:1/never\n"), a.data...)
	trailer := append(bytes.Clone(a.data), []byte("trailing non-audio")...)
	// Legal MPEG-1 Layer III frame headers and lengths, but impossible
	// decoder side information (all one bits). A header-only probe could pass.
	frame := bytes.Repeat([]byte{0xff}, 208)
	copy(frame, []byte{0xff, 0xfb, 0x50, 0xc0})
	undecodable := bytes.Repeat(frame, 6)
	for _, c := range []struct {
		name               string
		declared, supplied []byte
		want               error
	}{
		{"same_length_changed", a.data, b.data, processor.ErrPrivateIntakeBytes},
		{"short", a.data, a.data[:len(a.data)-1], processor.ErrPrivateIntakeBytes},
		{"over_declared_length", a.data, append(bytes.Clone(a.data), 'x'), processor.ErrPrivateIntakeSize},
		{"playlist_with_valid_mp3", preamble, preamble, processor.ErrPrivateIntakeProbe},
		{"trailing_data", trailer, trailer, processor.ErrPrivateIntakeProbe},
		{"decoder_refusal", undecodable, undecodable, processor.ErrPrivateIntakeProbe},
	} {
		if !t.Run(c.name, func(t *testing.T) {
			m := stageManifest(owner, c.declared)
			r, err := svc.Import(ctx, m, bytes.NewReader(c.supplied))
			if r != nil || !errors.Is(err, c.want) || puts != 0 {
				t.Fatalf("refusal receipt=%v err=%v puts=%d want=%v", r, err, puts, c.want)
			}
			key := requireIntakeAttempt(t, ctx, pg, m, "refused")
			if _, err := store.StatObject(ctx, key); !storage.IsObjectNotFound(err) {
				t.Fatal("refused attempt has an object")
			}
		}) {
			return
		}
	}
	if !t.Run("unknown_length_read_stops_at_cap_plus_one", func(t *testing.T) {
		m := stageManifest(owner, a.data)
		m.ByteLength = db.PrivateImportMaxBytes
		var stream zeroPrivateIntake
		r, err := svc.Import(ctx, m, &stream)
		if r != nil || !errors.Is(err, processor.ErrPrivateIntakeSize) || stream.read != db.PrivateImportMaxBytes+1 || puts != 0 {
			t.Fatalf("unbounded input read: receipt=%v err=%v length=%d puts=%d", r, err, stream.read, puts)
		}
		key := requireIntakeAttempt(t, ctx, pg, m, "refused")
		if _, err := store.StatObject(ctx, key); !storage.IsObjectNotFound(err) {
			t.Fatal("oversize attempt has an object")
		}
	}) {
		return
	}
	good = stageManifest(owner, a.data)
	tooBig := good
	tooBig.ByteLength = db.PrivateImportMaxBytes + 1
	if r, err := svc.Import(ctx, tooBig, neverReadPrivateIntake{t}); r != nil || !errors.Is(err, processor.ErrPrivateIntakeSize) || puts != 0 {
		t.Fatalf("over cap before read: %v %v puts=%d", r, err, puts)
	}
	r, err := svc.Import(ctx, good, bytes.NewReader(a.data))
	if err != nil || r == nil || r.TrackID <= 0 || r.OwnerID != owner || r.OperationID != good.OperationID || r.SHA256 != a.hash || r.ByteLength != int64(len(a.data)) || puts != 1 {
		t.Fatalf("canonical receipt: %v %v puts=%d", r, err, puts)
	}
	key := requireIntakeAttempt(t, ctx, pg, good, "winner")
	requireIntakeObject(t, ctx, store, key, a.data)
	var response minio.ErrorResponse
	if err := store.PutPrivateImportObject(ctx, key, bytes.NewReader(b.data), int64(len(b.data))); !errors.As(err, &response) || response.StatusCode != http.StatusPreconditionFailed {
		t.Fatal("real S3 did not enforce create-only write against the fixture winner")
	}
	requireIntakeObject(t, ctx, store, key, a.data)
	var duration int32
	var trackKey, hash string
	if err := pg.QueryRowContext(ctx, `SELECT duration_ms,storage_key,source_file_hash FROM tracks WHERE private_owner_id=$1 AND id=$2`, owner, r.TrackID).Scan(&duration, &trackKey, &hash); err != nil || duration < 450 || duration > 560 || trackKey != key || hash != a.hash {
		t.Fatalf("measured track facts: duration=%d hash_matches=%t key_matches=%t err=%v", duration, hash == a.hash, trackKey == key, err)
	}
	if historical, err := svc.Import(ctx, good, neverReadPrivateIntake{t}); err != nil || historical == nil || *historical != *r || puts != 1 {
		t.Fatalf("operation replay did not return canonical receipt: %v %v", historical, err)
	}
	changed := good
	changed.Title = "Different intent"
	if receipt, err := svc.Import(ctx, changed, neverReadPrivateIntake{t}); receipt != nil || !errors.Is(err, db.ErrPrivateImportIntentConflict) {
		t.Fatalf("changed intent replay: %v %v", receipt, err)
	}
}

type neverReadPrivateIntake struct{ t *testing.T }

type zeroPrivateIntake struct{ read int64 }

func (r *zeroPrivateIntake) Read(p []byte) (int, error) {
	clear(p)
	r.read += int64(len(p))
	return len(p), nil
}

func (r neverReadPrivateIntake) Read([]byte) (int, error) {
	r.t.Fatal("body read before admission or on replay")
	return 0, io.EOF
}

func privateIntakeStageRecovery(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a, b := privateImportMP3(t, ctx, 433), privateImportMP3(t, ctx, 721)
	svc := newPrivateIntake(t, pg, stagedFixtureStore{Client: store}, ffmpeg)
	// Fail the real receipt transaction after storage and after the attempted
	// track, membership and analysis writes. Its DB effects must roll back.
	if _, err := pg.ExecContext(ctx, `CREATE FUNCTION fixture_stage_receipt_fault() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'fixture stage receipt fault' USING DETAIL=NEW.track_id::text; END$$;
		CREATE TRIGGER fixture_stage_receipt_fault BEFORE INSERT ON private_import_receipts FOR EACH ROW EXECUTE FUNCTION fixture_stage_receipt_fault()`); err != nil {
		t.Fatal(err)
	}
	removeFault := func() {
		t.Helper()
		if _, err := pg.ExecContext(ctx, `DROP TRIGGER IF EXISTS fixture_stage_receipt_fault ON private_import_receipts; DROP FUNCTION IF EXISTS fixture_stage_receipt_fault()`); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(removeFault)
	failed := []db.PrivateImportManifest{stageManifest(owner, a.data), stageManifest(owner, b.data)}
	// Only one live upload per owner. Recover the first before admitting the second.
	r, err := svc.Import(ctx, failed[0], bytes.NewReader(a.data))
	var driverErr *pq.Error
	if r != nil || !errors.As(err, &driverErr) || driverErr.Message != "fixture stage receipt fault" {
		t.Fatalf("missing post-Put SQL fault: %v %v", r, err)
	}
	trackID, err := strconv.ParseInt(driverErr.Detail, 10, 64)
	if err != nil || trackID <= 0 {
		t.Fatal("receipt fault did not witness the attempted canonical track")
	}
	requireNoStagePublication(t, ctx, pg, failed[0], trackID)
	winnerKey := requireIntakeAttempt(t, ctx, pg, failed[0], "stored")
	requireIntakeObject(t, ctx, store, winnerKey, a.data)
	if r, err := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, owner, failed[0].OperationID); r != nil || !errors.Is(err, db.ErrPrivateImportNotFound) {
		t.Fatalf("rolled-back receipt escaped: %v %v", r, err)
	}
	if r, err := svc.Import(ctx, failed[1], neverReadPrivateIntake{t}); r != nil || !errors.Is(err, processor.ErrPrivateIntakeCapacity) {
		t.Fatalf("owner admitted a second active attempt: %v %v", r, err)
	}
	removeFault()
	secondDB := openPrivateImportFixtureDB(t, ctx)
	fresh := newPrivateIntake(t, secondDB, stagedFixtureStore{Client: store}, ffmpeg)
	winner, err := fresh.Recover(ctx, owner, failed[0].OperationID)
	if err != nil || winner == nil || winner.SHA256 != a.hash {
		t.Fatalf("fresh service did not recover stored attempt: %v %v", winner, err)
	}
	dup := stageManifest(owner, a.data)
	r, err = fresh.Import(ctx, dup, bytes.NewReader(a.data))
	if err != nil || r == nil || r.TrackID != winner.TrackID {
		t.Fatalf("canonical dedupe: %v %v", r, err)
	}
	loserKey := requireIntakeAttempt(t, ctx, pg, dup, "retiring")
	if loserKey == winnerKey {
		t.Fatal("dedupe reused the winner's key for Put")
	}
	requireIntakeObject(t, ctx, store, loserKey, a.data)
	if store.VerifyPrivateImportObjectAbsent(ctx, loserKey) {
		t.Fatal("owned S3 reported absence of present loser bytes")
	}
	if n, err := fresh.Collect(ctx, 8); err != nil || n != 1 {
		t.Fatalf("exact losing attempt collection: %d %v", n, err)
	}
	if _, err := store.StatObject(ctx, loserKey); !storage.IsObjectNotFound(err) {
		t.Fatal("losing key survived")
	}
	if !store.VerifyPrivateImportObjectAbsent(ctx, loserKey) {
		t.Fatal("owned S3 did not give an authoritative exact-key response")
	}
	requireIntakeObject(t, ctx, store, winnerKey, a.data)
}

func expirePrivateIntakeFixture(t *testing.T, ctx context.Context, pg *db.DB, m db.PrivateImportManifest) {
	t.Helper()
	result, err := pg.ExecContext(ctx, `UPDATE private_import_attempts SET expires_at=clock_timestamp()-INTERVAL '1 second'
		WHERE owner_id=$1 AND operation_id=$2`, m.OwnerID, m.OperationID)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := result.RowsAffected(); err != nil || n != 1 {
		t.Fatalf("expiry was not scoped to an exact fixture attempt: %d %v", n, err)
	}
}

type heldIntakeEOF struct {
	io.ReadCloser
	ctx     context.Context
	reached chan<- struct{}
	release <-chan struct{}
}

func (r heldIntakeEOF) Read(p []byte) (int, error) {
	n, err := r.ReadCloser.Read(p)
	if err == io.EOF {
		close(r.reached)
		select {
		case <-r.release:
		case <-r.ctx.Done():
			return n, r.ctx.Err()
		}
	}
	return n, err
}

func privateIntakeStageExpiredCommit(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 127)
	m := stageManifest(owner, a.data)
	uploadCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	seed := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, r io.Reader, n int64) error {
		if err := store.PutPrivateImportObject(ctx, key, r, n); err != nil {
			return err
		}
		cancel() // S3 acknowledged, but the original writer cannot commit.
		return nil
	}}, ffmpeg)
	if r, err := seed.Import(uploadCtx, m, bytes.NewReader(a.data)); r != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("setup did not leave an acknowledged object without a commit: %v %v", r, err)
	}
	key := requireIntakeAttempt(t, ctx, pg, m, "stored")
	reached, release := make(chan struct{}), make(chan struct{})
	readCtx, stop := context.WithCancel(ctx)
	defer stop()
	resume := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, get: func(ctx context.Context, k string) (io.ReadCloser, *storage.ObjectInfo, error) {
		body, info, err := store.GetObject(ctx, k)
		if err != nil {
			return nil, nil, err
		}
		return heldIntakeEOF{body, ctx, reached, release}, info, nil
	}}, ffmpeg)
	result := make(chan error, 1)
	go func() {
		receipt, err := resume.Recover(readCtx, owner, m.OperationID)
		if receipt != nil {
			err = errors.New("cleanup lost the fence: expired object obtained a receipt")
		}
		result <- err
	}()
	select {
	case <-reached:
	case err := <-result:
		t.Fatalf("canonical GET did not reach EOF before the fence: %v", err)
	case <-ctx.Done():
		t.Fatal("timed out waiting for exact canonical GET")
	}
	expirePrivateIntakeFixture(t, ctx, pg, m)
	if n, err := seed.Collect(ctx, 8); err != nil || n != 1 {
		t.Fatalf("cleanup did not retire the expired attempt: %d %v", n, err)
	}
	if _, err := store.StatObject(ctx, key); !storage.IsObjectNotFound(err) {
		t.Fatal("collector did not remove exact key")
	}
	close(release)
	select {
	case err := <-result:
		if !errors.Is(err, db.ErrPrivateImportStageClosed) {
			t.Fatalf("expired commit was not fenced in canonical SQL: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for stale commit")
	}
	if r, err := db.NewTrackRepository(pg).GetPrivateImportReceipt(ctx, owner, m.OperationID); r != nil || !errors.Is(err, db.ErrPrivateImportNotFound) {
		t.Fatalf("expired attempt published a receipt: %v %v", r, err)
	}
	requireIntakeAttempt(t, ctx, pg, m, "cleaned")
}

func privateIntakeStageLateAck(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 223)
	m := stageManifest(owner, a.data)
	start, release := make(chan string, 1), make(chan struct{})
	writeCtx, stop := context.WithCancel(ctx)
	defer stop()
	writer := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, r io.Reader, n int64) error {
		start <- key
		select {
		case <-release:
		case <-ctx.Done():
			return ctx.Err()
		}
		return store.PutPrivateImportObject(ctx, key, r, n)
	}}, ffmpeg)
	result := make(chan error, 1)
	go func() {
		r, err := writer.Import(writeCtx, m, bytes.NewReader(a.data))
		if r != nil {
			err = errors.New("late write unexpectedly issued a receipt")
		}
		result <- err
	}()
	var key string
	select {
	case key = <-start:
	case err := <-result:
		t.Fatalf("never reached Put: %v", err)
	case <-ctx.Done():
		t.Fatal("waiting for exact Put")
	}
	if key != requireIntakeAttempt(t, ctx, pg, m, "putting") {
		t.Fatal("held writer lacks exact custody")
	}
	deletes := 0
	collector := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, delete: func(ctx context.Context, k string) error {
		deletes++
		if k != key {
			t.Error("collector touched another object key")
		}
		return errors.New("fixture deletion unacknowledged")
	}}, ffmpeg)
	if n, err := collector.Collect(ctx, 8); n != 0 || err != nil || deletes != 0 {
		t.Fatalf("collector reached live Put: %d %v %d", n, err, deletes)
	}
	expirePrivateIntakeFixture(t, ctx, pg, m)
	if n, err := collector.Collect(ctx, 8); n != 0 || err != nil || deletes != 0 {
		t.Fatalf("collector deleted an unacknowledged Put: %d %v %d", n, err, deletes)
	}
	requireIntakeAttempt(t, ctx, pg, m, "quarantined")
	close(release)
	select {
	case err := <-result:
		if !errors.Is(err, db.ErrPrivateImportStageClosed) {
			t.Fatalf("late Put was not closed: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("waiting for late acknowledged Put")
	}
	requireIntakeAttempt(t, ctx, pg, m, "retiring")
	requireIntakeObject(t, ctx, store, key, a.data)
	if n, err := collector.Collect(ctx, 8); n != 0 || err == nil || deletes != 1 {
		t.Fatalf("failed Delete was not retained: %d %v %d", n, err, deletes)
	}
	if n, err := collector.Collect(ctx, 8); n != 0 || err != nil || deletes != 1 {
		t.Fatalf("failed Delete ignored backoff: %d %v %d", n, err, deletes)
	}
	requireIntakeAttempt(t, ctx, pg, m, "retiring")
	if _, err := pg.ExecContext(ctx, `UPDATE private_import_attempts SET cleanup_after=clock_timestamp()-INTERVAL '1 second' WHERE owner_id=$1 AND operation_id=$2`, owner, m.OperationID); err != nil {
		t.Fatal(err)
	}
	probes := 0
	ambiguous := newPrivateIntake(t, pg, stagedFixtureStore{Client: store, absent: func(_ context.Context, probed string) bool {
		probes++
		if probed != key {
			t.Fatal("absence proof did not address the exact retired object")
		}
		return false
	}}, ffmpeg)
	if n, err := ambiguous.Collect(ctx, 8); n != 0 || err == nil || probes != 1 {
		t.Fatalf("an acknowledged Delete without absence evidence released custody: %d %v %d", n, err, probes)
	}
	requireIntakeAttempt(t, ctx, pg, m, "retiring")
	if _, err := pg.ExecContext(ctx, `UPDATE private_import_attempts SET cleanup_after=clock_timestamp()-INTERVAL '1 second' WHERE owner_id=$1 AND operation_id=$2`, owner, m.OperationID); err != nil {
		t.Fatal(err)
	}
	newDB := openPrivateImportFixtureDB(t, ctx)
	retry := newPrivateIntake(t, newDB, stagedFixtureStore{Client: store}, ffmpeg)
	if n, err := retry.Collect(ctx, 8); n != 1 || err != nil {
		t.Fatalf("fresh reconciler could not collect exact attempt: %d %v", n, err)
	}
	if _, err := store.StatObject(ctx, key); !storage.IsObjectNotFound(err) {
		t.Fatal("expired object survived retry")
	}
	if r, err := retry.Import(ctx, m, neverReadPrivateIntake{t}); r != nil || !errors.Is(err, db.ErrPrivateImportStageClosed) {
		t.Fatalf("old operation reopened: %v %v", r, err)
	}
}

func privateIntakeStageUnacknowledged(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 987)
	m := stageManifest(owner, a.data)
	puts := 0
	objects := stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, r io.Reader, n int64) error {
		puts++
		if err := store.PutPrivateImportObject(ctx, key, r, n); err != nil {
			t.Error("fixture Put did not succeed")
			return err
		}
		return errors.New("fixture lost the successful Put acknowledgement before SQL")
	}}
	writer := newPrivateIntake(t, pg, objects, ffmpeg)
	if r, err := writer.Import(ctx, m, bytes.NewReader(a.data)); r != nil || !errors.Is(err, db.ErrPrivateImportStagePending) {
		t.Fatalf("lost acknowledgement admitted publication: %v %v", r, err)
	}
	key := requireIntakeAttempt(t, ctx, pg, m, "putting")
	requireIntakeObject(t, ctx, store, key, a.data)
	newDB := openPrivateImportFixtureDB(t, ctx)
	reader := newPrivateIntake(t, newDB, objects, ffmpeg)
	if r, err := reader.Import(ctx, m, neverReadPrivateIntake{t}); r != nil || !errors.Is(err, db.ErrPrivateImportStagePending) {
		t.Fatalf("duplicate in flight did not return pending: %v %v", r, err)
	}
	r, err := reader.Recover(ctx, owner, m.OperationID)
	if err != nil || r == nil || r.SHA256 != a.hash || r.OperationID != m.OperationID || puts != 1 {
		t.Fatalf("exact Put was not recovered without replay: %v %v puts=%d", r, err, puts)
	}
	if key != requireIntakeAttempt(t, ctx, pg, m, "winner") {
		t.Fatal("verification did not publish the observed key")
	}
	expirePrivateIntakeFixture(t, ctx, pg, m)
	if n, err := reader.Collect(ctx, 8); n != 0 || err != nil {
		t.Fatalf("winner entered expiry cleanup: %d %v", n, err)
	}
	requireIntakeObject(t, ctx, store, key, a.data)
}

func privateIntakeStageQuarantine(t *testing.T, ctx context.Context, pg *db.DB, owner uuid.UUID, store *storage.Client, ffmpeg string) {
	a := privateImportMP3(t, ctx, 347)
	m := stageManifest(owner, a.data)
	objects := stagedFixtureStore{Client: store, put: func(ctx context.Context, key string, r io.Reader, n int64) error {
		if err := store.PutPrivateImportObject(ctx, key, r, n); err != nil {
			t.Error("fixture Put did not succeed")
			return err
		}
		return errors.New("fixture lost the successful Put acknowledgement")
	}}
	writer := newPrivateIntake(t, pg, objects, ffmpeg)
	if r, err := writer.Import(ctx, m, bytes.NewReader(a.data)); r != nil || !errors.Is(err, db.ErrPrivateImportStagePending) {
		t.Fatalf("setup did not leave an uncertain Put: %v %v", r, err)
	}
	key := requireIntakeAttempt(t, ctx, pg, m, "putting")
	expirePrivateIntakeFixture(t, ctx, pg, m)
	newDB := openPrivateImportFixtureDB(t, ctx)
	collector := newPrivateIntake(t, newDB, stagedFixtureStore{Client: store}, ffmpeg)
	if n, err := collector.Collect(ctx, 8); n != 0 || err != nil {
		t.Fatalf("uncertain writer was not quarantined: %d %v", n, err)
	}
	requireIntakeAttempt(t, ctx, pg, m, "quarantined")
	requireIntakeObject(t, ctx, store, key, a.data)
	if r, err := collector.Recover(ctx, owner, m.OperationID); r != nil || !errors.Is(err, db.ErrPrivateImportStageClosed) {
		t.Fatalf("expired quarantine was reopened: %v %v", r, err)
	}
	if r, err := collector.Import(ctx, stageManifest(owner, a.data), neverReadPrivateIntake{t}); r != nil || !errors.Is(err, processor.ErrPrivateIntakeCapacity) {
		t.Fatalf("quarantine did not retain its capacity charge: %v %v", r, err)
	}
}
