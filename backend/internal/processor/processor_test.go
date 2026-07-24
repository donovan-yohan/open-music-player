package processor

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"errors"
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
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/playlistimport"
	"github.com/openmusicplayer/backend/internal/storage"
	"github.com/openmusicplayer/backend/internal/testutil"
)

type fakeObjectStorage struct {
	key         string
	contentType string
	data        []byte
	objects     map[string][]byte
	getKeys     []string
}

func (s *fakeObjectStorage) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error {
	s.key = key
	s.contentType = contentType
	s.data, _ = io.ReadAll(reader)
	return nil
}

func (s *fakeObjectStorage) GetObject(ctx context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error) {
	s.getKeys = append(s.getKeys, key)
	if data, ok := s.objects[key]; ok {
		return io.NopCloser(bytes.NewReader(data)), &storage.ObjectInfo{Size: int64(len(data)), ContentType: "audio/wav"}, nil
	}
	if key != s.key {
		return nil, nil, errors.New("object not found")
	}
	return io.NopCloser(bytes.NewReader(s.data)), &storage.ObjectInfo{
		Size:        int64(len(s.data)),
		ContentType: s.contentType,
	}, nil
}

func testWAVBytes(t *testing.T, sampleRate, channels int) []byte {
	t.Helper()
	const seconds = 1
	dataSize := sampleRate * channels * 2 * seconds
	var out bytes.Buffer
	for _, value := range []any{
		[]byte("RIFF"), uint32(36 + dataSize), []byte("WAVEfmt "), uint32(16),
		uint16(1), uint16(channels), uint32(sampleRate), uint32(sampleRate * channels * 2),
		uint16(channels * 2), uint16(16), []byte("data"), uint32(dataSize),
	} {
		if err := binary.Write(&out, binary.LittleEndian, value); err != nil {
			t.Fatalf("write WAV fixture: %v", err)
		}
	}
	out.Write(make([]byte, dataSize))
	return out.Bytes()
}

type fakeAnalysisStore struct {
	mu               sync.Mutex
	requestCount     int
	repairCount      int
	repairResult     db.AnalysisRepairRequest
	analyzingCount   int
	storeResultCount int
	storedResult     db.AnalysisResult
	storeResultCh    chan db.AnalysisResult
	storeResultErr   error
	failedCount      int
	unsupportedCount int
	closed           bool
}

type legacyAnalysisStore struct {
	requestCount int
}

func (s *fakeAnalysisStore) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.assertOpenLocked()
	s.requestCount++
	return nil
}

func (s *fakeAnalysisStore) RequestRepairAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage, force, onlyStale bool, staleAfter time.Duration) (db.AnalysisRepairRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.assertOpenLocked()
	s.repairCount++
	if s.repairResult.TrackID == 0 {
		s.repairResult.TrackID = trackID
	}
	return s.repairResult, nil
}

func (s *fakeAnalysisStore) MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.assertOpenLocked()
	s.analyzingCount++
	return nil
}

func (s *fakeAnalysisStore) StoreResult(ctx context.Context, trackID int64, result db.AnalysisResult) error {
	s.mu.Lock()
	s.assertOpenLocked()
	s.storeResultCount++
	s.storedResult = result
	ch := s.storeResultCh
	s.mu.Unlock()
	if ch != nil {
		ch <- result
	}
	return s.storeResultErr
}

func (s *fakeAnalysisStore) MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.assertOpenLocked()
	s.failedCount++
	return nil
}

func (s *fakeAnalysisStore) MarkUnsupported(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.assertOpenLocked()
	s.unsupportedCount++
	return nil
}

func (s *fakeAnalysisStore) closeForTest() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
}

func (s *fakeAnalysisStore) assertOpenLocked() {
	if s.closed {
		panic("analysis store write after close")
	}
}

type delayedRecoveryAnalysisStore struct {
	*fakeAnalysisStore
	delay time.Duration
}

func (s *delayedRecoveryAnalysisStore) MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	timer := time.NewTimer(s.delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return s.fakeAnalysisStore.MarkFailed(ctx, trackID, errText, provenance)
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *legacyAnalysisStore) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.requestCount++
	return nil
}

func (s *legacyAnalysisStore) MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	return nil
}

func (s *legacyAnalysisStore) StoreResult(ctx context.Context, trackID int64, result db.AnalysisResult) error {
	return nil
}

func (s *legacyAnalysisStore) MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	return nil
}

func (s *legacyAnalysisStore) MarkUnsupported(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	return nil
}

type fakeAnalyzerClient struct {
	requests chan analyzer.Request
	result   *analyzer.Result
	err      error
}

type contextAwareAnalyzerClient struct {
	started chan context.Context
	release chan struct{}
}

type blockingAnalyzerClient struct {
	mu        sync.Mutex
	active    int
	maxActive int
	started   chan int64
	release   chan struct{}
}

type nonCooperativeAnalyzerClient struct {
	started chan int64
	release chan struct{}
}

func sqlNullString(value string) sql.NullString {
	return sql.NullString{String: value, Valid: value != ""}
}

func sqlNullInt32(value int32) sql.NullInt32 {
	return sql.NullInt32{Int32: value, Valid: value != 0}
}

func (c *fakeAnalyzerClient) Analyze(ctx context.Context, req analyzer.Request) (*analyzer.Result, error) {
	if c.requests != nil {
		c.requests <- req
	}
	if c.err != nil {
		return nil, c.err
	}
	return c.result, nil
}

func (c *contextAwareAnalyzerClient) Analyze(ctx context.Context, _ analyzer.Request) (*analyzer.Result, error) {
	c.started <- ctx
	<-c.release
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return &analyzer.Result{
		SchemaVersion:  analyzer.SchemaVersion,
		SummaryJSON:    json.RawMessage(`{}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{}`),
	}, nil
}

func (c *blockingAnalyzerClient) Analyze(ctx context.Context, req analyzer.Request) (*analyzer.Result, error) {
	c.mu.Lock()
	c.active++
	if c.active > c.maxActive {
		c.maxActive = c.active
	}
	c.mu.Unlock()
	c.started <- req.TrackID
	select {
	case <-c.release:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	c.mu.Lock()
	c.active--
	c.mu.Unlock()
	return &analyzer.Result{
		SchemaVersion:  analyzer.SchemaVersion,
		SummaryJSON:    json.RawMessage(`{}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{}`),
	}, nil
}

func (c *nonCooperativeAnalyzerClient) Analyze(_ context.Context, req analyzer.Request) (*analyzer.Result, error) {
	c.started <- req.TrackID
	<-c.release
	return &analyzer.Result{
		SchemaVersion:  analyzer.SchemaVersion,
		SummaryJSON:    json.RawMessage(`{"bpm":{"value":128}}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"v1"}`),
	}, nil
}

func TestRunAnalysisSerializesConfiguredAnalyzerWork(t *testing.T) {
	store := &fakeAnalysisStore{storeResultCh: make(chan db.AnalysisResult, 2)}
	client := &blockingAnalyzerClient{
		started: make(chan int64, 2),
		release: make(chan struct{}, 2),
	}
	processor := New(&ProcessorConfig{
		AnalysisRepo:        store,
		AnalyzerClient:      client,
		AnalysisConcurrency: 1,
	})
	for _, trackID := range []int64{1, 2} {
		if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{
			TrackID: trackID, StorageKey: "tracks/test.mp3",
		}); err != nil {
			t.Fatalf("scheduleAnalysis(%d) error = %v", trackID, err)
		}
	}

	first := <-client.started
	select {
	case second := <-client.started:
		t.Fatalf("track %d started while track %d was active", second, first)
	case <-time.After(50 * time.Millisecond):
	}
	client.release <- struct{}{}
	second := <-client.started
	if second == first {
		t.Fatalf("second track id = first track id = %d", first)
	}
	client.release <- struct{}{}
	<-store.storeResultCh
	<-store.storeResultCh

	client.mu.Lock()
	defer client.mu.Unlock()
	if client.maxActive != 1 {
		t.Fatalf("max concurrent analysis jobs = %d, want 1", client.maxActive)
	}
}

