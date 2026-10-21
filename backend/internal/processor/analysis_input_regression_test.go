package processor

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	mu            sync.Mutex
	queries       []string
	canonicalHash string
	libraryErr    error
	failedImport  bool
}

type processorConnector struct{ fake *processorSQLFake }

func (c processorConnector) Connect(context.Context) (driver.Conn, error) {
	return processorConn{c.fake}, nil
}
func (c processorConnector) Driver() driver.Driver { return processorDriver{c.fake} }

type processorDriver struct{ fake *processorSQLFake }

func (d processorDriver) Open(string) (driver.Conn, error) { return processorConn{d.fake}, nil }

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
		return processorRow(int64(42), args[0].Value, "Canonical Song", "Canonical Artist", "", int64(123000), nil,
			nil, nil, nil, false, "https://canonical.test/a", "canonical", "tracks/canonical-a.wav", int64(4096),
			"pcm_s16le", int64(256), int64(16000), int64(1), "audio/wav", "{}", "provider", nil, "{}", nil, false, time.Now(), time.Now()), nil
	case strings.Contains(query, "SELECT source_file_hash FROM tracks"):
		return processorRow(c.fake.canonicalHash), nil
	case strings.Contains(query, "INSERT INTO user_library"):
		if c.fake.libraryErr != nil {
			return nil, c.fake.libraryErr
		}
		return processorRow(args[0].Value, args[1].Value, time.Now()), nil
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
	fake := &processorSQLFake{canonicalHash: "sha256:" + strings.Repeat("a", 64)}
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
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1), err: analyzer.ErrUnsupported}
	objects := &fakeObjectStorage{}
	p := New(&ProcessorConfig{TrackRepo: db.NewTrackRepository(database), Storage: objects, AnalysisRepo: store, AnalyzerClient: client})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := p.Shutdown(ctx); err != nil {
			t.Errorf("shutdown: %v", err)
		}
	})
	job := &download.DownloadJob{ID: "candidate-b", URL: "fixture://candidate-b", SourceType: "fixture", Title: "Candidate Song", Artist: "Candidate Artist", DurationMs: 1000}
	if err := p.Process(context.Background(), job, func(int) {}); err != nil {
		t.Fatal(err)
	}
	select {
	case req := <-client.requests:
		if req.TrackID != 42 || req.StorageKey != "tracks/canonical-a.wav" || req.SourceURL != "https://canonical.test/a" || req.SourceType != "canonical" || req.DurationMs != 123000 || req.Title != "Canonical Song" || req.Artist != "Canonical Artist" {
			t.Fatalf("analysis used discarded candidate B instead of canonical A: %+v", req)
		}
	case <-time.After(time.Second):
		t.Fatal("canonical analysis was not scheduled")
	}
	var provenance struct {
		Source struct {
			StorageKey string `json:"storage_key"`
			Hash       string `json:"source_file_hash"`
		} `json:"source"`
	}
	if err := json.Unmarshal(store.provenance, &provenance); err != nil {
		t.Fatal(err)
	}
	if provenance.Source.StorageKey != "tracks/canonical-a.wav" || provenance.Source.Hash != fakeSQL.canonicalHash {
		t.Fatalf("analysis source provenance = %+v; want canonical A key/hash", provenance.Source)
	}
	if objects.key != "tracks/fixture/candidate-b.wav" {
		t.Fatalf("candidate B was not actually uploaded: %s", objects.key)
	}
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
	p.enqueueAnalysis(context.Background(), &db.Track{ID: 42, StorageKey: sqlNullString("tracks/canonical-a.wav")}, &TrackMetadata{StorageKey: "tracks/candidate-b.wav"})
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
