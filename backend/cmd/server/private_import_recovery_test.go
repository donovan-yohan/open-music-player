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

func TestPrivateImportDurableReceiptAndCanonicalAnalysisRecovery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	firstDB := openPrivateImportFixtureDB(t, ctx)
	objects := privateImportObjectStore(t, ctx)
	if err := firstDB.Migrate(); err != nil {
		t.Fatal(err)
	}
	owner := seedPrivateImportUser(t, firstDB, ctx)
	other := seedPrivateImportUser(t, firstDB, ctx)
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
	if r, err := processor.CommitStoredPrivateImport(ctx, tracks, objects, first); r != nil || err == nil || !strings.Contains(err.Error(), "fixture refused receipt") {
		t.Fatalf("late receipt rollback fault: %v %v", r, err)
	}
	for _, table := range []string{"tracks", "user_library", "track_analysis", "private_import_receipts"} {
		var count int
		if err := firstDB.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&count); err != nil || count != 0 {
			t.Fatalf("atomic write leaked %s rows=%d err=%v", table, count, err)
		}
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
	const result = `{"schema_version":1,"summary":{"bpm":123},"artifacts":{},"provenance":{"analyzer":"fixture","analyzer_version":"fixture-v1"}}`
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
				t.Error(err)
			}
		})
		return p, client
	}
	startup := func(p *processor.Processor, client *analyzer.ServiceClient) {
		t.Helper()
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
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: owner.String(), URL: "file://" + a.path, SourceType: "local-fixture", Title: first.Title, Artist: first.Artist, Album: first.Album, DurationMs: int(first.DurationMs)}
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
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, step := range []struct {
			query string
			arg   any
		}{
			{`DELETE FROM private_import_receipts WHERE owner_id=$1`, owner},
			{`DELETE FROM tracks WHERE id=$1`, source.TrackID},
			{`DELETE FROM users WHERE id=$1`, owner},
		} {
			if _, err := database.ExecContext(cleanupCtx, step.query, step.arg); err != nil {
				t.Error(err)
			}
		}
	})
	return source
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
	if _, err := analysis.MarkStaleByAnalyzerVersionAtStartup(ctx, name, newer); err != nil {
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
	if _, err := analysis.MarkStaleByAnalyzerVersionAtStartup(ctx, name, final); err != nil {
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
			if _, err := database.ExecContext(ctx, `CREATE FUNCTION fixture_private_write_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='fixture write fault'; END$$;
				CREATE TRIGGER fixture_private_write_fault BEFORE INSERT ON `+tt.table+` FOR EACH ROW EXECUTE FUNCTION fixture_private_write_fault()`); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if _, err := database.Exec(`DROP TRIGGER fixture_private_write_fault ON ` + tt.table + `; DROP FUNCTION fixture_private_write_fault()`); err != nil {
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
	sharedTrack := func(label string) *db.Track {
		t.Helper()
		track, _, err := tracks.CreateTrackFromMetadata(ctx, "queue fixture artist", label, "", 500, db.WithStorage("fixture/"+label, 1))
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	head, tail := sharedTrack("queue head"), sharedTrack("queue tail")
	var healthState atomic.Int32
	healthState.Store(1)
	var healthReads atomic.Int32
	type request struct {
		TrackID         int64  `json:"track_id"`
		StorageKey      string `json:"storage_key"`
		ExpectedVersion string `json:"expected_analyzer_version"`
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
			_, _ = fmt.Fprintf(w, `{"status":"healthy","analyzer":%q,"analyzer_version":"queue-v%d","tempo_model":"test","key_model":"test","spectral_provenance":"test","spectral_channel_set":"bands3-v1"}`, name, state)
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
		actual := "queue-v1" // Ordinary jobs retain their startup admission input.
		switch got.TrackID {
		case head.ID:
			close(headStarted)
			select {
			case <-release:
			case <-req.Context().Done():
				return
			}
		case receipt.TrackID:
			actual = fmt.Sprintf("queue-v%d", healthState.Load())
			data, err := fixtureReadObject(req.Context(), objects, got.StorageKey)
			if err != nil || got.StorageKey != in.ObjectKey() || !bytes.Equal(data, audio.data) {
				t.Errorf("queued private track lost exact object: %v", err)
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
		}
		_, _ = fmt.Fprintf(w, `{"schema_version":1,"summary":{"bpm":123},"artifacts":{},"provenance":{"analyzer":%q,"analyzer_version":%q}}`, name, actual)
	}))
	defer service.Close()
	defer unblock()
	client, err := analyzer.NewServiceClient(analyzer.ServiceConfig{Enabled: true, BaseURL: service.URL, Timeout: 10 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	worker := processor.New(&processor.ProcessorConfig{TrackRepo: tracks, AnalysisRepo: analysis, AnalyzerClient: client, Storage: objects, RequireAnalyzerIdentity: true})
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := worker.Shutdown(stop); err != nil {
			t.Error(err)
		}
	})
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
	if healthReads.Load() <= before || seen[1].ExpectedVersion != "queue-v2" || seen[2].ExpectedVersion != "queue-v1" {
		t.Fatalf("queued private request reused startup identity or changed ordinary dispatch: %+v", seen)
	}
	row, err := analysis.GetByTrackID(ctx, receipt.TrackID)
	if err != nil || row.Status != db.AnalysisStatusAnalyzed || !bytes.Contains(row.ProvenanceJSON, []byte(`"queue-v2"`)) {
		t.Fatalf("fresh private result not committed: %+v %v", row, err)
	}
}
