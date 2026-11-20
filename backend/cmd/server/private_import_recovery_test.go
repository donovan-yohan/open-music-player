package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/lib/pq"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
)

type privateFixtureAudio struct {
	path string
	data []byte
	hash string
	ms   int32
}

func privateImportMP3(t *testing.T, ctx context.Context, hz int) privateFixtureAudio {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fixture.mp3")
	ffmpeg := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=%d:duration=0.5", hz), "-c:a", "libmp3lame", "-b:a", "64k", path)
	if output, err := ffmpeg.CombinedOutput(); err != nil {
		t.Fatalf("generate MP3: %v %s", err, output)
	}
	probe := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path)
	output, err := probe.Output()
	if err != nil {
		t.Fatal(err)
	}
	seconds, err := strconv.ParseFloat(strings.TrimSpace(string(output)), 64)
	if err != nil || seconds < 0.5 || seconds > 1 {
		t.Fatalf("unexpected generated media duration %q: %v", output, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return privateFixtureAudio{path, data, fixtureSHA256(data), int32(seconds*1000 + 0.5)}
}

func fixtureSHA256(data []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(data)) }

func privateImportObjectStore(t *testing.T, ctx context.Context) *storage.Client {
	t.Helper()
	endpoint, key, secret := os.Getenv("OMP_PRIVATE_IMPORT_S3"), os.Getenv("OMP_PRIVATE_IMPORT_S3_ID"), os.Getenv("OMP_PRIVATE_IMPORT_S3_SECRET")
	if endpoint == "" {
		t.Skip("requires an owned disposable fixture object store")
	}
	if !regexp.MustCompile(`^127\.0\.0\.1:[1-9][0-9]{0,4}$`).MatchString(endpoint) || !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(key) || !privateImportFixtureMarker.MatchString(secret) {
		t.Fatal("refusing invalid disposable object store authority")
	}
	bucket := "soundq-fixture-" + uuid.NewString()
	admin, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4(key, secret, ""), Region: "us-east-1"})
	if err != nil {
		t.Fatal("construct loopback object client")
	}
	if err := admin.MakeBucket(ctx, bucket, minio.MakeBucketOptions{Region: "us-east-1"}); err != nil {
		t.Fatalf("create exclusive fixture bucket: %v", err)
	}
	client, err := storage.New(&storage.Config{Endpoint: endpoint, AccessKey: key, SecretKey: secret, Bucket: bucket})
	if err != nil {
		t.Fatal("construct ordinary fixture storage client")
	}
	return client
}

// Wrap only the worker's transition boundary; all claim, mark, terminal and
// result operations still reach the real repository and PostgreSQL.
type fixtureHeldPrivateAnalysisStart struct {
	*db.AnalysisRepository
	trackID int64
	seen    chan<- struct{}
	release <-chan struct{}
}

func (s fixtureHeldPrivateAnalysisStart) MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	if trackID == s.trackID {
		select {
		case s.seen <- struct{}{}:
		case <-ctx.Done():
			return ctx.Err()
		}
		select {
		case <-s.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return s.AnalysisRepository.MarkAnalyzing(ctx, trackID, provenance)
}

// Durable recovery deliberately closes its first pool. Keep teardown on a
// separately attested pool and delete each receipt before its shared track.
type durableImportFixtures struct {
	owners    []uuid.UUID
	receipts  map[[2]uuid.UUID]int64
	publicKey string
}

func (f durableImportFixtures) remove(ctx context.Context, database *db.DB) error {
	tx, err := database.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for ids, trackID := range f.receipts {
		if _, err := tx.ExecContext(ctx, `DELETE FROM private_import_receipts WHERE owner_id=$1 AND operation_id=$2 AND track_id=$3`, ids[0], ids[1], trackID); err != nil {
			return fmt.Errorf("delete owned receipt: %w", err)
		}
	}
	for ids, trackID := range f.receipts {
		if _, err := tx.ExecContext(ctx, `DELETE FROM tracks WHERE private_owner_id=$1 AND id=$2`, ids[0], trackID); err != nil {
			return fmt.Errorf("delete owned private track: %w", err)
		}
	}
	if f.publicKey != "" {
		if _, err := tx.ExecContext(ctx, `DELETE FROM tracks WHERE storage_key=$1 AND private_owner_id IS NULL`, f.publicKey); err != nil {
			return fmt.Errorf("delete owned ordinary download: %w", err)
		}
	}
	for _, owner := range f.owners {
		if _, err := tx.ExecContext(ctx, `DELETE FROM users WHERE id=$1`, owner); err != nil {
			return fmt.Errorf("delete owned fixture user: %w", err)
		}
	}
	return tx.Commit()
}

func (f durableImportFixtures) assertRemoved(t *testing.T, database *db.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	assertAbsent := func(label, query string, args ...any) {
		t.Helper()
		var present bool
		if err := database.QueryRowContext(ctx, query, args...).Scan(&present); err != nil || present {
			t.Errorf("owned %s remains after durable fixture cleanup: present=%t err=%v", label, present, err)
		}
	}
	for ids, trackID := range f.receipts {
		assertAbsent("receipt", `SELECT EXISTS (SELECT 1 FROM private_import_receipts WHERE owner_id=$1 AND operation_id=$2)`, ids[0], ids[1])
		assertAbsent("private track", `SELECT EXISTS (SELECT 1 FROM tracks WHERE id=$1)`, trackID)
	}
	if f.publicKey != "" {
		assertAbsent("download track", `SELECT EXISTS (SELECT 1 FROM tracks WHERE storage_key=$1)`, f.publicKey)
	}
	for _, owner := range f.owners {
		assertAbsent("user", `SELECT EXISTS (SELECT 1 FROM users WHERE id=$1)`, owner)
	}
}

func registerDurableImportFaultCleanup(t *testing.T, database *db.DB, statement string) {
	t.Helper()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := database.ExecContext(ctx, statement); err != nil {
			t.Errorf("restore durable import fault fixture: %v", err)
		}
	})
}