func TestScheduleAnalysisQueueIsBoundedAndContextAware(t *testing.T) {
	client := &blockingAnalyzerClient{
		started: make(chan int64, analysisQueueSize+1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{
		AnalysisRepo:        &fakeAnalysisStore{},
		AnalyzerClient:      client,
		AnalysisConcurrency: 1,
	})

	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	<-client.started
	for trackID := int64(2); trackID <= analysisQueueSize+1; trackID++ {
		if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: trackID}); err != nil {
			t.Fatalf("fill queue at track %d: %v", trackID, err)
		}
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := processor.scheduleAnalysis(canceled, analyzer.Request{TrackID: 999}); !errors.Is(err, context.Canceled) {
		t.Fatalf("scheduleAnalysis() error = %v, want context.Canceled", err)
	}
	close(client.release)
}

func TestEnqueueAnalysisSkipsPendingRowWhenAnalyzerClientMissing(t *testing.T) {
	store := &fakeAnalysisStore{}
	processor := &Processor{analysisRepo: store}

	processor.enqueueAnalysis(context.Background(), &db.Track{ID: 42}, &TrackMetadata{
		StorageKey: "tracks/fixture/job-fixture.wav",
		SourceURL:  "fixture://silence",
		SourceType: "fixture",
	})

	if store.requestCount != 0 {
		t.Fatalf("RequestAnalysis called %d time(s) without analyzer client; would leave an unprocessable pending row", store.requestCount)
	}
}

func TestEnqueueAnalysisDefersRequiredIdentityWithoutCallingAnalyzer(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1)}
	processor := New(&ProcessorConfig{
		AnalysisRepo:            store,
		AnalyzerClient:          client,
		RequireAnalyzerIdentity: true,
	})

	processor.enqueueAnalysis(context.Background(), &db.Track{ID: 42}, &TrackMetadata{
		StorageKey: "tracks/fixture/job-fixture.wav",
	})

	if store.requestCount != 1 {
		t.Fatalf("RequestAnalysis called %d time(s), want one deferred pending row", store.requestCount)
	}
	select {
	case req := <-client.requests:
		t.Fatalf("analyzer ran without a required identity: %+v", req)
	default:
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := processor.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("Shutdown returned error: %v", err)
	}
}

func TestRepairMetadataSkipsUserEditedWithoutForce(t *testing.T) {
	processor := &Processor{}
	result, err := processor.RepairMetadata(context.Background(), &db.Track{
		ID:                 42,
		Title:              "Human Fixed Title",
		MetadataUserEdited: true,
	}, MetadataRepairOptions{})
	if err != nil {
		t.Fatalf("RepairMetadata returned error: %v", err)
	}
	if result.Status != "skipped" || result.Reason != "user_edited_metadata" {
		t.Fatalf("result = %+v, want user-edited skip", result)
	}
}

func TestRequestAnalysisRepairSkipsWhenAnalyzerClientMissing(t *testing.T) {
	store := &fakeAnalysisStore{}
	processor := &Processor{analysisRepo: store}

	result, err := processor.RequestAnalysisRepair(context.Background(), &db.Track{
		ID:         42,
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
	}, AnalysisRepairOptions{})
	if err != nil {
		t.Fatalf("RequestAnalysisRepair returned error: %v", err)
	}
	if result.Status != "skipped" || result.Reason != "analyzer_client_disabled" {
		t.Fatalf("result = %+v, want analyzer disabled skip", result)
	}
	if store.repairCount != 0 {
		t.Fatalf("repair store called %d time(s) without analyzer client", store.repairCount)
	}
}

func TestRequestAnalysisRepairWaitsForRequiredAnalyzerIdentity(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1)}
	processor := New(&ProcessorConfig{
		AnalysisRepo:            store,
		AnalyzerClient:          client,
		RequireAnalyzerIdentity: true,
	})

	result, err := processor.RequestAnalysisRepair(context.Background(), &db.Track{
		ID:         42,
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
	}, AnalysisRepairOptions{})
	if err != nil {
		t.Fatalf("RequestAnalysisRepair returned error: %v", err)
	}
	if result.Status != "skipped" || result.Reason != "analyzer_identity_unavailable" || result.WaitingOn != "analyzer" {
		t.Fatalf("result = %+v, want analyzer identity wait", result)
	}
	if store.repairCount != 0 {
		t.Fatalf("repair store called %d time(s) without required analyzer identity", store.repairCount)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := processor.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("Shutdown returned error: %v", err)
	}
}

func TestRequestAnalysisRepairDoesNotRunActiveNonStaleRequest(t *testing.T) {
	store := &fakeAnalysisStore{repairResult: db.AnalysisRepairRequest{
		TrackID:        42,
		PreviousStatus: db.AnalysisStatusAnalyzing,
		Status:         db.AnalysisStatusAnalyzing,
		Queued:         false,
		Reason:         "active_not_stale",
	}}
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1)}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})

	result, err := processor.RequestAnalysisRepair(context.Background(), &db.Track{
		ID:         42,
		Title:      "Fixture Song",
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
		SourceType: sqlNullString("fixture"),
		DurationMs: sqlNullInt32(1000),
	}, AnalysisRepairOptions{})
	if err != nil {
		t.Fatalf("RequestAnalysisRepair returned error: %v", err)
	}
	if result.Queued || result.Reason != "active_not_stale" {
		t.Fatalf("result = %+v, want active non-stale skip", result)
	}
	select {
	case req := <-client.requests:
		t.Fatalf("unexpected analyzer request: %+v", req)
	default:
	}
}

func TestRequestAnalysisRepairSkipsLegacyStoreWithoutRequeue(t *testing.T) {
	store := &legacyAnalysisStore{}
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1)}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})

	result, err := processor.RequestAnalysisRepair(context.Background(), &db.Track{
		ID:         42,
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
	}, AnalysisRepairOptions{})
	if err != nil {
		t.Fatalf("RequestAnalysisRepair returned error: %v", err)
	}
	if result.Status != "skipped" || result.Reason != "analysis_repair_unsupported" || result.WaitingOn != "analysis_store" {
		t.Fatalf("result = %+v, want repair-unsupported skip", result)
	}
	if store.requestCount != 0 {
		t.Fatalf("legacy RequestAnalysis called %d time(s); repair should not use stale retry path", store.requestCount)
	}
	select {
	case req := <-client.requests:
		t.Fatalf("unexpected analyzer request: %+v", req)
	default:
	}
}

