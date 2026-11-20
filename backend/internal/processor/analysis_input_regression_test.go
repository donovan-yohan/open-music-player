package processor

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

// Keep the real processor, track dedupe and library repositories in the loop.
// Only the SQL driver, object store and remote analyzer are fakes.
type processorSQLFake struct {
	mu             sync.Mutex
	queries        []string
	canonicalHash  string
	canonicalSize  int64
	postStoreTrack *db.Track
	genreHintCalls int
	libraryErr     error
	failedImport   bool
}

type processorConnector struct{ fake *processorSQLFake }

func (c processorConnector) Connect(context.Context) (driver.Conn, error) {
	return processorConn(c), nil
}
func (c processorConnector) Driver() driver.Driver { return processorDriver(c) }

type processorDriver struct{ fake *processorSQLFake }

func (d processorDriver) Open(string) (driver.Conn, error) { return processorConn(d), nil }

type processorConn struct{ fake *processorSQLFake }

func (processorConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (processorConn) Close() error              { return nil }
func (processorConn) Begin() (driver.Tx, error) { return processorTx{}, nil }

type processorTx struct{}

func (processorTx) Commit() error   { return nil }
func (processorTx) Rollback() error { return nil }

type processorRows struct {
	columns []string
	values  [][]driver.Value
}

func (r *processorRows) Columns() []string { return r.columns }
func (r *processorRows) Close() error      { return nil }
func (r *processorRows) Next(dest []driver.Value) error {
	if len(r.values) == 0 {
		return io.EOF
	}
	copy(dest, r.values[0])
	r.values = r.values[1:]
	return nil
}
func processorRow(values ...driver.Value) driver.Rows {
	columns := make([]string, len(values))
	for i := range columns {
		columns[i] = fmt.Sprintf("column_%d", i)
	}
	return &processorRows{columns: columns, values: [][]driver.Value{values}}
}
func (c processorConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.fake.mu.Lock()
	defer c.fake.mu.Unlock()
	c.fake.queries = append(c.fake.queries, query)
	switch {
	case strings.Contains(query, "WHERE identity_hash = $1"):
		return processorRow(int64(42), args[0].Value, "Canonical Song", "Canonical Artist", "", int64(1000), nil,
			nil, nil, nil, false, "https://canonical.test/a", "canonical", "tracks/canonical-a.wav", c.fake.canonicalSize,
			"pcm_s16le", int64(256), int64(16000), int64(1), "audio/wav", "{}", "provider", nil, "{}", nil, false, time.Now(), time.Now()), nil
	case strings.Contains(query, "FROM tracks") && strings.Contains(query, "WHERE id = $1") && strings.Contains(query, "file_size_bytes"):
		if args[0].Value != int64(42) {
			return nil, fmt.Errorf("unexpected canonical track read: %v", args)
		}
		track := c.fake.postStoreTrack
		if track == nil {
			return &processorRows{}, nil
		}
		return processorRow(track.ID, "private-fixture", track.Title, track.Artist.String, nil, int64(track.DurationMs.Int32), nil,
			nil, nil, nil, false, track.SourceURL.String, track.SourceType.String, track.StorageKey.String, track.FileSizeBytes.Int64,
			"pcm_s16le", int64(256), int64(16000), int64(1), "audio/wav", "{}", "provider", nil, "{}", nil, false, time.Now(), time.Now(), track.Private), nil
	case strings.Contains(query, "SELECT source_file_hash FROM tracks"):
		if args[0].Value != int64(42) {
			return nil, fmt.Errorf("unexpected canonical hash read: %v", args)
		}
		return processorRow(c.fake.canonicalHash), nil
	case strings.Contains(query, "INSERT INTO user_library"):
		if c.fake.libraryErr != nil {
			return nil, c.fake.libraryErr
		}
		if len(args) != 2 || args[1].Value != int64(42) {
			return nil, fmt.Errorf("unexpected library target: %v", args)
		}
		return processorRow(time.Now()), nil
	default:
		return nil, fmt.Errorf("unexpected query: %s", query)
	}
}
func (c processorConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.fake.mu.Lock()
	defer c.fake.mu.Unlock()
	c.fake.queries = append(c.fake.queries, query)
	switch {
	case strings.Contains(query, "pg_advisory_xact_lock"):
	case strings.Contains(query, "WITH genre_hint AS") && c.fake.postStoreTrack != nil:
		if args[0].Value != int64(42) || args[1].Value != `{"bpm":{"value":124}}` {
			return nil, fmt.Errorf("unexpected genre hint input: %v", args)
		}
		c.fake.genreHintCalls++
		return driver.RowsAffected(0), nil // this fixture's summary contains no genre
	case strings.Contains(query, "UPDATE playlist_import_items"):
		if len(args) != 3 || args[0].Value != int64(7) || args[1].Value != playlistimport.ItemStatusFailed || !strings.Contains(fmt.Sprint(args[2].Value), "library insert unavailable") {
			return nil, fmt.Errorf("unexpected import-failure bookkeeping: %+v", args)
		}
		c.fake.failedImport = true
	default:
		return nil, fmt.Errorf("unexpected exec: %s", query)
	}
	return driver.RowsAffected(1), nil
}

func newProcessorSQLFake(t *testing.T) (*db.DB, *processorSQLFake) {
	t.Helper()
	fake := &processorSQLFake{canonicalHash: "sha256:" + strings.Repeat("a", 64), canonicalSize: 4096}
	raw := sql.OpenDB(processorConnector{fake})
	t.Cleanup(func() { _ = raw.Close() })
	return &db.DB{DB: raw}, fake
}

type inputAnalysisStore struct {
	fakeAnalysisStore
	provenance      json.RawMessage
	alreadyAnalyzed bool
}

func (s *inputAnalysisStore) RequestAnalysisIfNeeded(ctx context.Context, trackID int64, provenance json.RawMessage) (bool, error) {
	err := s.RequestAnalysis(ctx, trackID, provenance)
	return !s.alreadyAnalyzed, err
}

func (s *inputAnalysisStore) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.provenance = append(json.RawMessage(nil), provenance...)
	return s.fakeAnalysisStore.RequestAnalysis(ctx, trackID, provenance)
}