func TestPrivateImportDurableReceiptAndCanonicalAnalysisRecovery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	firstDB := openPrivateImportFixtureDB(t, ctx)
	objects := privateImportObjectStore(t, ctx)
	if err := firstDB.Migrate(); err != nil {
		t.Fatal(err)
	}
	cleanupDB := openPrivateImportFixtureDB(t, ctx)
	fixtures := durableImportFixtures{receipts: make(map[[2]uuid.UUID]int64)}
	workersStopped := true
	t.Cleanup(func() { fixtures.assertRemoved(t, cleanupDB) })
	t.Cleanup(func() {
		if !workersStopped {
			t.Error("cannot remove durable fixtures before analysis workers stop")
			return
		}
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if err := fixtures.remove(cleanup, cleanupDB); err != nil {
			t.Errorf("remove durable fixtures: %v", err)
		}
	})
	owner := seedPrivateImportUser(t, firstDB, ctx)
	fixtures.owners = append(fixtures.owners, owner)
	other := seedPrivateImportUser(t, firstDB, ctx)
	fixtures.owners = append(fixtures.owners, other)
	a, b := privateImportMP3(t, ctx, 557), privateImportMP3(t, ctx, 907)
	if len(a.data) != len(b.data) || a.hash == b.hash {
		t.Fatal("negative must have equal length but distinct bytes")
	}
	t.Logf("generated MP3 A=%s B=%s bytes=%d measured_ms=%d", a.hash, b.hash, len(a.data), a.ms)
	put := func(key string, audio privateFixtureAudio) {
		t.Helper()
		if err := objects.PutObject(ctx, key, bytes.NewReader(audio.data), int64(len(audio.data)), "audio/mpeg"); err != nil {
			t.Fatal(err)
		}
	}
	newIntent := func(u uuid.UUID, audio privateFixtureAudio) db.PrivateImportIntent {
		return db.PrivateImportIntent{OwnerID: u, OperationID: uuid.New(), AttemptID: uuid.New(), SHA256: audio.hash, ByteLength: int64(len(audio.data)), DurationMs: audio.ms, Title: "Distinct private title", Artist: "Distinct private artist", Album: "Distinct private album"}
	}
	first, second, absent := newIntent(owner, a), newIntent(other, a), newIntent(other, b)
	second.OperationID, second.AttemptID = first.OperationID, first.AttemptID
	put(first.ObjectKey(), a)
	put(second.ObjectKey(), a)
	tracks := db.NewTrackRepository(firstDB)
	commit := func(in db.PrivateImportIntent) *db.PrivateImportReceipt {
		t.Helper()
		r, err := processor.CommitStoredPrivateImport(ctx, tracks, objects, in)
		if err != nil || r == nil || r.OwnerID != in.OwnerID || r.OperationID != in.OperationID || r.SHA256 != in.SHA256 || r.ByteLength != in.ByteLength || r.TrackID <= 0 || r.CommittedAt.IsZero() {
			t.Fatalf("invalid committed receipt %v, err=%v", r, err)
		}
		fixtures.receipts[[2]uuid.UUID{r.OwnerID, r.OperationID}] = r.TrackID
		return r
	}
	refuse := func(in db.PrivateImportIntent, expected error) {
		t.Helper()
		if r, err := processor.CommitStoredPrivateImport(ctx, tracks, objects, in); r != nil || !errors.Is(err, expected) {
			t.Fatalf("expected %v, got %v %v", expected, r, err)
		}
	}
	refuse(absent, processor.ErrPrivateImportBytes)
	put(absent.ObjectKey(), a)
	refuse(absent, processor.ErrPrivateImportBytes) // Equal length, wrong digest.
	if _, err := firstDB.ExecContext(ctx, `CREATE FUNCTION fixture_refuse_receipt() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'fixture refused receipt'; END$$;
		CREATE TRIGGER fixture_refuse_receipt BEFORE INSERT ON private_import_receipts FOR EACH ROW EXECUTE FUNCTION fixture_refuse_receipt()`); err != nil {
		t.Fatal(err)
	}
	registerDurableImportFaultCleanup(t, cleanupDB, `DROP TRIGGER IF EXISTS fixture_refuse_receipt ON private_import_receipts; DROP FUNCTION IF EXISTS fixture_refuse_receipt()`)
	if r, err := processor.CommitStoredPrivateImport(ctx, tracks, objects, first); r != nil || err == nil || !strings.Contains(err.Error(), "fixture refused receipt") {
		t.Fatalf("late receipt rollback fault: %v %v", r, err)
	}
	var leakedTrack, leakedMembership, leakedAnalysis, leakedReceipt bool
	if err := firstDB.QueryRowContext(ctx, `WITH owned_tracks AS (
		SELECT id FROM tracks WHERE private_owner_id=$1 OR storage_key=$3
	) SELECT EXISTS(SELECT 1 FROM owned_tracks),
		EXISTS(SELECT 1 FROM user_library WHERE user_id=$1),
		EXISTS(SELECT 1 FROM track_analysis WHERE track_id IN (SELECT id FROM owned_tracks)),
		EXISTS(SELECT 1 FROM private_import_receipts WHERE owner_id=$1 AND operation_id=$2)`,
		owner, first.OperationID, first.ObjectKey()).Scan(&leakedTrack, &leakedMembership, &leakedAnalysis, &leakedReceipt); err != nil || leakedTrack || leakedMembership || leakedAnalysis || leakedReceipt {
		t.Fatalf("atomic write rollback: track=%t membership=%t analysis=%t receipt=%t err=%v", leakedTrack, leakedMembership, leakedAnalysis, leakedReceipt, err)
	}
	if _, err := firstDB.ExecContext(ctx, `DROP TRIGGER fixture_refuse_receipt ON private_import_receipts; DROP FUNCTION fixture_refuse_receipt()`); err != nil {
		t.Fatal(err)
	}
	loser := newIntent(owner, a)
	put(loser.ObjectKey(), a)
	_, losingProof, err := tracks.ResolvePrivateImportCommit(ctx, loser)
	if err != nil || losingProof.Key != loser.ObjectKey() || losingProof.TrackID != 0 {
		t.Fatalf("not a pre-commit competing source: %+v %v", losingProof, err)
	}
	if data, err := fixtureReadObject(ctx, objects, losingProof.Key); err != nil || fixtureSHA256(data) != a.hash {
		t.Fatal("losing proof not bound to real bytes")
	}
	firstAck := commit(first) // Simulate losing the response after commit.
	if r, err := tracks.CommitVerifiedPrivateImport(ctx, loser, losingProof); r != nil || !errors.Is(err, db.ErrPrivateImportSourceChanged) {
		t.Fatalf("losing proof authorized winning canonical key: %v %v", r, err)
	}
	if err := objects.DeleteObject(ctx, loser.ObjectKey()); err != nil {
		t.Fatal(err)
	}
	put(loser.ObjectKey(), b)
	if r := commit(loser); r.TrackID != firstAck.TrackID {
		t.Fatal("same-owner duplicate did not coalesce onto the independently opened winner")
	}
	if receipt, err := tracks.GetPrivateImportReceipt(ctx, other, loser.OperationID); receipt != nil || !errors.Is(err, db.ErrPrivateImportNotFound) {
		t.Fatalf("foreign operation disclosed: %v %v", receipt, err)
	}
	secondAck := commit(second)
	if secondAck.TrackID == firstAck.TrackID || first.ObjectKey() == second.ObjectKey() {
		t.Fatal("second owner attached to first account custody")
	}
	if _, err := db.NewLibraryRepository(firstDB).AddTrackToLibrary(ctx, other, firstAck.TrackID); !errors.Is(err, db.ErrTrackNotFound) {
		t.Fatalf("foreign numeric membership admitted: %v", err)
	}
	if err := db.NewLibraryRepository(firstDB).RemoveTrackFromLibrary(ctx, owner, firstAck.TrackID); err != nil {
		t.Fatal(err)
	}
	if err := firstDB.Close(); err != nil {
		t.Fatal(err)
	}

	newDB := openPrivateImportFixtureDB(t, ctx)
	tracks = db.NewTrackRepository(newDB)
	if r, err := tracks.GetPrivateImportReceipt(ctx, owner, first.OperationID); err != nil || r == nil || *r != *firstAck {
		t.Fatalf("new pool did not recover identical committed receipt: %v %v", r, err)
	}
	if r := commit(first); *r != *firstAck {
		t.Fatal("idempotent receipt changed")
	}
	assertMember := func(want bool) {
		t.Helper()
		var member bool
		if err := newDB.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM user_library WHERE user_id=$1 AND track_id=$2)`, owner, firstAck.TrackID).Scan(&member); err != nil || member != want {
			t.Fatalf("membership=%t want %t: %v", member, want, err)
		}
	}
	assertMember(false)
	changed := first
	changed.Title += " changed"
	refuse(changed, db.ErrPrivateImportIntentConflict)
	changed.OperationID = uuid.New()
	refuse(changed, db.ErrPrivateImportMetadataReview)
	reattach := newIntent(owner, a)
	if ack := commit(reattach); ack.TrackID != firstAck.TrackID {
		t.Fatal("deliberate re-add allocated a new track")
	}
	assertMember(true)
	analysis := db.NewAnalysisRepository(newDB)
	loadStatus := func(id int64, want string) *db.TrackAnalysis {
		t.Helper()
		row, err := analysis.GetByTrackID(ctx, id)
		if err != nil || row == nil || row.Status != want {
			t.Fatalf("track %d want %s: %+v %v", id, want, row, err)
		}
		return row
	}
	loadStatus(firstAck.TrackID, db.AnalysisStatusStale)
	loadStatus(secondAck.TrackID, db.AnalysisStatusStale)

	const health = `{"status":"healthy","analyzer":"fixture","analyzer_version":"fixture-v1","tempo_model":"test","key_model":"test","spectral_provenance":"test","spectral_channel_set":"bands3-v1"}`
	const result = `{"schema_version":1,"summary":{"bpm":123},"artifacts":{},"provenance":{"analyzer":"fixture","analyzer_verſion":" fixture-v1 ","model":{"source":"generated"},"analyzer_verſion_note":"preserved"}}`
	type observation struct {
		wire      map[string]json.RawMessage
		key, hash string
		size      int
	}
	var mu sync.Mutex
	seen := make(map[int64][]observation)
	held, allow := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(allow) }) }
	defer release()
	pending, allowStart := make(chan struct{}), make(chan struct{})
	var startOnce sync.Once
	start := func() { startOnce.Do(func() { close(allowStart) }) }
	defer start()
	startFence := fixtureHeldPrivateAnalysisStart{analysis, secondAck.TrackID, pending, allowStart}
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodGet && req.URL.Path == "/health" {
			_, _ = io.WriteString(w, health)
			return
		}
		var request map[string]json.RawMessage
		var id int64
		var key string
		if req.Method != http.MethodPost || req.URL.Path != "/analyze" || json.NewDecoder(req.Body).Decode(&request) != nil || json.Unmarshal(request["track_id"], &id) != nil || json.Unmarshal(request["storage_key"], &key) != nil {
			t.Error("bad analyzer request")
			w.WriteHeader(400)
			return
		}
		data, err := fixtureReadObject(req.Context(), objects, key)
		if err != nil {
			t.Errorf("analyzer failed to open the wire-named object: %v", err)
			w.WriteHeader(500)
			return
		}
		mu.Lock()
		seen[id] = append(seen[id], observation{request, key, fixtureSHA256(data), len(data)})
		mu.Unlock()
		if id == secondAck.TrackID {
			select {
			case held <- struct{}{}:
			case <-req.Context().Done():
				return
			}
			select {
			case <-allow:
			case <-req.Context().Done():
				return
			}
		}
		_, _ = io.WriteString(w, result)
	}))
	t.Cleanup(service.Close)
	newRuntime := func() (*processor.Processor, *analyzer.ServiceClient) {
		t.Helper()
		client, err := analyzer.NewServiceClient(analyzer.ServiceConfig{Enabled: true, BaseURL: service.URL, Timeout: 3 * time.Second})
		if err != nil {
			t.Fatal(err)
		}
		p := processor.New(&processor.ProcessorConfig{TrackRepo: tracks, LibraryRepo: db.NewLibraryRepository(newDB), AnalysisRepo: startFence, AnalyzerClient: client, Storage: objects, RequireAnalyzerIdentity: true})
		t.Cleanup(func() {
			stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := p.Shutdown(stop); err != nil {
				workersStopped = false
				t.Error(err)
			}
		})
		return p, client
	}
	startup := func(p *processor.Processor, client *analyzer.ServiceClient) {
		t.Helper()
		if _, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis); err != nil {
			t.Fatalf("private startup: %v", err)
		}
		report, err := reconcileAnalyzerVersion(ctx, client, analysis, tracks, p)
		if err != nil || report.Analyzer != "fixture" || report.AnalyzerVersion != "fixture-v1" || report.Queued != 0 {
			t.Fatalf("wrong startup/identity owner: %+v %v", report, err)
		}
	}
	stopped, version := newRuntime()
	if n, err := stopped.DrainPrivateImportAnalysis(ctx); n != 0 || err != nil {
		t.Fatalf("unversioned private work admitted: %d %v", n, err)
	}
	startup(stopped, version)
	// The queue has no SQL ownership. A real worker-side claim fault rolls
	// back without consuming the obligation or sending any analyzer request.
	if _, err := newDB.ExecContext(ctx, `CREATE SEQUENCE fixture_claim_attempts;
		CREATE FUNCTION fixture_refuse_claim() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN
			PERFORM nextval('fixture_claim_attempts'); RAISE EXCEPTION 'fixture refused claim'; END$$;
		CREATE TRIGGER fixture_refuse_claim BEFORE UPDATE ON track_analysis FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION fixture_refuse_claim()`); err != nil {
		t.Fatal(err)
	}
	registerDurableImportFaultCleanup(t, cleanupDB, `DROP TRIGGER IF EXISTS fixture_refuse_claim ON track_analysis; DROP FUNCTION IF EXISTS fixture_refuse_claim(); DROP SEQUENCE IF EXISTS fixture_claim_attempts`)
	if n, err := stopped.DrainPrivateImportAnalysis(ctx); n != 2 || err != nil {
		t.Fatalf("expected two durable intents to reach the worker: %d %v", n, err)
	}
	if err := stopped.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	var attempts int
	if err := newDB.QueryRowContext(ctx, `SELECT last_value FROM fixture_claim_attempts WHERE is_called`).Scan(&attempts); err != nil || attempts != 2 {
		t.Fatalf("expected two real PostgreSQL claim faults: %d %v", attempts, err)
	}
	loadStatus(firstAck.TrackID, db.AnalysisStatusStale)
	loadStatus(secondAck.TrackID, db.AnalysisStatusStale)
	if _, err := newDB.ExecContext(ctx, `DROP TRIGGER fixture_refuse_claim ON track_analysis; DROP FUNCTION fixture_refuse_claim(); DROP SEQUENCE fixture_claim_attempts`); err != nil {
		t.Fatal(err)
	}
	if n, err := stopped.DrainPrivateImportAnalysis(ctx); n != 0 || err == nil || !strings.Contains(err.Error(), "schedule private analysis") {
		t.Fatalf("expected real closed queue to refuse the intents: %d %v", n, err)
	}
	loadStatus(firstAck.TrackID, db.AnalysisStatusStale)
	loadStatus(secondAck.TrackID, db.AnalysisStatusStale)
	failed := uuid.New()
	firstSource := db.PrivateImportSource{TrackID: firstAck.TrackID, Key: first.ObjectKey(), SHA256: first.SHA256, ByteLength: first.ByteLength, DurationMs: first.DurationMs}
	requirePrivateClaim(t, ctx, analysis, firstSource, failed, "fixture", "fixture-v1", true)
	if err := analysis.MarkFailed(ctx, firstAck.TrackID, "fixture terminal failure", fixtureClaimProvenance(failed, "fixture", "fixture-v1")); err != nil {
		t.Fatal(err)
	}
	if _, err := newDB.ExecContext(ctx, `UPDATE track_analysis SET completed_at = NOW() - INTERVAL '60 seconds' WHERE track_id=$1`, firstAck.TrackID); err != nil {
		t.Fatal(err)
	}
	old := uuid.New()
	canonical := db.PrivateImportSource{TrackID: secondAck.TrackID, Key: second.ObjectKey(), SHA256: second.SHA256, ByteLength: second.ByteLength, DurationMs: second.DurationMs}
	requirePrivateClaim(t, ctx, analysis, canonical, old, "fixture", "fixture-v1", true)
	if _, err := newDB.ExecContext(ctx, `UPDATE track_analysis SET requested_at = NOW() - INTERVAL '31 minutes' WHERE track_id=$1`, secondAck.TrackID); err != nil {
		t.Fatal(err)
	}

	missing := newIntent(other, b)
	put(missing.ObjectKey(), b)
	missingAck := commit(missing)
	if err := objects.DeleteObject(ctx, missing.ObjectKey()); err != nil {
		t.Fatal(err)
	}
	sibling := newIntent(other, b)
	put(sibling.ObjectKey(), b)
	refuse(sibling, processor.ErrPrivateImportBytes)
	worker, client := newRuntime()
	startup(worker, client)
	peer, peerClient := newRuntime()
	startup(peer, peerClient)
	track, err := tracks.GetByID(ctx, firstAck.TrackID)
	if err != nil || !track.Private {
		t.Fatalf("private ID read: %v %v", track, err)
	}
	if repair, err := worker.RepairMetadata(ctx, track, processor.MetadataRepairOptions{Force: true}); err != nil || repair.Reason != "private_track" {
		t.Fatalf("forced metadata repair reached matcher gate: %+v %v", repair, err)
	}
	type drainOutcome struct {
		queued int
		err    error
	}
	goDrain, done := make(chan struct{}), make(chan drainOutcome, 2)
	for _, p := range []*processor.Processor{worker, peer} {
		go func() {
			<-goDrain
			n, err := p.DrainPrivateImportAnalysis(ctx)
			done <- drainOutcome{n, err}
		}()
	}
	close(goDrain)
	x, y := <-done, <-done
	if x.queued+y.queued < 3 || x.queued+y.queued > 6 || x.err != nil || y.err != nil {
		t.Fatalf("concurrent drains did not find failed/aged/missed obligations: %+v %+v", x, y)
	}
	// Local hints may coexist in different runtimes. The worker claims are
	// contested in SQL, and the analyzer wire below must see each source once.
	select {
	case <-pending:
	case <-ctx.Done():
		t.Fatal("replacement worker did not reach its held start transition")
	}
	loadStatus(secondAck.TrackID, db.AnalysisStatusPending)
	retired := fixtureClaimProvenance(old, "fixture", "fixture-v1")
	if err := analysis.MarkAnalyzing(ctx, secondAck.TrackID, retired); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("retired token started the real pending replacement: %v", err)
	}
	loadStatus(secondAck.TrackID, db.AnalysisStatusPending)
	start()
	select {
	case <-held:
	case <-ctx.Done():
		t.Fatal("replacement worker did not reach held analyzer wire")
	}
	loadStatus(secondAck.TrackID, db.AnalysisStatusAnalyzing)
	if err := analysis.MarkFailed(ctx, secondAck.TrackID, "retired claim", retired); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("late failure could retire replacement claim: %v", err)
	}
	if err := analysis.StoreResult(ctx, secondAck.TrackID, db.AnalysisResult{
		SummaryJSON: json.RawMessage(`{"bpm":300}`), ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1"}`),
		Analyzer: "fixture", AnalyzerVersion: "fixture-v1", DispatchToken: old.String(),
	}); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("late result could replace a current same-version claim: %v", err)
	}
	release()
	// Entire existing URL worker path with its own local file fetch and storage Put.
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: owner.String(), URL: "file://" + a.path, SourceType: "local-fixture", Title: first.Title + " " + strings.ReplaceAll(first.OperationID.String(), "-", ""), Artist: first.Artist, Album: first.Album, DurationMs: int(first.DurationMs)}
	fixtures.publicKey = "tracks/local-fixture/" + job.ID + ".mp3"
	if err := worker.Process(ctx, job, func(int) {}); err != nil || job.TrackID == nil || *job.TrackID == firstAck.TrackID || *job.TrackID == secondAck.TrackID {
		t.Fatalf("URL ingest crossed private byte dedupe: %+v %v", job.TrackID, err)
	}
	if err := worker.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	if err := peer.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	beforeDedupe := loadStatus(firstAck.TrackID, db.AnalysisStatusAnalyzed)
	if r := commit(newIntent(owner, a)); r.TrackID != firstAck.TrackID {
		t.Fatal("analyzed canonical track was not reused")
	}
	if after := loadStatus(firstAck.TrackID, db.AnalysisStatusAnalyzed); !after.UpdatedAt.Equal(beforeDedupe.UpdatedAt) {
		t.Fatal("same-owner dedupe reset a healthy analysis row")
	}
	for _, ack := range []*db.PrivateImportReceipt{firstAck, secondAck} {
		row := loadStatus(ack.TrackID, db.AnalysisStatusAnalyzed)
		fields := assertFixtureResultIdentity(t, row.ProvenanceJSON, "fixture", "fixture-v1")
		var model map[string]string
		if err := json.Unmarshal(fields["model"], &model); err != nil || model["source"] != "generated" ||
			string(fields["analyzer_verſion_note"]) != `"preserved"` || fields["analyzer_verſion"] != nil {
			t.Fatalf("database lost result provenance or retained alias: %s %v", row.ProvenanceJSON, err)
		}
		if !bytes.Contains(row.SummaryJSON, []byte(`123`)) || bytes.Contains(row.ProvenanceJSON, []byte("dispatch_token")) {
			t.Fatalf("result/claim provenance boundary: %s %s", row.SummaryJSON, row.ProvenanceJSON)
		}
	}
	row := loadStatus(missingAck.TrackID, db.AnalysisStatusFailed)
	if !row.Error.Valid || row.Error.String != processor.ErrPrivateImportBytes.Error() {
		t.Fatalf("missing canonical object did not fail closed: %+v", row.Error)
	}
	if r := commit(missing); *r != *missingAck {
		t.Fatal("analysis failure changed committed receipt")
	}
	loadStatus(*job.TrackID, db.AnalysisStatusAnalyzed)
	assertPrivateAnalysisReadback(t, ctx, newDB, owner, other, firstAck.TrackID)
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 3 || len(seen[missingAck.TrackID]) != 0 {
		t.Fatalf("unexpected analyzer tracks: %v", seen)
	}
	assertWire := func(id int64) observation {
		t.Helper()
		items := seen[id]
		if len(items) != 1 || items[0].hash != a.hash || items[0].size != len(a.data) {
			t.Fatalf("analyzer did not open exact bytes once: %v", items)
		}
		wire, _ := json.Marshal(items[0].wire)
		t.Logf("wire track=%d key=%s opened_hash=%s opened_bytes=%d request=%s", id, items[0].key, items[0].hash, items[0].size, wire)
		return items[0]
	}
	for _, spec := range []struct {
		id  int64
		key string
	}{{firstAck.TrackID, first.ObjectKey()}, {secondAck.TrackID, second.ObjectKey()}} {
		item := assertWire(spec.id)
		if item.key != spec.key || strings.Contains(item.key, owner.String()) || strings.Contains(item.key, other.String()) ||
			len(item.wire) != 6 || string(item.wire["duration_ms"]) != strconv.Itoa(int(a.ms)) {
			t.Fatalf("wrong private wire identity: %+v", item)
		}
		for _, field := range []string{"track_id", "storage_key", "schema_version", "duration_ms", "expected_analyzer", "expected_analyzer_version"} {
			if item.wire[field] == nil {
				t.Fatalf("missing wire field %s", field)
			}
		}
	}
	publicWire := assertWire(*job.TrackID).wire
	for field, value := range map[string]string{"source_url": job.URL, "source_type": job.SourceType, "title": job.Title, "artist": job.Artist} {
		var actual string
		if err := json.Unmarshal(publicWire[field], &actual); err != nil || actual != value {
			t.Fatalf("URL path lost field %s: %q %v", field, actual, err)
		}
	}
}