func TestRequestAnalysisRepairQueuesAndRunsAnalyzer(t *testing.T) {
	store := &fakeAnalysisStore{
		repairResult:  db.AnalysisRepairRequest{TrackID: 42, Status: db.AnalysisStatusPending, Queued: true, Reason: "failed_retry"},
		storeResultCh: make(chan db.AnalysisResult, 1),
	}
	client := &fakeAnalyzerClient{
		requests: make(chan analyzer.Request, 1),
		result: &analyzer.Result{
			SchemaVersion:  analyzer.SchemaVersion,
			SummaryJSON:    json.RawMessage(`{"bpm":{"value":124}}`),
			ArtifactsJSON:  json.RawMessage(`{"waveform_resolution":"coarse_fixture"}`),
			ProvenanceJSON: json.RawMessage(`{"analyzer":"fake"}`),
		},
	}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	processor.SetAnalyzerIdentity("omp-mir-analyzer", "2026-07-11-3")

	result, err := processor.RequestAnalysisRepair(context.Background(), &db.Track{
		ID:         42,
		Title:      "Fixture Song",
		Artist:     sqlNullString("Fixture Artist"),
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
		SourceURL:  sqlNullString("fixture://silence"),
		SourceType: sqlNullString("fixture"),
	}, AnalysisRepairOptions{})
	if err != nil {
		t.Fatalf("RequestAnalysisRepair returned error: %v", err)
	}
	if !result.Queued || result.Reason != "failed_retry" {
		t.Fatalf("result = %+v, want queued retry", result)
	}
	select {
	case req := <-client.requests:
		if req.TrackID != 42 || req.StorageKey != "tracks/fixture/job-fixture.wav" {
			t.Fatalf("request = %+v", req)
		}
		if req.ExpectedAnalyzer != "omp-mir-analyzer" || req.ExpectedAnalyzerVersion != "2026-07-11-3" {
			t.Fatalf("request missing expected analyzer identity: %+v", req)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for analyzer request")
	}
	select {
	case <-store.storeResultCh:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for stored result")
	}
}

func TestRequestAnalysisRepairWorkerOutlivesStartupMaintenanceContext(t *testing.T) {
	store := &fakeAnalysisStore{
		repairResult:  db.AnalysisRepairRequest{TrackID: 42, Status: db.AnalysisStatusPending, Queued: true},
		storeResultCh: make(chan db.AnalysisResult, 1),
	}
	client := &contextAwareAnalyzerClient{
		started: make(chan context.Context, 1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	maintenanceCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	result, err := processor.RequestAnalysisRepair(maintenanceCtx, &db.Track{
		ID:         42,
		StorageKey: sqlNullString("tracks/fixture/job-fixture.wav"),
	}, AnalysisRepairOptions{})
	if err != nil || !result.Queued {
		t.Fatalf("RequestAnalysisRepair = %+v, %v; want queued repair", result, err)
	}
	cancel()
	select {
	case workerCtx := <-client.started:
		if err := workerCtx.Err(); err != nil {
			t.Fatalf("worker inherited canceled maintenance context: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for analyzer worker")
	}
	close(client.release)
	select {
	case <-store.storeResultCh:
	case <-time.After(time.Second):
		t.Fatal("queued repair did not finish after maintenance context cancellation")
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), time.Second)
	defer shutdownCancel()
	if err := processor.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("Shutdown returned error: %v", err)
	}
}

func TestAnalysisWorkerShutdownDrainsQueuedWorkAndStopsSubmissions(t *testing.T) {
	store := &fakeAnalysisStore{storeResultCh: make(chan db.AnalysisResult, 2)}
	client := &fakeAnalyzerClient{result: &analyzer.Result{
		SchemaVersion:  analyzer.SchemaVersion,
		SummaryJSON:    json.RawMessage(`{}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"v1"}`),
	}}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	for trackID := int64(1); trackID <= 2; trackID++ {
		if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: trackID}); err != nil {
			t.Fatalf("schedule track %d: %v", trackID, err)
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := processor.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("Shutdown returned error: %v", err)
	}
	if store.storeResultCount != 2 {
		t.Fatalf("stored results = %d, want 2", store.storeResultCount)
	}
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 3}); err == nil {
		t.Fatal("scheduleAnalysis accepted work after shutdown")
	}
}

func TestAnalysisWorkerShutdownDeadlineCancelsActiveAndQueuedRows(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &blockingAnalyzerClient{
		started: make(chan int64, analysisQueueSize+1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-client.started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for active analysis")
	}
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 2}); err != nil {
		t.Fatal(err)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := processor.Shutdown(shutdownCtx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown error = %v, want deadline exceeded", err)
	}
	store.mu.Lock()
	failed := store.failedCount
	store.mu.Unlock()
	if failed != 2 {
		t.Fatalf("failed rows = %d, want active and queued rows marked failed", failed)
	}
}

func TestAnalysisWorkerShutdownDeadlineSurvivesNonCooperativeAnalyzer(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &nonCooperativeAnalyzerClient{
		started: make(chan int64, 1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{
		AnalysisRepo:        store,
		AnalyzerClient:      client,
		AnalysisConcurrency: 1,
	})
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-client.started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for non-cooperative analysis")
	}
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 2}); err != nil {
		t.Fatal(err)
	}

	const shutdownTimeout = 80 * time.Millisecond
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	started := time.Now()
	err := processor.Shutdown(shutdownCtx)
	cancel()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown error = %v, want deadline exceeded", err)
	}
	if elapsed := time.Since(started); elapsed > shutdownTimeout+100*time.Millisecond {
		t.Fatalf("Shutdown took %s, exceeded hard deadline %s", elapsed, shutdownTimeout)
	}
	store.mu.Lock()
	failedBeforeRelease := store.failedCount
	storedBeforeRelease := store.storeResultCount
	store.mu.Unlock()
	if failedBeforeRelease != 2 {
		t.Fatalf("recoverable rows = %d, want active and queued rows", failedBeforeRelease)
	}
	if storedBeforeRelease != 0 {
		t.Fatalf("stored results before release = %d, want 0", storedBeforeRelease)
	}

	close(client.release)
	settleCtx, settleCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer settleCancel()
	if err := processor.Shutdown(settleCtx); err != nil {
		t.Fatalf("second Shutdown after analyzer release returned error: %v", err)
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.storeResultCount != 0 {
		t.Fatalf("late analyzer result stored %d time(s), want 0", store.storeResultCount)
	}
	if store.failedCount != 2 {
		t.Fatalf("recovery writes = %d, want exactly one per row", store.failedCount)
	}
}

func TestAnalysisWorkerShutdownRecoversRowsWithPreExpiredContext(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &nonCooperativeAnalyzerClient{
		started: make(chan int64, 1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{
		AnalysisRepo:        store,
		AnalyzerClient:      client,
		AnalysisConcurrency: 1,
	})
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-client.started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for non-cooperative analysis")
	}
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 2}); err != nil {
		t.Fatal(err)
	}

	expiredCtx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	started := time.Now()
	err := processor.Shutdown(expiredCtx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown error = %v, want deadline exceeded", err)
	}
	if elapsed := time.Since(started); elapsed > analysisShutdownRecoveryTimeout+500*time.Millisecond {
		t.Fatalf("Shutdown took %s with pre-expired context", elapsed)
	}
	store.mu.Lock()
	failed := store.failedCount
	stored := store.storeResultCount
	store.mu.Unlock()
	if failed != 2 || stored != 0 {
		t.Fatalf("recovery state = failed:%d stored:%d, want 2/0", failed, stored)
	}

	store.closeForTest()
	close(client.release)
	waitForWaitGroup(t, &processor.analysisTasks, time.Second, "analysis tasks")
	waitForWaitGroup(t, &processor.analysisWorkers, time.Second, "analysis workers")
}

