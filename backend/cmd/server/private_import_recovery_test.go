package main

import (
	"bytes"
	"context"
	"crypto/sha256"
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
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
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
			t.Error("analyzer failed to open the wire-named object")
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
		p := processor.New(&processor.ProcessorConfig{TrackRepo: tracks, LibraryRepo: db.NewLibraryRepository(newDB), AnalysisRepo: analysis, AnalyzerClient: client, Storage: objects, RequireAnalyzerIdentity: true})
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
	// A DB claim fault must not consume or overwrite the committed receipt.
	if _, err := newDB.ExecContext(ctx, `CREATE FUNCTION fixture_refuse_claim() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'fixture refused claim'; END$$;
		CREATE TRIGGER fixture_refuse_claim BEFORE UPDATE ON track_analysis FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION fixture_refuse_claim()`); err != nil {
		t.Fatal(err)
	}
	if n, err := stopped.DrainPrivateImportAnalysis(ctx); n != 0 || err == nil || !strings.Contains(err.Error(), "fixture refused claim") {
		t.Fatalf("expected failed PostgreSQL claim: %d %v", n, err)
	}
	loadStatus(firstAck.TrackID, db.AnalysisStatusStale)
	loadStatus(secondAck.TrackID, db.AnalysisStatusStale)
	if _, err := newDB.ExecContext(ctx, `DROP TRIGGER fixture_refuse_claim ON track_analysis; DROP FUNCTION fixture_refuse_claim()`); err != nil {
		t.Fatal(err)
	}
	if err := stopped.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	// Queue unavailable after a real SQL claim; durable terminal recovery must run.
	if n, err := stopped.DrainPrivateImportAnalysis(ctx); n != 0 || err == nil || !strings.Contains(err.Error(), "schedule private analysis") {
		t.Fatalf("expected real closed queue after claim: %d %v", n, err)
	}
	loadStatus(firstAck.TrackID, db.AnalysisStatusFailed)
	loadStatus(secondAck.TrackID, db.AnalysisStatusStale)
	if _, err := newDB.ExecContext(ctx, `UPDATE track_analysis SET updated_at = NOW() - INTERVAL '60 seconds' WHERE track_id=$1`, firstAck.TrackID); err != nil {
		t.Fatal(err)
	}
	old := uuid.New()
	canonical := db.PrivateImportSource{TrackID: secondAck.TrackID, Key: second.ObjectKey(), SHA256: second.SHA256, ByteLength: second.ByteLength, DurationMs: second.DurationMs}
	if admitted, err := analysis.ClaimPrivateImportAnalysis(ctx, canonical, old, "fixture", "fixture-v1"); !admitted || err != nil {
		t.Fatalf("simulate crash after atomic claim: admitted=%t %v", admitted, err)
	}
	if _, err := newDB.ExecContext(ctx, `UPDATE track_analysis SET updated_at = NOW() - INTERVAL '31 minutes' WHERE track_id=$1`, secondAck.TrackID); err != nil {
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
	if x.queued+y.queued != 3 || x.err != nil || y.err != nil {
		t.Fatalf("concurrent drains did not uniquely admit failed/aged/missed claims: %+v %+v", x, y)
	}
	if n, err := worker.DrainPrivateImportAnalysis(ctx); n != 0 || err != nil {
		t.Fatalf("second drain admitted already-owned work: %d %v", n, err)
	}
	select {
	case <-held:
	case <-ctx.Done():
		t.Fatal("replacement worker did not reach held analyzer wire")
	}
	loadStatus(secondAck.TrackID, db.AnalysisStatusAnalyzing)
	retired, _ := json.Marshal(map[string]string{"dispatch_token": old.String(), "expected_analyzer": "fixture", "expected_analyzer_version": "fixture-v1"})
	if err := analysis.MarkAnalyzing(ctx, secondAck.TrackID, retired); !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		t.Fatalf("late same-version worker acquired replacement claim: %v", err)
	}
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

func fixtureReadObject(ctx context.Context, objects *storage.Client, key string) ([]byte, error) {
	body, info, err := objects.GetObject(ctx, key)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	data, err := io.ReadAll(io.LimitReader(body, 1<<20))
	if err != nil || int64(len(data)) != info.Size {
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
