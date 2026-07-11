package processor

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
)

type fakeObjectStorage struct {
	key         string
	contentType string
	data        []byte
}

func (s *fakeObjectStorage) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error {
	s.key = key
	s.contentType = contentType
	s.data, _ = io.ReadAll(reader)
	return nil
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
	failedCount      int
	unsupportedCount int
}

type legacyAnalysisStore struct {
	requestCount int
}

func (s *fakeAnalysisStore) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requestCount++
	return nil
}

func (s *fakeAnalysisStore) RequestRepairAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage, force bool, staleAfter time.Duration) (db.AnalysisRepairRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.repairCount++
	if s.repairResult.TrackID == 0 {
		s.repairResult.TrackID = trackID
	}
	return s.repairResult, nil
}

func (s *fakeAnalysisStore) MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.analyzingCount++
	return nil
}

func (s *fakeAnalysisStore) StoreResult(ctx context.Context, trackID int64, result db.AnalysisResult) error {
	s.mu.Lock()
	s.storeResultCount++
	s.storedResult = result
	ch := s.storeResultCh
	s.mu.Unlock()
	if ch != nil {
		ch <- result
	}
	return nil
}

func (s *fakeAnalysisStore) MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failedCount++
	return nil
}

func (s *fakeAnalysisStore) MarkUnsupported(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.unsupportedCount++
	return nil
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

type blockingAnalyzerClient struct {
	mu        sync.Mutex
	active    int
	maxActive int
	started   chan int64
	release   chan struct{}
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
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for analyzer request")
	}
	select {
	case <-store.storeResultCh:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for stored result")
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

func newProcessorPostgresTestDB(t *testing.T) (*db.DB, context.Context) {
	t.Helper()
	dsn := os.Getenv("OMP_POSTGRES_TEST_DSN")
	if dsn == "" {
		dsn = os.Getenv("QA_DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres processor integration tests")
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
	if !bytes.HasPrefix(storage.data, []byte("RIFF")) || !bytes.Contains(storage.data[:16], []byte("WAVE")) {
		t.Fatalf("uploaded object is not a RIFF/WAVE fixture")
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