func TestAnalysisWorkerShutdownRecoveryCanExceedCallerReserve(t *testing.T) {
	baseStore := &fakeAnalysisStore{}
	store := &delayedRecoveryAnalysisStore{
		fakeAnalysisStore: baseStore,
		delay:             analysisShutdownRecoveryReserve + 100*time.Millisecond,
	}
	client := &blockingAnalyzerClient{
		started: make(chan int64, 2),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{
		AnalysisRepo:        store,
		AnalyzerClient:      client,
		AnalysisConcurrency: 1,
	})
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-client.started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for active analysis")
	}
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 2}); err != nil {
		t.Fatal(err)
	}

	callerCtx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	started := time.Now()
	err := processor.Shutdown(callerCtx)
	elapsed := time.Since(started)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown error = %v, want deadline exceeded", err)
	}
	if elapsed < store.delay {
		t.Fatalf("Shutdown returned in %s before delayed recovery %s completed", elapsed, store.delay)
	}
	if elapsed > analysisShutdownRecoveryTimeout+500*time.Millisecond {
		t.Fatalf("Shutdown took %s, exceeded bounded recovery window", elapsed)
	}
	baseStore.mu.Lock()
	failed := baseStore.failedCount
	stored := baseStore.storeResultCount
	baseStore.mu.Unlock()
	if failed != 2 || stored != 0 {
		t.Fatalf("recovery state = failed:%d stored:%d, want 2/0", failed, stored)
	}
	waitForWaitGroup(t, &processor.analysisTasks, time.Second, "analysis tasks")
	waitForWaitGroup(t, &processor.analysisWorkers, time.Second, "analysis workers")
}

func waitForWaitGroup(t *testing.T, group *sync.WaitGroup, timeout time.Duration, label string) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		group.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for %s", label)
	}
}