func fixtureReadObject(ctx context.Context, objects fixtureObjectReader, key string) ([]byte, error) {
	body, info, err := objects.GetObject(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("open fixture object: %w", err)
	}
	defer body.Close()
	data, err := io.ReadAll(io.LimitReader(body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read fixture object: %w", err)
	}
	if info == nil || int64(len(data)) != info.Size {
		return nil, errors.New("could not read full fixture object")
	}
	return data, nil
}

func assertPrivateAnalysisReadback(t *testing.T, ctx context.Context, database *db.DB, owner, other uuid.UUID, track int64) {
	t.Helper()
	secret := uuid.NewString() + uuid.NewString()
	sessions := auth.NewService(nil, nil, secret)
	router := api.NewRouterWithConfig(&api.RouterConfig{
		AuthService: sessions, AuthHandlers: auth.NewHandlers(sessions),
		AnalysisHandlers: api.NewAnalysisHandlersWithTrackRepo(db.NewAnalysisRepository(database), db.NewLibraryRepository(database), db.NewTrackRepository(database)),
	})
	request := func(user uuid.UUID, id int64) *httptest.ResponseRecorder {
		t.Helper()
		token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/v1/tracks/%d/analysis", id), nil).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}
	visible := request(owner, track)
	var got api.AnalysisResponse
	if err := json.Unmarshal(visible.Body.Bytes(), &got); visible.Code != http.StatusOK || err != nil || got.TrackID != track || got.Status != db.AnalysisStatusAnalyzed || !bytes.Contains(got.Summary, []byte(`123`)) {
		t.Fatalf("ordinary owner analysis readback: HTTP %d %+v %v", visible.Code, got, err)
	}
	foreign, unknown := request(other, track), request(other, 1<<60)
	if foreign.Code != http.StatusNotFound || unknown.Code != foreign.Code || unknown.Body.String() != foreign.Body.String() {
		t.Fatalf("foreign/absent analysis distinguished: %d %d", foreign.Code, unknown.Code)
	}
}

type fixtureObjectReader interface {
	GetObject(context.Context, string) (io.ReadCloser, *storage.ObjectInfo, error)
}

type fixtureObjectReadFunc func() (io.ReadCloser, *storage.ObjectInfo, error)

func (f fixtureObjectReadFunc) GetObject(context.Context, string) (io.ReadCloser, *storage.ObjectInfo, error) {
	return f()
}

type fixturePartialReader struct{ err error }

func (r fixturePartialReader) Read(p []byte) (int, error) {
	p[0] = 'x'
	return 1, r.err
}

func TestPrivateAnalysisFixturePreservesObjectReadErrors(t *testing.T) {
	fault := errors.New("fixture IO sentinel")
	for _, tt := range []struct {
		name, context string
		open          fixtureObjectReadFunc
		want          error
	}{
		{"GetObject", "open fixture object", func() (io.ReadCloser, *storage.ObjectInfo, error) { return nil, nil, fault }, fault},
		{"PartialRead", "read fixture object", func() (io.ReadCloser, *storage.ObjectInfo, error) {
			return io.NopCloser(fixturePartialReader{fault}), &storage.ObjectInfo{Size: 2}, nil
		}, fault},
		{"SizeMismatch", "could not read full fixture object", func() (io.ReadCloser, *storage.ObjectInfo, error) {
			return io.NopCloser(strings.NewReader("x")), &storage.ObjectInfo{Size: 2}, nil
		}, nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			data, err := fixtureReadObject(context.Background(), tt.open, "fixture")
			if data != nil || err == nil || !strings.Contains(err.Error(), tt.context) || (tt.want != nil && !errors.Is(err, tt.want)) {
				t.Fatalf("fixture read error lost its cause or operation: %q %v", data, err)
			}
		})
	}
}

func privateAnalysisFixtureDB(t *testing.T, ctx context.Context) (*db.DB, *db.TrackRepository, *db.AnalysisRepository) {
	t.Helper()
	database := openPrivateImportFixtureDB(t, ctx)
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	return database, db.NewTrackRepository(database), db.NewAnalysisRepository(database)
}

func fixtureCanonicalIntent(owner uuid.UUID, audio privateFixtureAudio) db.PrivateImportIntent {
	return db.PrivateImportIntent{OwnerID: owner, OperationID: uuid.New(), AttemptID: uuid.New(), SHA256: audio.hash, ByteLength: int64(len(audio.data)), DurationMs: audio.ms, Title: "Synthetic private analysis fixture"}
}

func fixtureSQLPrivateSource(t *testing.T, ctx context.Context, database *db.DB, tracks *db.TrackRepository) db.PrivateImportSource {
	t.Helper()
	data := []byte("synthetic facts for SQL, never opened by an analyzer")
	owner := seedPrivateImportUser(t, database, ctx)
	in := fixtureCanonicalIntent(owner, privateFixtureAudio{data: data, hash: fixtureSHA256(data), ms: 500})
	_, source, err := tracks.ResolvePrivateImportCommit(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := tracks.CommitVerifiedPrivateImport(ctx, in, source)
	if err != nil {
		t.Fatal(err)
	}
	source.TrackID = receipt.TrackID
	t.Cleanup(func() { cleanupPrivateAnalysisReceipt(t, database, receipt) })
	return source
}

func cleanupPrivateAnalysisReceipt(t *testing.T, database *db.DB, receipt *db.PrivateImportReceipt) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := database.ExecContext(ctx, `DELETE FROM private_import_receipts WHERE owner_id=$1 AND operation_id=$2 AND track_id=$3`, receipt.OwnerID, receipt.OperationID, receipt.TrackID); err != nil {
		t.Error(err)
		return
	}
	if _, err := database.ExecContext(ctx, `DELETE FROM tracks WHERE id=$1 AND private_owner_id=$2`, receipt.TrackID, receipt.OwnerID); err != nil {
		t.Error(err)
		return
	}
	if _, err := database.ExecContext(ctx, `DELETE FROM users WHERE id=$1`, receipt.OwnerID); err != nil {
		t.Error(err)
	}
}

func fixtureClaimProvenance(token uuid.UUID, name, version string) json.RawMessage {
	p, _ := json.Marshal(map[string]string{"dispatch_token": token.String(), "expected_analyzer": name, "expected_analyzer_version": version})
	return p
}

func requirePrivateClaim(t *testing.T, ctx context.Context, analysis *db.AnalysisRepository, source db.PrivateImportSource, token uuid.UUID, name, version string, want bool) {
	t.Helper()
	if got, err := analysis.ClaimPrivateImportAnalysis(ctx, source, token, name, version); got != want || err != nil {
		t.Fatalf("private claim granted=%t want %t: %v", got, want, err)
	}
}

func TestPrivateAnalysisClaimCutoffsIgnoreManualOverrides(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	for _, tt := range []struct {
		phase, timestamp, cutoff string
	}{
		{"pending", "requested_at", "30 minutes"},
		{"analyzing", "started_at", "30 minutes"},
		{"failed", "completed_at", "30 seconds"},
	} {
		t.Run(tt.phase, func(t *testing.T) {
			const name, version = "lease-fixture", "same-version"
			source := fixtureSQLPrivateSource(t, ctx, database, tracks)
			old, replacement := uuid.New(), uuid.New()
			retired := fixtureClaimProvenance(old, name, version)
			requirePrivateClaim(t, ctx, analysis, source, old, name, version, true)
			if tt.phase != "pending" {
				if err := analysis.MarkAnalyzing(ctx, source.TrackID, retired); err != nil {
					t.Fatal(err)
				}
			}
			if tt.phase == "failed" {
				if err := analysis.MarkFailed(ctx, source.TrackID, "fixture failure", retired); err != nil {
					t.Fatal(err)
				}
			}
			age := func(expired bool) {
				t.Helper()
				delta := " + INTERVAL '10 seconds'"
				if expired {
					delta = " - INTERVAL '10 seconds'"
				}
				assign := tt.timestamp + " = NOW() - $2::interval" + delta
				// Earlier claim phases are older still; only the current phase may decide.
				if tt.phase != "pending" {
					assign += ", requested_at = NOW() - INTERVAL '60 minutes'"
				}
				if tt.phase == "failed" {
					assign += ", started_at = NOW() - INTERVAL '60 minutes'"
				}
				if !expired {
					assign += ", updated_at = NOW() - INTERVAL '60 minutes'"
				}
				if _, err := database.ExecContext(ctx, "UPDATE track_analysis SET "+assign+" WHERE track_id=$1", source.TrackID, tt.cutoff); err != nil {
					t.Fatal(err)
				}
			}
			age(false)
			if granted, err := analysis.ClaimPrivateImportAnalysis(ctx, source, replacement, name, version); err != nil {
				t.Fatal(err)
			} else if granted {
				t.Errorf("fresh %s phase incorrectly aged out with stale updated_at", tt.phase)
				// Restore the intended phase under the granted token so the separate
				// manual-override rejection witness still exercises real SQL.
				old, replacement = replacement, uuid.New()
				retired = fixtureClaimProvenance(old, name, version)
				if tt.phase != "pending" {
					if err := analysis.MarkAnalyzing(ctx, source.TrackID, retired); err != nil {
						t.Fatal(err)
					}
				}
				if tt.phase == "failed" {
					if err := analysis.MarkFailed(ctx, source.TrackID, "fixture failure", retired); err != nil {
						t.Fatal(err)
					}
				}
			}
			age(true)
			manual, err := analysis.SetOverrides(ctx, source.TrackID, json.RawMessage(`{"key":"Dm"}`), 0)
			if err != nil || manual.Status != tt.phase || !manual.ManualOverrideUpdatedAt.Valid || !manual.UpdatedAt.Equal(manual.ManualOverrideUpdatedAt.Time) || time.Since(manual.UpdatedAt) > 5*time.Second {
				t.Fatalf("override did not refresh its own published state: %+v %v", manual, err)
			}
			if granted, err := analysis.ClaimPrivateImportAnalysis(ctx, source, replacement, name, version); !granted || err != nil {
				t.Fatalf("expired %s phase stranded after manual override: granted=%t %v", tt.phase, granted, err)
			}
			assertState := func(status, token string) {
				t.Helper()
				var gotStatus, gotToken string
				if err := database.QueryRowContext(ctx, `SELECT status, dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&gotStatus, &gotToken); gotStatus != status || gotToken != token || err != nil {
					t.Fatalf("claim owner state=%s %s want %s %s: %v", gotStatus, gotToken, status, token, err)
				}
			}
			assertState(db.AnalysisStatusPending, replacement.String())
			if err := analysis.MarkAnalyzing(ctx, source.TrackID, retired); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
				t.Fatalf("old token moved the pending replacement to analyzing: %v", err)
			}
			assertState(db.AnalysisStatusPending, replacement.String())
			if err := analysis.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(replacement, name, version)); err != nil {
				t.Fatalf("replacement token could not start: %v", err)
			}
			assertState(db.AnalysisStatusAnalyzing, replacement.String())
			if err := analysis.MarkFailed(ctx, source.TrackID, "retired worker", retired); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
				t.Fatalf("retired same-version failure affected replacement: %v", err)
			}
			result := db.AnalysisResult{
				SummaryJSON: json.RawMessage(`{"bpm":300}`), ProvenanceJSON: json.RawMessage(`{"analyzer":"lease-fixture","analyzer_version":"same-version"}`),
				Analyzer: name, AnalyzerVersion: version, DispatchToken: old.String(),
			}
			if err := analysis.StoreResult(ctx, source.TrackID, result); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
				t.Fatalf("retired same-version result affected replacement: %v", err)
			}
			assertState(db.AnalysisStatusAnalyzing, replacement.String())
			result.DispatchToken, result.SummaryJSON = replacement.String(), json.RawMessage(`{"bpm":123}`)
			if err := analysis.StoreResult(ctx, source.TrackID, result); err != nil {
				t.Fatal(err)
			}
			row, err := analysis.GetByTrackID(ctx, source.TrackID)
			if err != nil || row.Status != db.AnalysisStatusAnalyzed || !bytes.Contains(row.SummaryJSON, []byte(`123`)) ||
				!bytes.Equal(row.OverridesJSON, manual.OverridesJSON) || row.ManualOverrideRevision != 1 || bytes.Contains(row.ProvenanceJSON, []byte("dispatch_token")) {
				t.Fatalf("current result or manual override did not survive: %+v %v", row, err)
			}
		})
	}
}

func TestPrivateAnalysisClaimCannotReplaceConflictingIdentityFence(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	source := fixtureSQLPrivateSource(t, ctx, database, tracks)
	const name, older, newer = "rolling-fixture", "opaque-a", "opaque-z"
	oldToken, newToken := uuid.New(), uuid.New()
	requirePrivateClaim(t, ctx, analysis, source, oldToken, name, older, true)
	if _, err := analysis.ReconcilePrivateAnalyzerAtStartup(ctx, func(context.Context) (string, string, error) { return name, newer, nil }); err != nil {
		t.Fatal(err)
	}
	assertFence := func(want string) {
		t.Helper()
		var status, expected string
		var token sql.NullString
		if err := database.QueryRowContext(ctx, `SELECT status, provenance_json->>'expected_analyzer_version', dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&status, &expected, &token); err != nil || status != db.AnalysisStatusStale || expected != want || token.Valid {
			t.Fatalf("expected unowned stale fence %q, got %s %q %+v: %v", want, status, expected, token, err)
		}
	}
	assertFence(newer)
	for _, version := range []string{older, newer} {
		candidates, err := tracks.GetPrivateImportAnalysisCandidates(ctx, name, version, 16)
		found := false
		for _, candidate := range candidates {
			found = found || candidate.TrackID == source.TrackID
		}
		if err != nil || found != (version == newer) {
			t.Fatalf("candidate selection disagrees with persisted identity fence for %q: found=%t %v", version, found, err)
		}
	}
	requirePrivateClaim(t, ctx, analysis, source, oldToken, name, older, false)
	assertFence(newer)
	// Regular startup reconciliation after endpoint convergence can also re-fence
	// an already-stale pinned row that never ran during the intermediate rollout.
	const final = "opaque-b"
	if _, err := analysis.MarkStaleByAnalyzerVersion(ctx, name, final); err != nil {
		t.Fatal(err)
	}
	assertFence(newer) // Repeated ordinary scans must not re-pin stale rows.
	if _, err := analysis.ReconcilePrivateAnalyzerAtStartup(ctx, func(context.Context) (string, string, error) { return name, final, nil }); err != nil {
		t.Fatal(err)
	}
	assertFence(final)
	requirePrivateClaim(t, ctx, analysis, source, newToken, name, final, true)
	// A peer may still be finishing its ordinary startup scan with an
	// earlier health snapshot. It has no private fence authority now.
	if _, err := analysis.MarkStaleByAnalyzerVersion(ctx, name, older); err != nil {
		t.Fatal(err)
	}
	var status, expected string
	var token sql.NullString
	if err := database.QueryRowContext(ctx, `SELECT status, provenance_json->>'expected_analyzer_version', dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&status, &expected, &token); err != nil || status != db.AnalysisStatusPending || expected != final || !token.Valid || token.String != newToken.String() {
		t.Fatalf("repeated startup scan overwrote a newer pending fence: %s %q %+v %v", status, expected, token, err)
	}
	if err := analysis.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(newToken, name, final)); err != nil {
		t.Fatal(err)
	}
	if err := analysis.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(oldToken, name, older)); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("older startup work resumed after a newer fence: %v", err)
	}
}

// Use the production HTTP client and startup caller. The first server response
// captures its identity before the test releases delivery to backend A.
func privateAnalysisStartupClient(t *testing.T, handler func(http.ResponseWriter, *http.Request)) *analyzer.ServiceClient {
	t.Helper()
	service := httptest.NewServer(http.HandlerFunc(handler))
	t.Cleanup(service.Close)
	client, err := analyzer.NewServiceClient(analyzer.ServiceConfig{Enabled: true, BaseURL: service.URL})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func writePrivateAnalysisHealth(w http.ResponseWriter, name, version string) {
	_, _ = fmt.Fprintf(w, `{"status":"healthy","analyzer":%q,"analyzer_version":%q,"tempo_model":"test","key_model":"test","spectral_provenance":"test","spectral_channel_set":"bands3-v1"}`, name, version)
}

func startupMigrationFixture(t *testing.T) (*db.DB, *db.DB) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	database := openPrivateImportFixtureDB(t, ctx)
	migration := openPrivateImportFixturePool(t, ctx, true)
	var timeout string
	if err := migration.QueryRowContext(ctx, `SHOW statement_timeout`).Scan(&timeout); err != nil || timeout != "8s" {
		t.Fatalf("migration peer statement_timeout=%q: %v", timeout, err)
	}
	if err := migration.Migrate(); err != nil {
		t.Fatalf("initialize guarded migration fixture: %v", err)
	}
	post, cancelPost := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelPost()
	if err := database.CheckDatabaseNotProtected(post); err != nil {
		t.Fatal(err)
	}
	return database, migration
}

func awaitStartupMigrationWait(t *testing.T, ctx context.Context, read func() (string, error)) string {
	t.Helper()
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	for {
		wait, err := read()
		if err != nil {
			t.Fatal(err)
		}
		if wait != "" {
			return wait
		}
		select {
		case <-tick.C:
		case <-ctx.Done():
			t.Fatal("migration did not reach the PostgreSQL wait boundary")
		}
	}
}

func tryPrivateStartupHealth(ctx context.Context, database *db.DB, client *analyzer.ServiceClient) (int64, error) {
	return db.NewAnalysisRepository(database).ReconcilePrivateAnalyzerAtStartup(ctx, func(ctx context.Context) (string, string, error) {
		info, err := client.Info(ctx)
		return info.Analyzer, info.AnalyzerVersion, err
	})
}

func TestPrivateAnalysisStartupDoesNotDeadlockPeerMigration(t *testing.T) {
	database, migration := startupMigrationFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 17*time.Second)
	defer cancel()
	// Remove one index from before the conflicting DDL and one at the receipt
	// lock. Independent readback must see both or neither, never a partial batch.
	if _, err := database.ExecContext(ctx, `DROP INDEX idx_users_email, idx_private_import_receipts_track`); err != nil {
		t.Fatal(err)
	}
	var restored bool
	t.Cleanup(func() {
		if !restored {
			if err := migration.Migrate(); err != nil {
				t.Errorf("restore fixture indexes: %v", err)
			}
		}
	})
	readSchema := func() (early, late bool, temp int) {
		t.Helper()
		if err := database.QueryRowContext(ctx, `SELECT to_regclass('idx_users_email') IS NOT NULL,
			to_regclass('idx_private_import_receipts_track') IS NOT NULL,
			(SELECT count(*) FROM pg_class WHERE relpersistence='t')`).Scan(&early, &late, &temp); err != nil {
			t.Fatal(err)
		}
		return early, late, temp
	}
	_, _, initialTemp := readSchema()
	sampled, hold := make(chan struct{}), make(chan struct{})
	release := sync.OnceFunc(func() { close(hold) })
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
		close(sampled)
		select {
		case <-hold:
			writePrivateAnalysisHealth(w, "migration-fence", "opaque-current")
		case <-req.Context().Done():
		}
	})
	var startupErr, migrationErr error
	var workers sync.WaitGroup
	defer func() { release(); cancel(); workers.Wait() }()
	workers.Go(func() { _, startupErr = tryPrivateStartupHealth(ctx, database, client) })
	awaitPrivateAnalysisStartupSignal(t, ctx, sampled)
	workers.Go(func() { migrationErr = migration.Migrate() })
	wait := awaitStartupMigrationWait(t, ctx, func() (string, error) {
		var got string
		err := database.QueryRowContext(ctx, `WITH startup AS (
			SELECT pid FROM pg_locks WHERE relation='private_import_receipts'::regclass
			AND mode='ShareRowExclusiveLock' AND granted
		) SELECT COALESCE((SELECT CASE WHEN wl.locktype='advisory' THEN 'schema advisory key'
			ELSE 'receipts ShareLock with tracks AccessExclusiveLock' END
			FROM pg_locks wl JOIN pg_stat_activity m USING(pid) WHERE m.application_name=$1
			AND m.datname=current_database() AND NOT wl.granted
			AND EXISTS (SELECT 1 FROM startup WHERE pid=ANY(pg_blocking_pids(wl.pid)))
			AND ((wl.locktype='advisory' AND wl.objsubid=1
			      AND ((wl.classid::bigint << 32) | wl.objid::bigint)=hashtextextended('open_music_player_schema_migrate',0))
			 OR (wl.relation='private_import_receipts'::regclass AND wl.mode='ShareLock'
			     AND EXISTS (SELECT 1 FROM pg_locks tr WHERE tr.pid=wl.pid AND tr.granted
			         AND tr.relation='tracks'::regclass AND tr.mode='AccessExclusiveLock'))) LIMIT 1), '')`, privateImportMigrationFixtureApplication).Scan(&got)
		return got, err
	})
	t.Logf("real Migrate blocked on %s while startup held the health response", wait)
	if early, late, temp := readSchema(); early || late || temp != initialTemp {
		t.Fatalf("partial schema state visible while Migrate waits: early=%t late=%t temp=%d", early, late, temp)
	}
	release()
	workers.Wait()
	early, late, temp := readSchema()
	restored = early && late
	if early != late || temp != initialTemp || restored != (migrationErr == nil) {
		t.Errorf("migration did not settle atomically: early=%t late=%t temp=%d migration=%v", early, late, temp, migrationErr)
	}
	if startupErr != nil || migrationErr != nil {
		state := func(err error) string {
			var pgErr *pq.Error
			if errors.As(err, &pgErr) {
				return string(pgErr.Code)
			}
			return "none"
		}
		t.Fatalf("startup and Migrate must both succeed: startup=%v (SQLSTATE %s); migration=%v (SQLSTATE %s)", startupErr, state(startupErr), migrationErr, state(migrationErr))
	}
	if wait != "schema advisory key" {
		t.Fatalf("a successful migration still took schema relation locks during the observation: %s", wait)
	}
}

func TestPrivateAnalysisStartupRefusesBeforeHealthWhilePeerMigrates(t *testing.T) {
	database, migration := startupMigrationFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 17*time.Second)
	defer cancel()
	tracks := db.NewTrackRepository(database)
	source := fixtureSQLPrivateSource(t, ctx, database, tracks)
	analysis := db.NewAnalysisRepository(database)
	const name, old, current = "migration-reverse", "opaque-old", "opaque-current"
	requirePrivateClaim(t, ctx, analysis, source, uuid.New(), name, old, true)
	blocker, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	defer func() { _ = blocker.Rollback(); cancel(); workers.Wait() }()
	if _, err := blocker.ExecContext(ctx, `LOCK TABLE tracks IN ACCESS SHARE MODE`); err != nil {
		t.Fatal(err)
	}
	var blockerPID int
	if err := blocker.QueryRowContext(ctx, `SELECT pg_backend_pid()`).Scan(&blockerPID); err != nil {
		t.Fatal(err)
	}
	migrated := make(chan error, 1)
	workers.Go(func() { migrated <- migration.Migrate() })
	wait := awaitStartupMigrationWait(t, ctx, func() (string, error) {
		var got string
		err := database.QueryRowContext(ctx, `WITH peers AS (
			SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND application_name=$1
		) SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_locks l JOIN peers p USING(pid)
			WHERE l.locktype='advisory' AND l.objsubid=1 AND l.granted
			AND ((l.classid::bigint << 32) | l.objid::bigint)=hashtextextended('open_music_player_schema_migrate',0))
			AND EXISTS (SELECT 1 FROM pg_locks l JOIN peers p USING(pid)
			WHERE l.relation='tracks'::regclass AND l.mode='AccessExclusiveLock' AND NOT l.granted
			AND $2=ANY(pg_blocking_pids(l.pid))) THEN 'schema key held; tracks AccessExclusiveLock waiting' ELSE '' END`, privateImportMigrationFixtureApplication, blockerPID).Scan(&got)
		return got, err
	})
	t.Logf("real Migrate paused before touching receipts: %s", wait)
	var samples atomic.Int32
	var endpointCurrent atomic.Bool
	unwantedHealth := make(chan struct{}, 1)
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, _ *http.Request) {
		samples.Add(1)
		if endpointCurrent.Load() {
			writePrivateAnalysisHealth(w, name, current)
		} else {
			unwantedHealth <- struct{}{}
			writePrivateAnalysisHealth(w, name, old)
		}
	})
	attempted := make(chan error, 1)
	workers.Go(func() { _, err := tryPrivateStartupHealth(ctx, database, client); attempted <- err })
	select {
	case err := <-attempted:
		if err == nil || !strings.Contains(err.Error(), "schema migration in progress") || samples.Load() != 0 {
			t.Fatalf("startup did not refuse the held schema key before health: samples=%d error=%v", samples.Load(), err)
		}
	case <-unwantedHealth:
		t.Fatal("startup sampled health while real Migrate held the schema key")
	case <-ctx.Done():
		t.Fatal("startup blocked instead of refusing the held schema key")
	}
	if err := blocker.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-migrated; err != nil {
		t.Fatalf("paused Migrate did not finish after release: %v", err)
	}
	endpointCurrent.Store(true)
	if marked, err := tryPrivateStartupHealth(ctx, database, client); err != nil || marked != 1 || samples.Load() != 1 {
		t.Fatalf("fresh observation did not reconcile after Migrate: marked=%d samples=%d error=%v", marked, samples.Load(), err)
	}
	requirePrivateClaim(t, ctx, analysis, source, uuid.New(), name, current, true)
}

func TestPrivateAnalysisStartupOrdersTwoBackendSamples(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	database, tracksA, analysisA := privateAnalysisFixtureDB(t, ctx)
	peer := openPrivateImportFixtureDB(t, ctx)
	analysisB := db.NewAnalysisRepository(peer)
	source := fixtureSQLPrivateSource(t, ctx, database, tracksA)
	// Deliberately reversed lexical order: version strings are opaque.
	const name, older, newer = "startup-order", "z-before", "a-after"
	retired, replacement := uuid.New(), uuid.New()
	requirePrivateClaim(t, ctx, analysisA, source, retired, name, older, true)
	sampledA, sampledB, resume := make(chan struct{}), make(chan struct{}), make(chan struct{})
	release := sync.OnceFunc(func() { close(resume) })
	clientA := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
		close(sampledA)
		select {
		case <-resume:
			writePrivateAnalysisHealth(w, name, older)
		case <-req.Context().Done():
		}
	})
	clientB := privateAnalysisStartupClient(t, func(w http.ResponseWriter, _ *http.Request) {
		close(sampledB)
		writePrivateAnalysisHealth(w, name, newer)
	})
	var starters sync.WaitGroup
	defer func() { release(); cancel(); starters.Wait() }()
	start := func(client *analyzer.ServiceClient, analysis *db.AnalysisRepository) <-chan error {
		done := make(chan error, 1)
		starters.Go(func() {
			_, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis)
			done <- err
		})
		return done
	}
	doneA := start(clientA, analysisA)
	select {
	case <-sampledA:
	case <-ctx.Done():
		t.Fatal("first startup did not reach its held health sample")
	}
	doneB := start(clientB, analysisB)
	await := func(done <-chan error) {
		t.Helper()
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("startup did not settle")
		}
	}
	// Wait for a positive race witness, either the peer blocked at the real
	// database authority or the predecessor reaching HTTP prematurely.
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	observedLock := false
observe:
	for {
		select {
		case <-sampledB:
			break observe
		case <-tick.C:
			observedLock = hasPrivateAnalysisStartupWaiter(t, ctx, database)
			if observedLock {
				break observe
			}
		case <-ctx.Done():
			t.Fatal("peer neither waited at PostgreSQL nor reached health")
		}
	}
	if observedLock {
		t.Log("peer waited at PostgreSQL before sending its health request")
		select {
		case <-sampledB:
			t.Error("peer sampled health before obtaining the startup lock")
		default:
		}
		release()
		await(doneA)
		await(doneB)
		requirePrivateClaim(t, ctx, analysisB, source, replacement, name, newer, true)
	} else {
		await(doneB)
		requirePrivateClaim(t, ctx, analysisB, source, replacement, name, newer, true)
		release()
		await(doneA)
	}
	prov := fixtureClaimProvenance(replacement, name, newer)
	var status, version string
	var token sql.NullString
	if err := database.QueryRowContext(ctx, `SELECT status, provenance_json->>'expected_analyzer_version', dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&status, &version, &token); err != nil || status != db.AnalysisStatusPending || version != newer || token.String != replacement.String() {
		t.Fatalf("delayed startup cleared the newer claim: status=%s version=%q token=%+v error=%v", status, version, token, err)
	}
	if !observedLock {
		t.Fatal("peer health was not ordered by the database startup lock")
	}
	if err := analysisB.MarkAnalyzing(ctx, source.TrackID, prov); err != nil {
		t.Fatalf("newer claim could not start: %v", err)
	}
	if err := analysisA.MarkFailed(ctx, source.TrackID, "stale backend", fixtureClaimProvenance(retired, name, older)); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("retired token still owned the row: %v", err)
	}
	result := db.AnalysisResult{Analyzer: name, AnalyzerVersion: newer, DispatchToken: replacement.String(),
		SummaryJSON: json.RawMessage(`{"bpm":123}`), ProvenanceJSON: json.RawMessage(`{"analyzer":"startup-order","analyzer_version":"a-after"}`)}
	if err := analysisB.StoreResult(ctx, source.TrackID, result); err != nil {
		t.Fatalf("newer claim could not publish: %v", err)
	}
	row, err := analysisB.GetByTrackID(ctx, source.TrackID)
	if err != nil || row.Status != db.AnalysisStatusAnalyzed || !bytes.Contains(row.SummaryJSON, []byte(`123`)) {
		t.Fatalf("newer result did not persist: %+v %v", row, err)
	}
}

func hasPrivateAnalysisStartupWaiter(t *testing.T, ctx context.Context, database *db.DB) bool {
	t.Helper()
	// Observe a real blocker on either the predecessor's advisory key or the
	// receipt relation. The same fixture runs on both production snapshots.
	var waiting bool
	if err := database.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM pg_locks
		WHERE database=(SELECT oid FROM pg_database WHERE datname=current_database())
		AND NOT granted AND cardinality(pg_blocking_pids(pid)) > 0
		AND ((locktype='advisory' AND objsubid=1 AND ((classid::bigint << 32) | objid::bigint) = hashtextextended('private-import/v1:analysis-startup',0))
		     OR (locktype='relation' AND relation='private_import_receipts'::regclass AND mode='ShareRowExclusiveLock')))`).Scan(&waiting); err != nil {
		t.Fatal(err)
	}
	return waiting
}

func awaitPrivateAnalysisStartupSignal(t *testing.T, ctx context.Context, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-ctx.Done():
		t.Fatal("startup did not reach its held health response")
	}
}

func requirePrivateAnalysisStartupConflict(t *testing.T, err error) {
	t.Helper()
	var conflict *pq.Error
	if !errors.As(err, &conflict) || conflict.Code != "40001" {
		t.Fatalf("wanted PostgreSQL 40001 from the intervening claim, got %v", err)
	}
}

func TestPrivateAnalysisStartupWaitingPeerUsesPostLockSnapshot(t *testing.T) {
	for _, tc := range []struct {
		name            string
		claimDuringHold bool
	}{
		{name: "sample_matches_predecessor_snapshot"},
		{name: "worker_claim_from_unfenced_stale", claimDuringHold: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			database, tracks, analysisA := privateAnalysisFixtureDB(t, ctx)
			analysisB := db.NewAnalysisRepository(openPrivateImportFixtureDB(t, ctx))
			source := fixtureSQLPrivateSource(t, ctx, database, tracks)
			const name, v1, v2 = "waiting-startup", "z-v1", "a-v2"
			claim := uuid.New()
			if !tc.claimDuringHold {
				requirePrivateClaim(t, ctx, analysisA, source, claim, name, v2, true)
			}
			sampledA, sampledB, hold := make(chan struct{}), make(chan struct{}), make(chan struct{})
			release := sync.OnceFunc(func() { close(hold) })
			var endpointAtV2 atomic.Bool
			var samples atomic.Int32
			client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
				switch samples.Add(1) {
				case 1:
					close(sampledA)
					select {
					case <-hold:
						writePrivateAnalysisHealth(w, name, v1)
					case <-req.Context().Done():
					}
				case 2:
					close(sampledB)
					if endpointAtV2.Load() {
						writePrivateAnalysisHealth(w, name, v2)
					}
				default:
					w.WriteHeader(http.StatusInternalServerError)
				}
			})
			var starters sync.WaitGroup
			defer func() { release(); cancel(); starters.Wait() }()
			start := func(analysis *db.AnalysisRepository) <-chan error {
				done := make(chan error, 1)
				starters.Go(func() {
					_, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis)
					done <- err
				})
				return done
			}
			doneA := start(analysisA)
			awaitPrivateAnalysisStartupSignal(t, ctx, sampledA)
			doneB := start(analysisB)
			tick := time.NewTicker(5 * time.Millisecond)
			defer tick.Stop()
			for !hasPrivateAnalysisStartupWaiter(t, ctx, database) {
				select {
				case <-sampledB:
					t.Fatal("backend B sampled health before acquiring the PostgreSQL lock")
				case <-tick.C:
				case <-ctx.Done():
					t.Fatal("backend B never waited at PostgreSQL")
				}
			}
			// B's predecessor snapshot must predate the worker commit. A still
			// holds v1 while the claim commits and the endpoint switches to v2.
			if tc.claimDuringHold {
				requirePrivateClaim(t, ctx, analysisB, source, claim, name, v1, true)
			}
			endpointAtV2.Store(true)
			if !hasPrivateAnalysisStartupWaiter(t, ctx, database) {
				t.Fatal("backend B stopped waiting before A released health")
			}
			t.Log("backend B positively waited at PostgreSQL after the endpoint switched and before A released health")
			release()
			errA, errB := <-doneA, <-doneB
			if errB != nil {
				t.Fatalf("waiting backend B could not reconcile v2: %v (A: %v)", errB, errA)
			}
			var status, version string
			var token sql.NullString
			if err := database.QueryRowContext(ctx, `SELECT status, provenance_json->>'expected_analyzer_version', dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&status, &version, &token); err != nil {
				t.Fatal(err)
			}
			if status != db.AnalysisStatusStale || version != v2 || token.Valid {
				t.Fatalf("backend B reported success but left status=%s version=%q token=%+v (A: %v)", status, version, token, errA)
			}
			if tc.claimDuringHold {
				requirePrivateAnalysisStartupConflict(t, errA)
			} else if errA != nil {
				t.Fatalf("backend A did not settle its uncontested v1 sample: %v", errA)
			}
			if got := samples.Load(); got != 2 {
				t.Fatalf("health sample count=%d, want 2", got)
			}
			requirePrivateClaim(t, ctx, analysisB, source, uuid.New(), name, v2, true)
		})
	}
}