func TestProcessDeduplicatedUploadAnalyzesCanonicalAudio(t *testing.T) {
	database, fakeSQL := newProcessorSQLFake(t)
	store := &inputAnalysisStore{}
	audio := testWAVBytes(t, 16000, 1)
	fakeSQL.canonicalSize, fakeSQL.canonicalHash = int64(len(audio)), fixtureSHA256(audio)
	objects := &fakeObjectStorage{objects: map[string][]byte{canonicalAnalysisKey: audio}}
	client, seen, calls := newAnalysisWireFixture(t, objects, http.StatusUnsupportedMediaType)
	p := New(&ProcessorConfig{TrackRepo: db.NewTrackRepository(database), LibraryRepo: db.NewLibraryRepository(database), Storage: objects, AnalysisRepo: store, AnalyzerClient: client})
	t.Cleanup(func() { drainAnalysisForTest(t, p) })
	job := &download.DownloadJob{ID: "candidate-b", UserID: uuid.NewString(), URL: "fixture://candidate-b", SourceType: "fixture", Title: "Candidate Song", Artist: "Candidate Artist", DurationMs: 2000}
	if err := p.Process(context.Background(), job, func(int) {}); err != nil {
		t.Fatal(err)
	}
	wire := receiveAnalysisWire(t, seen)
	want := fmt.Sprintf(`{"schema_version":%d,"track_id":42,"storage_key":%q,"source_url":"https://canonical.test/a","source_type":"canonical","duration_ms":1000,"title":"Canonical Song","artist":"Canonical Artist"}`, analyzer.SchemaVersion, canonicalAnalysisKey)
	if string(wire.body) != want || wire.hash != fakeSQL.canonicalHash || wire.size != fakeSQL.canonicalSize {
		t.Fatalf("analysis used wrong input: %s, %s/%d; want %s, %s/%d", wire.body, wire.hash, wire.size, want, fakeSQL.canonicalHash, fakeSQL.canonicalSize)
	}
	drainAnalysisForTest(t, p)
	if calls.Load() != 1 || store.unsupportedCount != 1 {
		t.Fatalf("URL analysis requests=%d unsupported=%d; want 1/1", calls.Load(), store.unsupportedCount)
	}
	assertStoredSource(t, store.provenance, "post_download", canonicalAnalysisKey, wire.hash, 0, 1000, "canonical")
	if objects.key != "tracks/fixture/candidate-b.wav" || len(objects.data) == 0 || fixtureSHA256(objects.data) == wire.hash {
		t.Fatalf("candidate B was not a distinct uploaded object: %s, %s/%d", objects.key, fixtureSHA256(objects.data), len(objects.data))
	}
	t.Logf("analyzer POST /analyze body=%s opened=%s bytes=%d; discarded candidate=%s %s bytes=%d", wire.body, wire.hash, wire.size, objects.key, fixtureSHA256(objects.data), len(objects.data))
	if job.TrackID == nil || *job.TrackID != 42 {
		t.Fatalf("deduplication lost canonical track ID: %v", job.TrackID)
	}
	fakeSQL.mu.Lock()
	defer fakeSQL.mu.Unlock()
	for _, query := range fakeSQL.queries {
		if strings.Contains(query, "SET source_file_hash") {
			t.Fatal("discarded upload hash was adopted by canonical track")
		}
	}
}