func TestAnalysisWorkerShutdownUnblocksSenderOnFullQueue(t *testing.T) {
	store := &fakeAnalysisStore{}
	client := &blockingAnalyzerClient{
		started: make(chan int64, analysisQueueSize+1),
		release: make(chan struct{}),
	}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 1}); err != nil {
		t.Fatal(err)
	}
	<-client.started
	for trackID := int64(2); trackID <= analysisQueueSize+1; trackID++ {
		if err := processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: trackID}); err != nil {
			t.Fatalf("fill queue at track %d: %v", trackID, err)
		}
	}

	scheduleDone := make(chan error, 1)
	go func() {
		scheduleDone <- processor.scheduleAnalysis(context.Background(), analyzer.Request{TrackID: 999})
	}()
	select {
	case err := <-scheduleDone:
		t.Fatalf("full-queue schedule returned before shutdown: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := processor.Shutdown(shutdownCtx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Shutdown error = %v, want deadline exceeded", err)
	}
	select {
	case err := <-scheduleDone:
		if err == nil || !strings.Contains(err.Error(), "shutting down") {
			t.Fatalf("blocked schedule error = %v, want shutdown error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("full-queue sender remained blocked after shutdown")
	}
	store.mu.Lock()
	failed := store.failedCount
	store.mu.Unlock()
	if failed != analysisQueueSize+1 {
		t.Fatalf("failed rows = %d, want active plus %d queued rows", failed, analysisQueueSize)
	}
}

func TestRunAnalysisDiscardsSupersededVersionWithoutTerminalOverwrite(t *testing.T) {
	store := &fakeAnalysisStore{storeResultErr: db.ErrAnalysisResultSuperseded}
	client := &fakeAnalyzerClient{result: &analyzer.Result{
		SchemaVersion:   analyzer.SchemaVersion,
		SummaryJSON:     json.RawMessage(`{}`),
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  json.RawMessage(`{"analyzer":"omp-mir-analyzer","analyzer_version":"old"}`),
		Analyzer:        "omp-mir-analyzer",
		AnalyzerVersion: "old",
	}}
	processor := &Processor{analysisRepo: store, analyzerClient: client}

	processor.runAnalysis(analyzer.Request{TrackID: 42})

	if store.failedCount != 0 || store.unsupportedCount != 0 {
		t.Fatalf("superseded result changed terminal state: failed=%d unsupported=%d", store.failedCount, store.unsupportedCount)
	}
}

func TestEnqueueAnalysisRunsConfiguredAnalyzerAndStoresResult(t *testing.T) {
	store := &fakeAnalysisStore{storeResultCh: make(chan db.AnalysisResult, 1)}
	client := &fakeAnalyzerClient{
		requests: make(chan analyzer.Request, 1),
		result: &analyzer.Result{
			SchemaVersion:  analyzer.SchemaVersion,
			SummaryJSON:    json.RawMessage("{\"bpm\":{\"value\":124},\"waveform\":{\"sample_count\":6}}"),
			ArtifactsJSON:  json.RawMessage("{\"waveform_resolution\":\"coarse_fixture\"}"),
			ProvenanceJSON: json.RawMessage("{\"analyzer\":\"fake\"}"),
		},
	}
	processor := New(&ProcessorConfig{AnalysisRepo: store, AnalyzerClient: client})
	processor.SetAnalyzerIdentity("omp-mir-analyzer", "2026-07-11-3")

	processor.enqueueAnalysis(context.Background(), &db.Track{ID: 42}, &TrackMetadata{
		StorageKey: "tracks/fixture/job-fixture.wav",
		SourceURL:  "fixture://silence",
		SourceType: "fixture",
		DurationMs: 197500,
		Title:      "Fixture Song",
		Artist:     "Fixture Artist",
	})

	select {
	case req := <-client.requests:
		if req.TrackID != 42 || req.StorageKey != "tracks/fixture/job-fixture.wav" || req.SchemaVersion != analyzer.SchemaVersion {
			t.Fatalf("analyzer request = %#v", req)
		}
		if req.ExpectedAnalyzer != "omp-mir-analyzer" || req.ExpectedAnalyzerVersion != "2026-07-11-3" {
			t.Fatalf("normal analysis request missing current analyzer identity: %#v", req)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for analyzer request")
	}
	select {
	case result := <-store.storeResultCh:
		if string(result.SummaryJSON) != string(client.result.SummaryJSON) {
			t.Fatalf("stored summary = %s, want %s", result.SummaryJSON, client.result.SummaryJSON)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for stored analysis result")
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.requestCount != 1 || store.analyzingCount != 1 || store.storeResultCount != 1 {
		t.Fatalf("analysis calls = request:%d analyzing:%d store:%d, want 1/1/1", store.requestCount, store.analyzingCount, store.storeResultCount)
	}
}

func TestRunAnalysisAppliesGenreHintAgainstPostgres(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	repo := db.NewTrackRepository(database)
	track, created, err := repo.CreateTrackFromMetadata(ctx, "Fixture Artist", "Fixture Song", "", 197500,
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("create track: %v", err)
	}
	if !created {
		t.Fatal("expected new track")
	}

	store := &fakeAnalysisStore{}
	client := &fakeAnalyzerClient{result: &analyzer.Result{
		SchemaVersion:  analyzer.SchemaVersion,
		SummaryJSON:    json.RawMessage(`{"genre_hints":[{"value":"breakbeat","confidence":0.41},{"value":"house","confidence":0.88}]}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fake"}`),
	}}
	processor := &Processor{analysisRepo: store, analyzerClient: client, trackRepo: repo}

	processor.runAnalysis(analyzer.Request{TrackID: track.ID, StorageKey: "tracks/fixture/song.wav"})

	var genre sql.NullString
	if err := database.QueryRowContext(ctx, `SELECT genre FROM tracks WHERE id = $1`, track.ID).Scan(&genre); err != nil {
		t.Fatalf("query genre: %v", err)
	}
	if !genre.Valid || genre.String != "house" {
		t.Fatalf("genre = %#v, want house", genre)
	}
}

func TestDuplicateLegacyTrackBackfillsFromExistingReferencedObject(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	existingBytes := testWAVBytes(t, 16000, 2)
	existing, created, err := trackRepo.CreateTrackFromMetadata(
		ctx, "", "Duplicate Legacy", "", 0,
		db.WithStorage("tracks/fixture/existing.wav", int64(len(existingBytes))),
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""),
	)
	if err != nil || !created {
		t.Fatalf("seed legacy track: created=%v err=%v", created, err)
	}
	objectStore := &fakeObjectStorage{objects: map[string][]byte{
		"tracks/fixture/existing.wav": existingBytes,
	}}
	p := New(&ProcessorConfig{TrackRepo: trackRepo, Storage: objectStore})
	job := &download.DownloadJob{
		ID:         "new-differing-artifact",
		URL:        "fixture://duplicate-legacy",
		SourceType: "fixture",
		Title:      "Duplicate Legacy",
	}
	if err := p.Process(ctx, job, func(int) {}); err != nil {
		t.Fatalf("process duplicate: %v", err)
	}
	reloaded, err := trackRepo.GetByID(ctx, existing.ID)
	if err != nil {
		t.Fatalf("reload legacy track: %v", err)
	}
	if reloaded.SampleRateHz.Int32 != 16000 || reloaded.Channels.Int32 != 2 || reloaded.BitrateKbps.Int32 != 512 {
		t.Fatalf("legacy track facts = sample=%v channels=%v bitrate=%v; want existing 16kHz stereo 512kbps",
			reloaded.SampleRateHz, reloaded.Channels, reloaded.BitrateKbps)
	}
	if len(objectStore.getKeys) != 1 || objectStore.getKeys[0] != "tracks/fixture/existing.wav" {
		t.Fatalf("duplicate backfill probed keys = %v, want existing referenced object", objectStore.getKeys)
	}
}

func TestDuplicateLegacyTrackWithMissingObjectStillAttachesToLibrary(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'duplicate-missing', 'x')
	`, userID, "duplicate-missing-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	trackRepo := db.NewTrackRepository(database)
	existing, created, err := trackRepo.CreateTrackFromMetadata(
		ctx, "", "Duplicate Missing Artifact", "", 0,
		db.WithStorage("tracks/fixture/missing.wav", 1234),
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""),
	)
	if err != nil || !created {
		t.Fatalf("seed legacy track: created=%v err=%v", created, err)
	}
	objectStore := &fakeObjectStorage{objects: map[string][]byte{}}
	p := New(&ProcessorConfig{
		TrackRepo:   trackRepo,
		LibraryRepo: db.NewLibraryRepository(database),
		Storage:     objectStore,
	})
	job := &download.DownloadJob{
		ID:         "new-artifact-for-missing-duplicate",
		UserID:     userID.String(),
		URL:        "fixture://duplicate-missing",
		SourceType: "fixture",
		Title:      "Duplicate Missing Artifact",
	}

	if err := p.Process(ctx, job, func(int) {}); err != nil {
		t.Fatalf("process duplicate with missing stored object: %v", err)
	}
	if job.TrackID == nil || *job.TrackID != existing.ID {
		t.Fatalf("duplicate associated track = %v, want existing %d", job.TrackID, existing.ID)
	}
	var membershipCount int
	if err := database.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM user_library WHERE user_id = $1 AND track_id = $2
	`, userID, existing.ID).Scan(&membershipCount); err != nil {
		t.Fatalf("count library membership: %v", err)
	}
	if membershipCount != 1 {
		t.Fatalf("library membership count = %d, want 1", membershipCount)
	}
	reloaded, err := trackRepo.GetByID(ctx, existing.ID)
	if err != nil {
		t.Fatalf("reload legacy track: %v", err)
	}
	if reloaded.Codec.Valid || reloaded.BitrateKbps.Valid ||
		reloaded.SampleRateHz.Valid || reloaded.Channels.Valid ||
		reloaded.ContentType.Valid {
		t.Fatalf("missing stored object acquired fabricated facts: %+v", reloaded)
	}
}

func TestAttachPlaylistImportTrackBackfillsSourceEntryIdempotently(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-source', 'x')
	`, userID, "processor-source-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	playlistRepo := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: userID, Name: "Queued source import"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	track, created, err := trackRepo.CreateTrackFromMetadata(ctx, "Source Artist", "Queued source track", "", 180000)
	if err != nil || !created {
		t.Fatalf("create track = (%#v, %v, %v), want created track", track, created, err)
	}

	sourceRepo := db.NewPlaylistSourceRepository(database)
	if err := sourceRepo.ApplyResolvedMapping(ctx, &db.PlaylistSourceBinding{
		PlaylistID:          playlist.ID,
		UserID:              userID,
		Provider:            "youtube",
		ProviderPlaylistID:  "PL_processor_source",
		CanonicalURL:        "https://www.youtube.com/playlist?list=PL_processor_source",
		SnapshotFingerprint: sql.NullString{String: "processor-source-snapshot", Valid: true},
	}, []db.ResolvedPlaylistSourceEntry{{
		ProviderEntryID: "stable-queued-entry",
		SourceURL:       "https://www.youtube.com/watch?v=queued-entry",
		SourceOrder:     0,
	}}); err != nil {
		t.Fatalf("apply source mapping: %v", err)
	}
	_, sourceEntries, err := sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil || len(sourceEntries) != 1 {
		t.Fatalf("load source entry = (%#v, %v), want one entry", sourceEntries, err)
	}
	var sourceBindingID int64
	if err := database.QueryRowContext(ctx, `SELECT source_binding_id FROM playlist_source_entries WHERE id = $1`, sourceEntries[0].ID).Scan(&sourceBindingID); err != nil {
		t.Fatalf("load source binding ID: %v", err)
	}
	var conflictingSourceEntryID int64
	if err := database.QueryRowContext(ctx, `
		INSERT INTO playlist_source_entries (source_binding_id, provider_entry_id, source_url, source_order)
		VALUES ($1, 'conflicting-entry', 'https://www.youtube.com/watch?v=conflicting-entry', 1)
		RETURNING id
	`, sourceBindingID).Scan(&conflictingSourceEntryID); err != nil {
		t.Fatalf("create conflicting source entry: %v", err)
	}

	importJobID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO playlist_import_jobs (id, user_id, playlist_id, source_url, status)
		VALUES ($1, $2, $3, $4, 'importing')
	`, importJobID, userID, playlist.ID, "https://www.youtube.com/playlist?list=PL_processor_source"); err != nil {
		t.Fatalf("create import job: %v", err)
	}
	var importItemID int64
	if err := database.QueryRowContext(ctx, `
		INSERT INTO playlist_import_items
			(import_job_id, source_index, playlist_position, source_id, source_url, title, status, download_job_id)
		VALUES ($1, 1, 0, 'stable-queued-entry', 'https://www.youtube.com/watch?v=queued-entry', 'Queued source track', 'queued', 'queued-job')
		RETURNING id
	`, importJobID).Scan(&importItemID); err != nil {
		t.Fatalf("create queued import item: %v", err)
	}

	processor := New(&ProcessorConfig{
		PlaylistRepo: playlistRepo,
		ImportRepo:   playlistimport.NewImportRepository(database),
	})
	job := &download.DownloadJob{
		ID:                   "queued-job",
		PlaylistImportJobID:  importJobID.String(),
		PlaylistImportItemID: importItemID,
		PlaylistID:           playlist.ID,
		PlaylistPosition:     0,
	}
	if err := processor.attachPlaylistImportTrack(ctx, job, track.ID); err != nil {
		t.Fatalf("complete queued import item: %v", err)
	}
	if err := processor.attachPlaylistImportTrack(ctx, job, track.ID); err != nil {
		t.Fatalf("retry queued import item: %v", err)
	}
	importRepo := playlistimport.NewImportRepository(database)
	if err := importRepo.AssociateItemSourceEntry(ctx, importItemID, sourceEntries[0].ID); err != nil {
		t.Fatalf("associate completed import item: %v", err)
	}
	if err := importRepo.AssociateItemSourceEntry(ctx, importItemID, sourceEntries[0].ID); err != nil {
		t.Fatalf("retry completed import association: %v", err)
	}
	if err := importRepo.AssociateItemSourceEntry(ctx, importItemID, conflictingSourceEntryID); !errors.Is(err, db.ErrPlaylistImportSourceLinkConflict) {
		t.Fatalf("conflicting import association error = %v, want %v", err, db.ErrPlaylistImportSourceLinkConflict)
	}

	var status string
	var itemTrackID, sourceEntryID, sourceTrackID sql.NullInt64
	if err := database.QueryRowContext(ctx, `
		SELECT i.status, i.track_id, i.playlist_source_entry_id, e.track_id
		FROM playlist_import_items AS i
		LEFT JOIN playlist_source_entries AS e ON e.id = i.playlist_source_entry_id
		WHERE i.id = $1
	`, importItemID).Scan(&status, &itemTrackID, &sourceEntryID, &sourceTrackID); err != nil {
		t.Fatalf("load completed import item: %v", err)
	}
	if status != playlistimport.ItemStatusImported || !itemTrackID.Valid || itemTrackID.Int64 != track.ID || !sourceEntryID.Valid || !sourceTrackID.Valid || sourceTrackID.Int64 != track.ID {
		t.Fatalf("completed import = status:%q item_track:%#v source_entry:%#v source_track:%#v, want linked imported track %d", status, itemTrackID, sourceEntryID, sourceTrackID, track.ID)
	}
	var membershipCount int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`, playlist.ID, track.ID).Scan(&membershipCount); err != nil {
		t.Fatalf("count playlist membership: %v", err)
	}
	if membershipCount != 1 {
		t.Fatalf("playlist membership count = %d, want 1 after retry", membershipCount)
	}
	var importedItems, queuedItems int
	if err := database.QueryRowContext(ctx, `SELECT imported_items, queued_items FROM playlist_import_jobs WHERE id = $1`, importJobID).Scan(&importedItems, &queuedItems); err != nil {
		t.Fatalf("load import counts: %v", err)
	}
	if importedItems != 1 || queuedItems != 0 {
		t.Fatalf("import counts = imported:%d queued:%d, want 1/0", importedItems, queuedItems)
	}

	legacyTrack, created, err := trackRepo.CreateTrackFromMetadata(ctx, "Legacy Artist", "Legacy queued track", "", 180000)
	if err != nil || !created {
		t.Fatalf("create legacy track = (%#v, %v, %v), want created track", legacyTrack, created, err)
	}
	legacyJobID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO playlist_import_jobs (id, user_id, playlist_id, source_url, status)
		VALUES ($1, $2, $3, $4, 'importing')
	`, legacyJobID, userID, playlist.ID, "https://www.youtube.com/playlist?list=legacy"); err != nil {
		t.Fatalf("create legacy import job: %v", err)
	}
	var legacyItemID int64
	if err := database.QueryRowContext(ctx, `
		INSERT INTO playlist_import_items
			(import_job_id, source_index, playlist_position, source_id, source_url, title, status, download_job_id)
		VALUES ($1, 1, 1, 'legacy-entry', 'https://www.youtube.com/watch?v=legacy-entry', 'Legacy queued track', 'queued', 'legacy-job')
		RETURNING id
	`, legacyJobID).Scan(&legacyItemID); err != nil {
		t.Fatalf("create legacy import item: %v", err)
	}
	legacyJob := &download.DownloadJob{
		ID:                   "legacy-job",
		PlaylistImportJobID:  legacyJobID.String(),
		PlaylistImportItemID: legacyItemID,
		PlaylistID:           playlist.ID,
		PlaylistPosition:     1,
	}
	if err := processor.attachPlaylistImportTrack(ctx, legacyJob, legacyTrack.ID); err != nil {
		t.Fatalf("complete legacy import item: %v", err)
	}
	var legacyStatus string
	var legacyItemTrackID sql.NullInt64
	if err := database.QueryRowContext(ctx, `
		SELECT status, track_id
		FROM playlist_import_items
		WHERE id = $1
	`, legacyItemID).Scan(&legacyStatus, &legacyItemTrackID); err != nil {
		t.Fatalf("load legacy import item: %v", err)
	}
	if legacyStatus != playlistimport.ItemStatusImported || !legacyItemTrackID.Valid || legacyItemTrackID.Int64 != legacyTrack.ID {
		t.Fatalf("legacy import = status:%q track:%#v, want imported track %d", legacyStatus, legacyItemTrackID, legacyTrack.ID)
	}
	var legacyMembershipCount int
	if err := database.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM playlist_tracks
		WHERE playlist_id = $1 AND track_id = $2
	`, playlist.ID, legacyTrack.ID).Scan(&legacyMembershipCount); err != nil {
		t.Fatalf("count legacy playlist membership: %v", err)
	}
	if legacyMembershipCount != 1 {
		t.Fatalf("legacy playlist membership count = %d, want 1", legacyMembershipCount)
	}
}

func newProcessorPostgresTestDB(t *testing.T) (*db.DB, context.Context) {
	t.Helper()
	dsn := testutil.PostgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres processor integration tests")
	}
	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })
	database := &db.DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.ExecContext(context.Background(), `TRUNCATE TABLE tracks RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}
	return database, context.Background()
}