func TestPrivateAnalysisStartupRejectsClaimFromUnfencedStateDuringHealth(t *testing.T) {
	for _, tc := range []struct {
		name       string
		missingRow bool
	}{
		{name: "stale_row"},
		{name: "legacy_missing_row", missingRow: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
			peer := db.NewAnalysisRepository(openPrivateImportFixtureDB(t, ctx))
			source := fixtureSQLPrivateSource(t, ctx, database, tracks)
			if tc.missingRow {
				if _, err := database.ExecContext(ctx, `DELETE FROM track_analysis WHERE track_id=$1`, source.TrackID); err != nil {
					t.Fatal(err)
				}
			}
			const name, observed, worker = "unfenced-startup", "opaque-observed", "opaque-worker"
			sampled, hold := make(chan struct{}), make(chan struct{})
			release := sync.OnceFunc(func() { close(hold) })
			client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
				close(sampled)
				select {
				case <-hold:
					writePrivateAnalysisHealth(w, name, observed)
				case <-req.Context().Done():
				}
			})
			var startupErr error
			var starter sync.WaitGroup
			defer func() { release(); cancel(); starter.Wait() }()
			starter.Go(func() {
				_, startupErr = reconcilePrivateAnalyzerVersion(ctx, client, analysis)
			})
			awaitPrivateAnalysisStartupSignal(t, ctx, sampled)
			claim := uuid.New()
			requirePrivateClaim(t, ctx, peer, source, claim, name, worker, true)
			release()
			starter.Wait()
			if err := peer.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(claim, name, worker)); err != nil {
				t.Fatalf("held startup changed the intervening claim: %v (startup: %v)", err, startupErr)
			}
			requirePrivateAnalysisStartupConflict(t, startupErr)
		})
	}
}