func TestEnqueueAnalysisDoesNotScheduleAlreadyAnalyzedTrack(t *testing.T) {
	store := &inputAnalysisStore{alreadyAnalyzed: true}
	p := &Processor{
		analysisRepo: store, analyzerClient: &fakeAnalyzerClient{},
		analysisQueue: make(chan analysisTask, 1), analysisStop: make(chan struct{}),
		analysisOutstanding: make(map[uint64]analyzer.Request),
	}
	if queued, err := p.SchedulePostStoreAnalysis(context.Background(), &db.Track{ID: 42, StorageKey: sqlNullString(canonicalAnalysisKey)}, PostStoreDownload); err != nil || queued {
		t.Fatalf("already analyzed canonical track: queued=%v err=%v", queued, err)
	}
	if store.requestCount != 1 {
		t.Fatalf("analysis persistence requests = %d, want one", store.requestCount)
	}
	if len(p.analysisQueue) != 0 {
		t.Fatal("already analyzed canonical track was redundantly scheduled")
	}
}

func TestProcessLibraryInsertionFailureStopsBeforeSuccess(t *testing.T) {
	database, fakeSQL := newProcessorSQLFake(t)
	libraryErr := errors.New("library insert unavailable")
	fakeSQL.libraryErr = libraryErr
	p := New(&ProcessorConfig{TrackRepo: db.NewTrackRepository(database), LibraryRepo: db.NewLibraryRepository(database), Storage: &fakeObjectStorage{}})
	progress := 0
	err := p.Process(context.Background(), &download.DownloadJob{ID: "library-failure-no-import", URL: "fixture://library-failure", SourceType: "fixture", UserID: uuid.NewString()}, func(value int) { progress = value })
	if !errors.Is(err, libraryErr) {
		t.Fatalf("Process error = %v, progress = %d; want library insertion failure, not successful completion", err, progress)
	}
	if progress >= 95 {
		t.Fatalf("library insertion failure reported completion progress %d", progress)
	}
}