func TestRunAnalysisMapsAnalyzerErrorsToTerminalStates(t *testing.T) {
	tests := []struct {
		name            string
		err             error
		wantFailed      int
		wantUnsupported int
	}{
		{name: "unsupported", err: analyzer.ErrUnsupported, wantUnsupported: 1},
		{name: "failure", err: errors.New("transport failed"), wantFailed: 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := &fakeAnalysisStore{}
			processor := &Processor{
				analysisRepo:   store,
				analyzerClient: &fakeAnalyzerClient{err: tt.err},
			}

			processor.runAnalysis(analyzer.Request{TrackID: 42, StorageKey: "tracks/fixture/job-fixture.wav"})

			store.mu.Lock()
			defer store.mu.Unlock()
			if store.analyzingCount != 1 {
				t.Fatalf("MarkAnalyzing called %d time(s), want 1", store.analyzingCount)
			}
			if store.failedCount != tt.wantFailed || store.unsupportedCount != tt.wantUnsupported {
				t.Fatalf("terminal calls = failed:%d unsupported:%d, want failed:%d unsupported:%d", store.failedCount, store.unsupportedCount, tt.wantFailed, tt.wantUnsupported)
			}
		})
	}
}

func TestApplyDeterministicCleanupPorterRobinsonOfficialVideo(t *testing.T) {
	metadata := &TrackMetadata{
		Title:  "Porter Robinson - Cheerleader (Official Music Video)",
		Artist: "Porter RobinsonVEVO",
	}

	cleanup := applyDeterministicCleanup(metadata)

	if !cleanup.Applied {
		t.Fatalf("expected deterministic cleanup to apply")
	}
	if metadata.Artist != "Porter Robinson" || metadata.Title != "Cheerleader" {
		t.Fatalf("metadata = artist %q title %q, want Porter Robinson/Cheerleader", metadata.Artist, metadata.Title)
	}
	if cleanup.Method != "separator" || cleanup.Confidence <= 0 {
		t.Fatalf("cleanup = method %q confidence %v, want separator with confidence", cleanup.Method, cleanup.Confidence)
	}
}