func TestPrivateAnalysisStartupRejectsAnInterveningWorkerClaim(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	peer := db.NewAnalysisRepository(openPrivateImportFixtureDB(t, ctx))
	source := fixtureSQLPrivateSource(t, ctx, database, tracks)
	const name, before, current = "startup-cas", "opaque-before", "opaque-current"
	requirePrivateClaim(t, ctx, analysis, source, uuid.New(), name, current, true)
	if _, err := database.ExecContext(ctx, `UPDATE track_analysis SET requested_at=NOW()-INTERVAL '31 minutes' WHERE track_id=$1`, source.TrackID); err != nil {
		t.Fatal(err)
	}
	sampled, resume := make(chan struct{}), make(chan struct{})
	release := sync.OnceFunc(func() { close(resume) })
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
		close(sampled)
		select {
		case <-resume:
			writePrivateAnalysisHealth(w, name, before)
		case <-req.Context().Done():
		}
	})
	var startupErr error
	var starter sync.WaitGroup
	defer func() { release(); cancel(); starter.Wait() }()
	starter.Go(func() {
		_, startupErr = reconcilePrivateAnalyzerVersion(ctx, client, analysis)
	})
	select {
	case <-sampled:
	case <-ctx.Done():
		t.Fatal("startup did not reach its held health sample")
	}
	replacement := uuid.New()
	requirePrivateClaim(t, ctx, peer, source, replacement, name, current, true)
	release()
	starter.Wait()
	if err := peer.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(replacement, name, current)); err != nil {
		t.Fatalf("startup overwrote an intervening worker claim: %v (startup: %v)", err, startupErr)
	}
	var conflict *pq.Error
	if !errors.As(startupErr, &conflict) || conflict.Code != "40001" {
		t.Fatalf("startup did not reject its stale row snapshot: %v", startupErr)
	}
	// The next startup attempt reads fresh health; the aborted transaction
	// must release the authority and leave the live matching fence alone.
	fresh := privateAnalysisStartupClient(t, func(w http.ResponseWriter, _ *http.Request) { writePrivateAnalysisHealth(w, name, current) })
	if _, err := reconcilePrivateAnalyzerVersion(ctx, fresh, analysis); err != nil {
		t.Fatalf("fresh attempt failed: %v", err)
	}
	var status, token string
	if err := database.QueryRowContext(ctx, `SELECT status, dispatch_token::text FROM track_analysis WHERE track_id=$1`, source.TrackID).Scan(&status, &token); err != nil || status != db.AnalysisStatusAnalyzing || token != replacement.String() {
		t.Fatalf("fresh attempt disturbed matching worker: %s %q %v", status, token, err)
	}
}