func TestProcessLibraryInsertionFailureIsNotSuccessfulCompletion(t *testing.T) {
	database, fakeSQL := newProcessorSQLFake(t)
	libraryErr := errors.New("library insert unavailable")
	fakeSQL.libraryErr = libraryErr
	store := &fakeAnalysisStore{}
	p := New(&ProcessorConfig{TrackRepo: db.NewTrackRepository(database), LibraryRepo: db.NewLibraryRepository(database), ImportRepo: playlistimport.NewImportRepository(database), Storage: &fakeObjectStorage{}, AnalysisRepo: store, AnalyzerClient: &fakeAnalyzerClient{err: analyzer.ErrUnsupported}})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = p.Shutdown(ctx)
	})
	job := &download.DownloadJob{ID: "library-failure", URL: "fixture://library-failure", SourceType: "fixture", Title: "Candidate Song", UserID: uuid.NewString(), PlaylistImportItemID: 7}
	progress := 0
	err := p.Process(context.Background(), job, func(value int) { progress = value })
	if !errors.Is(err, libraryErr) {
		t.Fatalf("Process error = %v, want library insertion failure", err)
	}
	if progress >= 95 {
		t.Fatalf("failed library insert reported completion progress %d", progress)
	}
	if store.requestCount != 0 {
		t.Fatalf("analysis scheduled after failed library insert: %d", store.requestCount)
	}
	fakeSQL.mu.Lock()
	defer fakeSQL.mu.Unlock()
	if !fakeSQL.failedImport {
		t.Fatal("existing deferred import-failure bookkeeping did not run")
	}
	if _, err := os.Stat(filepath.Join(os.TempDir(), "omp-fixture-library-failure.wav")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("download temporary file not cleaned: %v", err)
	}
}

func TestPrivateAnalysisLocalIntentDeduplicationAndCapacity(t *testing.T) {
	newQueue := func(capacity int) *Processor {
		return &Processor{
			analysisQueue:          make(chan analysisTask, capacity),
			analysisOutstanding:    make(map[uint64]analyzer.Request),
			privateAnalysisPending: make(map[int64]uint64),
		}
	}
	check := func(t *testing.T, p *Processor, ctx context.Context, id int64, want bool, wantErr error) {
		t.Helper()
		admitted, err := p.schedulePrivateAnalysis(ctx, db.PrivateImportSource{TrackID: id})
		if admitted != want || !errors.Is(err, wantErr) {
			t.Fatalf("local intent %d admitted=%t want=%t error=%v want=%v", id, admitted, want, err, wantErr)
		}
	}
	ctx := context.Background()
	t.Run("QueuedAndStarting", func(t *testing.T) {
		p := newQueue(privateImportAnalysisBatchLimit + 2)
		check(t, p, ctx, 1, true, nil)
		check(t, p, ctx, 1, false, nil)
		starting := <-p.analysisQueue
		check(t, p, ctx, 1, false, nil)
		for id := int64(2); id <= privateImportAnalysisBatchLimit; id++ {
			check(t, p, ctx, id, true, nil)
		}
		check(t, p, ctx, privateImportAnalysisBatchLimit+1, false, nil)
		if len(p.analysisOutstanding) != 0 {
			t.Fatalf("waiting hints entered durable shutdown recovery: %v", p.analysisOutstanding)
		}
		p.finishAnalysisTask(starting)
		check(t, p, ctx, privateImportAnalysisBatchLimit+1, true, nil)
		p.drainAnalysisQueue(ctx)
		if len(p.privateAnalysisPending) != 0 {
			t.Fatalf("retired queue retained local hints: %v", p.privateAnalysisPending)
		}
		check(t, p, ctx, 1, true, nil)
		p.drainAnalysisQueue(ctx)
	})
	t.Run("SharedQueueFull", func(t *testing.T) {
		p := newQueue(1)
		p.analysisQueue <- analysisTask{request: analyzer.Request{TrackID: 99}}
		check(t, p, ctx, 1, false, nil)
		if shared := <-p.analysisQueue; shared.request.TrackID != 99 || len(p.privateAnalysisPending) != 0 {
			t.Fatal("saturated shared queue replaced its work or retained an unqueued hint")
		}
		canceled, cancel := context.WithCancel(ctx)
		cancel()
		check(t, p, canceled, 1, false, context.Canceled)
		check(t, p, ctx, 1, true, nil)
		p.drainAnalysisQueue(ctx)
	})
}