func TestApplyDeterministicCleanupDoesNotUseUploaderWhenTitleIsWeak(t *testing.T) {
	metadata := &TrackMetadata{
		Title:    "Cheerleader (Official Music Video)",
		Artist:   "Porter RobinsonVEVO",
		Uploader: "Porter RobinsonVEVO",
	}

	cleanup := applyDeterministicCleanup(metadata)

	if cleanup.Applied {
		t.Fatalf("weak non-separator title should not rewrite provider metadata")
	}
	if metadata.Artist != "Porter RobinsonVEVO" || metadata.Title != "Cheerleader (Official Music Video)" {
		t.Fatalf("metadata changed on weak parse: artist %q title %q", metadata.Artist, metadata.Title)
	}
}

func TestMetadataProvenanceRetainsRawProviderAndCleanup(t *testing.T) {
	metadata := &TrackMetadata{
		Title:      "Madeon // All My Friends (Visualizer) [HD]",
		Artist:     "madeonofficial",
		Uploader:   "madeonofficial",
		DurationMs: 190000,
		SourceURL:  "https://youtu.be/example",
		SourceType: "youtube",
		Raw: map[string]interface{}{
			"title":         "Madeon // All My Friends (Visualizer) [HD]",
			"uploader":      "madeonofficial",
			"thumbnail_url": "https://img.example/front.jpg",
			"source_quality": map[string]interface{}{
				"score":          88,
				"classification": "official_audio",
				"recommendation": "preferred",
			},
		},
	}
	cleanup := applyDeterministicCleanup(metadata)
	provenance := metadataProvenance(metadata, cleanup)

	var decoded map[string]interface{}
	if err := json.Unmarshal(provenance, &decoded); err != nil {
		t.Fatalf("provenance is invalid JSON: %v", err)
	}
	provider := decoded["raw_provider"].(map[string]interface{})
	if provider["title"] != "Madeon // All My Friends (Visualizer) [HD]" {
		t.Fatalf("raw provider title = %v", provider["title"])
	}
	sourceQuality := provider["source_quality"].(map[string]interface{})
	if sourceQuality["classification"] != "official_audio" {
		t.Fatalf("source quality provenance = %#v", sourceQuality)
	}
	deterministic := decoded["deterministic"].(map[string]interface{})
	if deterministic["artist"] != "Madeon" || deterministic["title"] != "All My Friends" || deterministic["applied"] != true {
		t.Fatalf("deterministic provenance = %#v", deterministic)
	}
}

func TestProviderMetadataSkipsOnlyEmptyStrings(t *testing.T) {
	metadata := &TrackMetadata{
		Title: "Fallback Title",
		Raw: map[string]interface{}{
			"title":         "",
			"thumbnail":     []interface{}{"https://img.example/front.jpg"},
			"thumbnail_url": map[string]interface{}{"url": "https://img.example/front.jpg"},
			"duration":      float64(180),
		},
	}

	provider := providerMetadata(metadata)
	if provider["title"] != "Fallback Title" {
		t.Fatalf("empty raw title should fall back to metadata title, got %#v", provider["title"])
	}
	if _, ok := provider["thumbnail"]; !ok {
		t.Fatalf("non-string thumbnail array was incorrectly skipped")
	}
	if _, ok := provider["thumbnail_url"]; !ok {
		t.Fatalf("non-string thumbnail_url object was incorrectly skipped")
	}
}

func TestFailedMBMatchUpdateLeavesIdentityAndRespectsUserEdits(t *testing.T) {
	update := failedMBMatchUpdate(errors.New("musicbrainz unavailable"))

	if update.MBVerified != nil || update.ApplyMBIdentity {
		t.Fatalf("failure fallback should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic failure update must respect sticky user edits")
	}
	if update.MetadataStatus != "failed" {
		t.Fatalf("status = %q, want failed", update.MetadataStatus)
	}
	if !update.ClearMetadataConfidence {
		t.Fatalf("automatic failure update must clear stale confidence")
	}
}

func TestAutomaticMBMatchUpdateLowConfidenceLeavesIdentityUnchanged(t *testing.T) {
	output := &matcher.MatchOutput{
		Verified: false,
		BestMatch: &matcher.MatchResult{
			MBID:        "11111111-1111-1111-1111-111111111111",
			ArtistMBID:  "22222222-2222-2222-2222-222222222222",
			ReleaseID:   "33333333-3333-3333-3333-333333333333",
			Title:       "Suggested Title",
			Artist:      "Suggested Artist",
			Confidence:  0.63,
			CoverArtURL: "https://coverartarchive.org/release/33333333-3333-3333-3333-333333333333/front-250",
		},
		Suggestions: []matcher.MatchResult{
			{MBID: "11111111-1111-1111-1111-111111111111", Title: "Suggested Title", Artist: "Suggested Artist", Confidence: 0.63},
		},
	}

	update := automaticMBMatchUpdate(output)
	if update.MBVerified != nil || update.ApplyMBIdentity || update.MBRecordingID != nil || update.MBArtistID != nil || update.MBReleaseID != nil {
		t.Fatalf("low-confidence suggestion should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic suggestion update must respect sticky user edits")
	}
	if update.MetadataStatus != "suggested" || update.MetadataJSON == nil {
		t.Fatalf("low-confidence suggestion metadata not persisted correctly: status=%q json=%s", update.MetadataStatus, string(update.MetadataJSON))
	}
	if update.ClearMetadataConfidence {
		t.Fatalf("low-confidence suggestion should keep its current confidence")
	}
}

func TestAutomaticMBMatchUpdateNoMatchLeavesIdentityUnchanged(t *testing.T) {
	update := automaticMBMatchUpdate(&matcher.MatchOutput{Verified: false})

	if update.MBVerified != nil || update.ApplyMBIdentity || update.MBRecordingID != nil || update.MBArtistID != nil || update.MBReleaseID != nil {
		t.Fatalf("no-match fallback should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic no-match update must respect sticky user edits")
	}
	if update.MetadataStatus != "no_match" {
		t.Fatalf("status = %q, want no_match", update.MetadataStatus)
	}
	if !update.ClearMetadataConfidence {
		t.Fatalf("automatic no-match update must clear stale confidence")
	}
}

func TestDownloadAndStoreFixtureCreatesPlayableWAVObject(t *testing.T) {
	storage := &fakeObjectStorage{}
	processor := &Processor{storage: storage}
	job := &download.DownloadJob{
		ID:         "job-fixture",
		UserID:     "00000000-0000-0000-0000-000000000001",
		URL:        "fixture://silence",
		SourceType: "fixture",
		Title:      "Fixture Silence",
	}

	metadata, err := processor.downloadAndStore(context.Background(), job)
	if err != nil {
		t.Fatalf("downloadAndStore failed: %v", err)
	}
	if metadata.StorageKey != "tracks/fixture/job-fixture.wav" {
		t.Fatalf("unexpected storage key %q", metadata.StorageKey)
	}
	if metadata.FileSizeBytes <= 44 {
		t.Fatalf("expected wav payload bigger than header, got %d", metadata.FileSizeBytes)
	}
	if storage.contentType != "audio/wav" {
		t.Fatalf("expected audio/wav, got %s", storage.contentType)
	}
	if metadata.AudioQuality.Codec != "pcm_s16le" ||
		metadata.AudioQuality.BitrateKbps != 128 ||
		metadata.AudioQuality.SampleRateHz != 8000 ||
		metadata.AudioQuality.Channels != 1 ||
		metadata.AudioQuality.ContentType != "audio/wav" {
		t.Fatalf("unexpected ffprobe facts: %+v", metadata.AudioQuality)
	}
	if !bytes.HasPrefix(storage.data, []byte("RIFF")) || !bytes.Contains(storage.data[:16], []byte("WAVE")) {
		t.Fatalf("uploaded object is not a RIFF/WAVE fixture")
	}
}