func TestPrivateAnalysisStartupNormalizesFenceForRecovery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	source := fixtureSQLPrivateSource(t, ctx, database, tracks)
	const name, version = "normalized-analyzer", "normalized-v2"
	requirePrivateClaim(t, ctx, analysis, source, uuid.New(), "prior-analyzer", "prior-v1", true)
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, _ *http.Request) {
		writePrivateAnalysisHealth(w, " \t"+name+"\n ", "\r "+version+" \t")
	})
	repairs := &startupRepairProcessor{}
	privateReport, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis)
	if err != nil || privateReport.Analyzer != name || privateReport.AnalyzerVersion != version {
		t.Fatalf("private startup did not use the normalized pair: %+v %v", privateReport, err)
	}
	report, err := reconcileAnalyzerVersion(ctx, client, analysis, &startupTrackStore{}, repairs)
	if err != nil {
		t.Fatalf("startup did not recover old fence: %+v %v", report, err)
	}
	candidates, err := tracks.GetPrivateImportAnalysisCandidates(ctx, name, version, 16)
	if err != nil || len(candidates) != 1 || candidates[0].TrackID != source.TrackID {
		t.Fatalf("normalized worker pair did not select the startup fence: %v %v", candidates, err)
	}
	if report.Analyzer != name || report.AnalyzerVersion != version || repairs.analyzer != name || repairs.analyzerVersion != version {
		t.Fatalf("startup consumers disagreed about normalized pair: %+v", report)
	}
	requirePrivateClaim(t, ctx, analysis, source, uuid.New(), name, version, true)
}