func TestHasCompleteAudioQualityRejectsEmptyAndNonPositiveFacts(t *testing.T) {
	complete := &db.Track{
		Codec:        sql.NullString{String: "mp3", Valid: true},
		BitrateKbps:  sql.NullInt32{Int32: 137, Valid: true},
		SampleRateHz: sql.NullInt32{Int32: 44100, Valid: true},
		Channels:     sql.NullInt32{Int32: 2, Valid: true},
		ContentType:  sql.NullString{String: "audio/mpeg", Valid: true},
	}
	if !hasCompleteAudioQuality(complete) {
		t.Fatal("complete artifact facts were rejected")
	}
	incomplete := *complete
	incomplete.BitrateKbps.Int32 = 0
	if hasCompleteAudioQuality(&incomplete) {
		t.Fatal("zero bitrate was treated as complete")
	}
	incomplete = *complete
	incomplete.Codec.String = " "
	if hasCompleteAudioQuality(&incomplete) {
		t.Fatal("blank codec was treated as complete")
	}
}

func TestDownloadAndStoreUsesProbeContentTypeDespiteMisleadingExtension(t *testing.T) {
	wavPath, _, err := writeFixtureWAV("misleading-extension")
	if err != nil {
		t.Fatalf("write fixture wav: %v", err)
	}
	defer os.Remove(wavPath)
	misleadingPath := strings.TrimSuffix(wavPath, ".wav") + ".mp3"
	if err := os.Rename(wavPath, misleadingPath); err != nil {
		t.Fatalf("rename fixture: %v", err)
	}
	defer os.Remove(misleadingPath)

	objectStore := &fakeObjectStorage{}
	p := &Processor{storage: objectStore}
	metadata, err := p.downloadAndStore(context.Background(), &download.DownloadJob{
		ID:         "misleading-extension",
		URL:        "file://" + misleadingPath,
		SourceType: "file",
	})
	if err != nil {
		t.Fatalf("downloadAndStore: %v", err)
	}
	if metadata.AudioQuality.ContentType != "audio/wav" || objectStore.contentType != "audio/wav" {
		t.Fatalf("probe/upload content types = %q/%q, want audio/wav", metadata.AudioQuality.ContentType, objectStore.contentType)
	}
}

func TestProbeAudioFileUsesStdoutOnlyForJSON(t *testing.T) {
	ffprobe := filepath.Join(t.TempDir(), "ffprobe")
	script := `#!/bin/sh
echo "diagnostic noise" >&2
printf '%s\n' '{"streams":[{"codec_name":"mp3","bit_rate":"137000","sample_rate":"44100","channels":2}],"format":{"bit_rate":"137000","format_name":"mp3"}}'
`
	if err := os.WriteFile(ffprobe, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake ffprobe: %v", err)
	}
	t.Setenv("PATH", filepath.Dir(ffprobe)+string(os.PathListSeparator)+os.Getenv("PATH"))

	quality, err := probeAudioFile(context.Background(), "ignored.mp3", "audio/mpeg")
	if err != nil {
		t.Fatalf("probe with exit-0 stderr noise: %v", err)
	}
	if quality.Codec != "mp3" || quality.BitrateKbps != 137 ||
		quality.SampleRateHz != 44100 || quality.Channels != 2 ||
		quality.ContentType != "audio/mpeg" {
		t.Fatalf("quality = %+v", quality)
	}
}

func TestAudioContentTypeUsesAACContainer(t *testing.T) {
	if got := audioContentType("aac", "mov,mp4,m4a,3gp,3g2,mj2", "audio/aac"); got != "audio/mp4" {
		t.Fatalf("AAC in MP4 content type = %q, want audio/mp4", got)
	}
	if got := audioContentType("aac", "adts,aac", "application/octet-stream"); got != "audio/aac" {
		t.Fatalf("raw AAC content type = %q, want audio/aac", got)
	}
}

func TestRunYTDLPCleansTempDirAfterSuccess(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
out=""
max=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "--max-filesize" ]; then max="$arg"; fi
  prev="$arg"
done
[ -n "$out" ]
[ "$max" = "268435456" ]
audio="${out%.*}.mp3"
printf 'fake mp3 data' > "$audio"
printf '{"title":"Downloaded Title","duration":2}' > "${out%.*}.info.json"
`)
	metadata := &TrackMetadata{}

	path, contentType, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=1", metadata, maxYTDLPOutputBytes)
	if err != nil {
		t.Fatalf("runYTDLPCommand failed: %v", err)
	}
	defer os.Remove(path)

	if contentType != "audio/mpeg" {
		t.Fatalf("content type = %q, want audio/mpeg", contentType)
	}
	if metadata.Title != "Downloaded Title" || metadata.DurationMs != 2000 {
		t.Fatalf("metadata = title %q duration %d, want Downloaded Title/2000", metadata.Title, metadata.DurationMs)
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after success: %v", leaked)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("returned copied audio missing: %v", err)
	}
}

func TestRunYTDLPRejectsOversizeOutputAndCleansTempDir(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
out=""
max=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "--max-filesize" ]; then max="$arg"; fi
  prev="$arg"
done
[ -n "$out" ]
[ "$max" = "8" ]
audio="${out%.*}.mp3"
head -c 32 /dev/zero > "$audio"
`)

	path, _, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=oversize", &TrackMetadata{}, 8)
	if err == nil {
		os.Remove(path)
		t.Fatalf("runYTDLPCommand oversize succeeded with path %q", path)
	}
	if !strings.Contains(err.Error(), "too large") {
		t.Fatalf("oversize error = %v, want too large", err)
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after oversize: %v", leaked)
	}
}

func TestRunYTDLPCleansTempDirAfterCommandFailure(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
printf 'nope' >&2
exit 7
`)

	_, _, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=fail", &TrackMetadata{}, maxYTDLPOutputBytes)
	if err == nil {
		t.Fatalf("runYTDLPCommand failure succeeded")
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after failure: %v", leaked)
	}
}

func writeFakeYTDLP(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "yt-dlp-fake")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatalf("write fake yt-dlp: %v", err)
	}
	return path
}

func snapshotYTDLPTempDirs(t *testing.T) map[string]struct{} {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "omp-ytdlp-*"))
	if err != nil {
		t.Fatalf("glob temp dirs: %v", err)
	}
	seen := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		seen[match] = struct{}{}
	}
	return seen
}

func newYTDLPTempDirs(t *testing.T, before map[string]struct{}) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "omp-ytdlp-*"))
	if err != nil {
		t.Fatalf("glob temp dirs: %v", err)
	}
	var leaked []string
	for _, match := range matches {
		if _, ok := before[match]; !ok {
			leaked = append(leaked, match)
		}
	}
	return leaked
}