func createFixturePrivateWriteFault(ctx context.Context, database *db.DB, table string) error {
	_, err := database.ExecContext(ctx, `CREATE FUNCTION fixture_private_write_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='fixture write fault'; END$$;
		CREATE TRIGGER fixture_private_write_fault BEFORE INSERT ON `+pq.QuoteIdentifier(table)+` FOR EACH ROW EXECUTE FUNCTION fixture_private_write_fault()`)
	return err
}

func dropFixturePrivateWriteFault(database *db.DB, table string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	_, err := database.ExecContext(ctx, `DROP TRIGGER IF EXISTS fixture_private_write_fault ON `+pq.QuoteIdentifier(table)+`; DROP FUNCTION IF EXISTS fixture_private_write_fault()`)
	return err
}

func TestPrivateCanonicalWriteFaultCleanupIsBounded(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	database, _, _ := privateAnalysisFixtureDB(t, ctx)
	peer := openPrivateImportFixtureDB(t, ctx)
	const table = "private_import_receipts"
	if err := createFixturePrivateWriteFault(ctx, database, table); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := dropFixturePrivateWriteFault(database, table, 5*time.Second); err != nil {
			t.Error(err)
		}
	})
	lock, err := peer.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lock.Rollback() }()
	if _, err := lock.ExecContext(ctx, `LOCK TABLE private_import_receipts IN ACCESS SHARE MODE`); err != nil {
		t.Fatal(err)
	}
	// The operation deadline must end the DROP before the conflicting lock
	// is released. The outer wait is a failsafe, not the source of cancellation.
	done := make(chan error, 1)
	var teardown sync.WaitGroup
	teardown.Go(func() { done <- dropFixturePrivateWriteFault(database, table, 200*time.Millisecond) })
	defer func() { _ = lock.Rollback(); teardown.Wait() }()
	select {
	case err := <-done:
		var canceled *pq.Error
		if !errors.Is(err, context.DeadlineExceeded) && (!errors.As(err, &canceled) || canceled.Code != "57014") {
			t.Fatalf("held trigger drop did not return a deadline/cancellation error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("trigger teardown outlived its bound while PostgreSQL held a conflicting lock")
	}
	// This test context is already canceled when cleanup needs its own budget.
	cancel()
}

func TestPrivateCanonicalWriteErrorsIdentifyOperationAndRollback(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	database, tracks, _ := privateAnalysisFixtureDB(t, ctx)
	for _, tt := range []struct{ table, operation string }{
		{"user_library", "insert canonical private membership"},
		{"track_analysis", "insert canonical private analysis obligation"},
		{"private_import_receipts", "insert canonical private receipt"},
	} {
		t.Run(tt.table, func(t *testing.T) {
			if err := createFixturePrivateWriteFault(ctx, database, tt.table); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if err := dropFixturePrivateWriteFault(database, tt.table, 5*time.Second); err != nil {
					t.Error(err)
				}
			})
			data := []byte("synthetic custody facts")
			owner := seedPrivateImportUser(t, database, ctx)
			in := fixtureCanonicalIntent(owner, privateFixtureAudio{data: data, hash: fixtureSHA256(data), ms: 500})
			_, source, err := tracks.ResolvePrivateImportCommit(ctx, in)
			if err != nil {
				t.Fatal(err)
			}
			receipt, err := tracks.CommitVerifiedPrivateImport(ctx, in, source)
			var driver *pq.Error
			if receipt != nil || err == nil || !strings.Contains(err.Error(), tt.operation+": ") || !errors.As(err, &driver) || !errors.Is(err, driver) || driver.Code != "P0001" {
				t.Errorf("expected static %q and original PostgreSQL fault, got receipt=%v err=%v", tt.operation, receipt, err)
			}
			var leaked bool
			if err := database.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM tracks WHERE private_owner_id=$1)
				OR EXISTS(SELECT 1 FROM user_library WHERE user_id=$1) OR EXISTS(SELECT 1 FROM private_import_receipts WHERE owner_id=$1)
				OR EXISTS(SELECT 1 FROM track_analysis WHERE provenance_json->>'trigger'='post_library_upload' AND NOT EXISTS(SELECT 1 FROM tracks t WHERE t.id=track_analysis.track_id))`, owner).Scan(&leaked); err != nil || leaked {
				t.Fatalf("canonical rollback leaked state: %t %v", leaked, err)
			}
		})
	}
}

func TestPrivateAnalysisWaitsInSharedQueueWithoutLeaseAndRefreshesIdentity(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	objects := privateImportObjectStore(t, ctx)
	owner := seedPrivateImportUser(t, database, ctx)
	audio := privateImportMP3(t, ctx, 631)
	in := fixtureCanonicalIntent(owner, audio)
	if err := objects.PutObject(ctx, in.ObjectKey(), bytes.NewReader(audio.data), int64(len(audio.data)), "audio/mpeg"); err != nil {
		t.Fatal(err)
	}
	receipt, err := processor.CommitStoredPrivateImport(ctx, tracks, objects, in)
	if err != nil {
		t.Fatal(err)
	}
	var worker *processor.Processor
	var publicIDs []int64
	t.Cleanup(func() {
		if worker != nil {
			stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			err := worker.Shutdown(stop)
			cancel()
			if err != nil {
				t.Errorf("cannot retire FIFO fixtures before workers stop: %v", err)
				return
			}
		}
		cleanupPrivateAnalysisReceipt(t, database, receipt)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, id := range publicIDs {
			if _, err := database.ExecContext(ctx, `DELETE FROM tracks WHERE id=$1 AND private_owner_id IS NULL`, id); err != nil {
				t.Error(err)
			}
		}
	})
	sharedTrack := func(label string) *db.Track {
		t.Helper()
		label += " " + in.OperationID.String()
		track, created, err := tracks.CreateTrackFromMetadata(ctx, "queue fixture artist", label, "", 500, db.WithStorage("fixture/"+label, 1))
		if err != nil || !created {
			t.Fatalf("create owned FIFO track: created=%t %v", created, err)
		}
		publicIDs = append(publicIDs, track.ID)
		return track
	}
	head, tail := sharedTrack("queue head"), sharedTrack("queue tail")
	var healthState atomic.Int32
	healthState.Store(1)
	var healthReads atomic.Int32
	type request struct {
		TrackID          int64  `json:"track_id"`
		StorageKey       string `json:"storage_key"`
		ExpectedAnalyzer string `json:"expected_analyzer"`
		ExpectedVersion  string `json:"expected_analyzer_version"`
	}
	var seen []request
	var mu sync.Mutex
	headStarted, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		const name = "queue-fixture"
		if req.Method == http.MethodGet && req.URL.Path == "/health" {
			healthReads.Add(1)
			state := healthState.Load()
			if state == 0 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			version := fmt.Sprintf("queue-v%d", state)
			if state == 2 {
				writePrivateAnalysisHealth(w, " \t"+name, version+"\n ")
			} else {
				writePrivateAnalysisHealth(w, name, version)
			}
			return
		}
		var got request
		if req.Method != http.MethodPost || req.URL.Path != "/analyze" || json.NewDecoder(req.Body).Decode(&got) != nil {
			t.Error("invalid queue fixture request")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		mu.Lock()
		seen = append(seen, got)
		mu.Unlock()
		actualName, actual := name, "queue-v1" // Ordinary jobs retain their startup admission input.
		switch got.TrackID {
		case head.ID:
			close(headStarted)
			select {
			case <-release:
			case <-req.Context().Done():
				return
			}
		case receipt.TrackID:
			actualName, actual = " \t"+name, fmt.Sprintf("queue-v%d\r ", healthState.Load())
			data, err := fixtureReadObject(req.Context(), objects, got.StorageKey)
			if err != nil || got.StorageKey != in.ObjectKey() || !bytes.Equal(data, audio.data) {
				t.Errorf("queued private track lost exact object: %v", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
		}
		_, _ = fmt.Fprintf(w, `{"schema_version":1,"summary":{"bpm":123},"artifacts":{},"provenance":{"analyzer":%q,"analyzer_version":%q}}`, actualName, actual)
	}))
	defer service.Close()
	defer unblock()
	client, err := analyzer.NewServiceClient(analyzer.ServiceConfig{Enabled: true, BaseURL: service.URL, Timeout: 10 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	worker = processor.New(&processor.ProcessorConfig{TrackRepo: tracks, AnalysisRepo: analysis, AnalyzerClient: client, Storage: objects, RequireAnalyzerIdentity: true})
	if _, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis); err != nil {
		t.Fatalf("private startup: %v", err)
	}
	startup, err := reconcileAnalyzerVersion(ctx, client, analysis, tracks, worker)
	if err != nil || startup.AnalyzerVersion != "queue-v1" || startup.Queued != 0 {
		t.Fatalf("ordinary startup: %+v %v", startup, err)
	}
	queueShared := func(track *db.Track) {
		t.Helper()
		if granted, err := worker.SchedulePostStoreAnalysis(ctx, track, processor.PostStoreDownload); !granted || err != nil {
			t.Fatalf("schedule shared job: %t %v", granted, err)
		}
	}
	queueShared(head)
	select {
	case <-headStarted:
	case <-ctx.Done():
		t.Fatal("shared head did not hold the worker")
	}
	assertUnclaimed := func() {
		t.Helper()
		var status string
		var token sql.NullString
		if err := database.QueryRowContext(ctx, `SELECT status, dispatch_token::text FROM track_analysis WHERE track_id=$1`, receipt.TrackID).Scan(&status, &token); err != nil || status != db.AnalysisStatusStale || token.Valid {
			t.Errorf("waiting intent started a SQL lease before worker ownership: %s %v %v", status, token.Valid, err)
		}
	}
	// A failed live identity check must not use startup's cache and mutate a row.
	healthState.Store(0)
	if n, err := worker.DrainPrivateImportAnalysis(ctx); n != 0 || err == nil {
		t.Errorf("unhealthy current analyzer did not defer private admission: %d %v", n, err)
	}
	assertUnclaimed()
	healthState.Store(1)
	if n, err := worker.DrainPrivateImportAnalysis(ctx); n != 1 || err != nil {
		t.Errorf("did not queue exactly one private intent: %d %v", n, err)
	}
	assertUnclaimed()
	queueShared(tail)
	// Compress 31 minutes behind public jobs without aging a correct, still-unclaimed intent.
	if _, err := database.ExecContext(ctx, `UPDATE track_analysis SET updated_at=NOW()-INTERVAL '31 minutes', requested_at=NOW()-INTERVAL '31 minutes' WHERE status='pending' AND track_id=$1`, receipt.TrackID); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if n, err := worker.DrainPrivateImportAnalysis(ctx); n != 0 || err != nil {
			t.Errorf("repeated drain duplicated a waiting intent: %d %v", n, err)
		}
	}
	before := healthReads.Load()
	// No drain after this change; the shared worker itself must resolve the new identity.
	healthState.Store(2)
	unblock()
	if err := worker.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, got := range seen {
		if got.TrackID == receipt.TrackID && got.ExpectedVersion != "queue-v2" {
			t.Errorf("private worker used cached identity after endpoint changed: %q", got.ExpectedVersion)
		}
	}
	if len(seen) != 3 || seen[0].TrackID != head.ID || seen[1].TrackID != receipt.TrackID || seen[2].TrackID != tail.ID {
		t.Fatalf("private work lost its place in the shared FIFO: %+v", seen)
	}
	if healthReads.Load() <= before || seen[1].ExpectedAnalyzer != "queue-fixture" || seen[1].ExpectedVersion != "queue-v2" || seen[2].ExpectedVersion != "queue-v1" {
		t.Fatalf("queued private request reused startup identity or changed ordinary dispatch: %+v", seen)
	}
	row, err := analysis.GetByTrackID(ctx, receipt.TrackID)
	if err != nil || row == nil || row.Status != db.AnalysisStatusAnalyzed {
		t.Fatalf("fresh private result not committed: %+v %v", row, err)
	}
	fields := assertFixtureResultIdentity(t, row.ProvenanceJSON, "queue-fixture", "queue-v2")
	if string(fields["expected_analyzer"]) != `"queue-fixture"` || string(fields["expected_analyzer_version"]) != `"queue-v2"` {
		t.Fatalf("queue result lost its independent claim identity: %s", row.ProvenanceJSON)
	}
}

func assertFixtureResultIdentity(t *testing.T, raw json.RawMessage, wantName, wantVersion string) map[string]json.RawMessage {
	t.Helper()
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatalf("invalid stored result provenance: %v", err)
	}
	var name, version string
	nameErr := json.Unmarshal(fields["analyzer"], &name)
	versionErr := json.Unmarshal(fields["analyzer_version"], &version)
	if nameErr != nil || versionErr != nil || name != wantName || version != wantVersion {
		t.Fatalf("stored result identity fields = %q@%q, want %q@%q: %v %v (provenance: %s)", name, version, wantName, wantVersion, nameErr, versionErr, raw)
	}
	return fields
}
