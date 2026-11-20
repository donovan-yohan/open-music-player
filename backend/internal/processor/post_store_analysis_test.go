package processor

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
)

const canonicalAnalysisKey = "tracks/canonical-a.wav"

func fixtureSHA256(body []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(body)) }

type analysisWireCapture struct {
	body []byte
	hash string
	size int64
}

// Exercise the real ServiceClient serializer and HTTP path. The receiving
// fixture opens the object named on the wire, not the expected fixture key.
func newAnalysisWireFixture(t *testing.T, objects ObjectStorage, status int) (*analyzer.ServiceClient, <-chan analysisWireCapture, *atomic.Int32) {
	t.Helper()
	seen := make(chan analysisWireCapture, 4)
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/analyze" || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("unexpected analyzer request: %s %s (%s)", r.Method, r.URL.Path, r.Header.Get("Content-Type"))
			http.Error(w, "wrong analyzer endpoint", http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(r.Body)
		var input struct {
			StorageKey string `json:"storage_key"`
		}
		if err != nil || json.Unmarshal(body, &input) != nil {
			t.Errorf("unreadable analyzer payload: %s, %v", body, err)
			http.Error(w, "bad analyzer request", http.StatusBadRequest)
			return
		}
		reader, _, err := objects.GetObject(r.Context(), input.StorageKey)
		if err != nil {
			t.Errorf("open analyzer input %q: %v", input.StorageKey, err)
			http.Error(w, "missing object", http.StatusNotFound)
			return
		}
		defer reader.Close()
		audio, err := io.ReadAll(reader)
		if err != nil {
			t.Errorf("read analyzer input: %v", err)
			http.Error(w, "unreadable object", http.StatusBadRequest)
			return
		}
		select {
		case seen <- analysisWireCapture{body, fixtureSHA256(audio), int64(len(audio))}:
		default:
			t.Error("unexpected repeated analyzer request")
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"schema_version":1,"summary":{"bpm":{"value":124}},"artifacts":{},"provenance":{"analyzer":"fixture","analyzer_version":"v1"}}`)
	}))
	t.Cleanup(server.Close)
	client, err := analyzer.NewServiceClient(analyzer.ServiceConfig{Enabled: true, BaseURL: server.URL, Client: server.Client(), Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	return client, seen, &calls
}

func receiveAnalysisWire(t *testing.T, seen <-chan analysisWireCapture) analysisWireCapture {
	t.Helper()
	select {
	case capture := <-seen:
		return capture
	case <-time.After(5 * time.Second):
		t.Fatal("no real analyzer HTTP request observed")
		return analysisWireCapture{}
	}
}

func drainAnalysisForTest(t *testing.T, p *Processor) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.Shutdown(ctx); err != nil {
		t.Fatalf("drain analysis: %v", err)
	}
}

// Record the store admission boundary, including losing claims. The real SQL
// repository owns and independently tests the conflict predicate for statuses.
type postStoreRecordingAnalysis struct {
	fakeAnalysisStore
	provenance json.RawMessage
	decisions  []bool
	onClaim    func()
}

func (s *postStoreRecordingAnalysis) RequestAnalysisIfNeeded(ctx context.Context, trackID int64, provenance json.RawMessage) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if _, ok := ctx.Deadline(); !ok {
		return false, fmt.Errorf("post-commit claim has no deadline")
	}
	if trackID != 42 {
		return false, fmt.Errorf("unexpected track ID %d", trackID)
	}
	i := s.requestCount
	s.requestCount++
	shouldQueue := i < len(s.decisions) && s.decisions[i]
	if shouldQueue {
		s.provenance = append(json.RawMessage(nil), provenance...)
		if s.onClaim != nil {
			s.onClaim()
		}
	}
	return shouldQueue, nil
}

func privateAnalysisFixture(t *testing.T) (*db.TrackRepository, *processorSQLFake, *fakeObjectStorage, *db.Track, []byte) {
	t.Helper()
	audio := testWAVBytes(t, 16000, 1)
	track := &db.Track{
		ID: 42, StorageKey: sqlNullString(canonicalAnalysisKey), FileSizeBytes: sql.NullInt64{Int64: int64(len(audio)), Valid: true},
		DurationMs: sql.NullInt32{Int32: 1000, Valid: true}, SourceURL: sqlNullString("file:///private/original-name.wav"),
		SourceType: sqlNullString("private-fixture"), Title: "private title", Artist: sqlNullString("private artist"),
	}
	database, fakeSQL := newProcessorSQLFake(t)
	fakeSQL.postStoreTrack, fakeSQL.canonicalHash = track, fixtureSHA256(audio)
	return db.NewTrackRepository(database), fakeSQL, &fakeObjectStorage{objects: map[string][]byte{canonicalAnalysisKey: audio}}, track, audio
}

func TestPostStoreLibraryUploadAnalyzesCanonicalStoredAudio(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
	}{
		{"analyzed", http.StatusOK},
		{"unsupported", http.StatusUnsupportedMediaType},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo, sqlFixture, objects, track, audio := privateAnalysisFixture(t)
			client, seen, calls := newAnalysisWireFixture(t, objects, tc.status)
			store := &postStoreRecordingAnalysis{decisions: []bool{true, false}}
			p := New(&ProcessorConfig{TrackRepo: repo, AnalysisRepo: store, AnalyzerClient: client, Storage: objects, RequireAnalyzerIdentity: true})
			matcher := &fakeMetadataMatcher{err: errors.New("post-store analysis must not match metadata")}
			p.matcher = matcher
			t.Cleanup(func() { drainAnalysisForTest(t, p) })
			p.SetAnalyzerIdentity("fixture", "v1")

			// The upload already committed; caller disconnect/deadline cannot own this claim.
			caller, cancel := context.WithTimeout(context.Background(), 0)
			defer cancel()
			if queued, err := p.SchedulePostStoreAnalysis(caller, track, PostStoreLibraryUpload); err != nil || !queued {
				t.Fatalf("canonical upload after caller cancellation: queued=%v err=%v", queued, err)
			}
			wire := receiveAnalysisWire(t, seen)
			want := fmt.Sprintf(`{"schema_version":%d,"track_id":42,"storage_key":%q,"duration_ms":1000,"expected_analyzer":"fixture","expected_analyzer_version":"v1"}`, analyzer.SchemaVersion, canonicalAnalysisKey)
			if string(wire.body) != want || wire.hash != fixtureSHA256(audio) || wire.size != int64(len(audio)) {
				t.Fatalf("canonical analyzer input = %s, %s/%d; want %s, %s/%d", wire.body, wire.hash, wire.size, want, fixtureSHA256(audio), len(audio))
			}
			t.Logf("analyzer POST /analyze body=%s opened=%s bytes=%d", wire.body, wire.hash, wire.size)
			assertStoredSource(t, store.provenance, "post_library_upload", canonicalAnalysisKey, wire.hash, wire.size, 1000, "private-fixture")
			finished := make(chan struct{})
			go func() { p.analysisTasks.Wait(); close(finished) }()
			select {
			case <-finished:
			case <-time.After(5 * time.Second):
				t.Fatal("analyzer never recorded a terminal outcome")
			}
			if queued, err := p.SchedulePostStoreAnalysis(caller, track, PostStoreLibraryUpload); err != nil || queued {
				t.Fatalf("repeat %s import: queued=%v err=%v", tc.name, queued, err)
			}
			drainAnalysisForTest(t, p)
			if calls.Load() != 1 || store.requestCount != 2 || store.analyzingCount != 1 || store.failedCount != 0 {
				t.Fatalf("analysis runs=%d claims=%d starts=%d failed=%d", calls.Load(), store.requestCount, store.analyzingCount, store.failedCount)
			}
			if objects.key != "" || len(objects.getKeys) != 1 || matcher.matchCalls != 0 || matcher.nonMusicCalls != 0 {
				t.Fatal("post-commit analysis repeated storage or matching work")
			}
			if tc.status == http.StatusOK {
				if store.storeResultCount != 1 || string(store.storedResult.SummaryJSON) != `{"bpm":{"value":124}}` || store.unsupportedCount != 0 || sqlFixture.genreHintCalls != 1 {
					t.Fatalf("ordinary analyzer result not stored: %+v", store.storedResult)
				}
			} else if store.unsupportedCount != 1 || store.storeResultCount != 0 || sqlFixture.genreHintCalls != 0 {
				t.Fatalf("unsupported requests=%d results=%d", store.unsupportedCount, store.storeResultCount)
			}
		})
	}
}

func assertStoredSource(t *testing.T, provenance json.RawMessage, trigger, key, hash string, size int64, duration int, sourceType string) {
	t.Helper()
	var got struct {
		Trigger string `json:"trigger"`
		Source  struct {
			Key        string `json:"storage_key"`
			Hash       string `json:"source_file_hash"`
			Size       int64  `json:"file_size_bytes"`
			Duration   int    `json:"duration_ms"`
			SourceType string `json:"source_type"`
		} `json:"source"`
	}
	if err := json.Unmarshal(provenance, &got); err != nil || got.Trigger != trigger || got.Source.Key != key || got.Source.Hash != hash || got.Source.Size != size || got.Source.Duration != duration || got.Source.SourceType != sourceType {
		t.Fatalf("source provenance = %s (%v); want %s %s %s %d %d %s", provenance, err, trigger, key, hash, size, duration, sourceType)
	}
	t.Logf("analysis claim provenance=%s", provenance)
}

func TestPostStoreLibraryUploadRejectsUnprovenSource(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*db.Track, *processorSQLFake)
	}{
		{"missing key", func(track *db.Track, _ *processorSQLFake) { track.StorageKey = sql.NullString{} }},
		{"missing persisted track", func(_ *db.Track, sql *processorSQLFake) { sql.postStoreTrack = nil }},
		{"candidate key", func(track *db.Track, _ *processorSQLFake) { track.StorageKey = sqlNullString("tracks/candidate-b.wav") }},
		{"candidate length", func(track *db.Track, _ *processorSQLFake) { track.FileSizeBytes.Int64++ }},
		{"candidate duration", func(track *db.Track, _ *processorSQLFake) { track.DurationMs.Int32++ }},
		{"missing persisted hash", func(_ *db.Track, sql *processorSQLFake) { sql.canonicalHash = "" }},
		{"malformed persisted hash", func(_ *db.Track, sql *processorSQLFake) { sql.canonicalHash = "sha256:" + strings.Repeat("g", 64) }},
		{"noncanonical persisted hash", func(_ *db.Track, sql *processorSQLFake) { sql.canonicalHash = "sha256:" + strings.Repeat("A", 64) }},
		{"missing persisted length", func(track *db.Track, sql *processorSQLFake) {
			track.FileSizeBytes.Int64 = 0
			sql.postStoreTrack.FileSizeBytes.Int64 = 0
		}},
		{"missing measured duration", func(track *db.Track, sql *processorSQLFake) {
			track.DurationMs.Int32 = 0
			sql.postStoreTrack.DurationMs.Int32 = 0
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo, sql, _, canonical, _ := privateAnalysisFixture(t)
			input := *canonical
			tc.mutate(&input, sql)
			store := &postStoreRecordingAnalysis{decisions: []bool{true}}
			client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1), err: analyzer.ErrUnsupported}
			p := New(&ProcessorConfig{TrackRepo: repo, AnalysisRepo: store, AnalyzerClient: client})
			t.Cleanup(func() { drainAnalysisForTest(t, p) })
			if queued, err := p.SchedulePostStoreAnalysis(context.Background(), &input, PostStoreLibraryUpload); err == nil || queued {
				t.Fatalf("unproven source accepted: queued=%v err=%v", queued, err)
			}
			drainAnalysisForTest(t, p)
			if store.requestCount != 0 || len(client.requests) != 0 {
				t.Fatal("unproven source reached the analysis store or analyzer")
			}
		})
	}
}

func TestPostStoreLibraryUploadDefersForIdentityAndHonorsPending(t *testing.T) {
	repo, _, _, track, _ := privateAnalysisFixture(t)
	store := &postStoreRecordingAnalysis{decisions: []bool{true, false}}
	client := &fakeAnalyzerClient{requests: make(chan analyzer.Request, 1), err: analyzer.ErrUnsupported}
	p := New(&ProcessorConfig{TrackRepo: repo, AnalysisRepo: store, AnalyzerClient: client, RequireAnalyzerIdentity: true})
	t.Cleanup(func() { drainAnalysisForTest(t, p) })
	if queued, err := p.SchedulePostStoreAnalysis(context.Background(), track, PostStoreLibraryUpload); err != nil || queued || store.requestCount != 1 {
		t.Fatalf("unavailable identity did not retain one pending intent without dispatch: queued=%v claims=%d err=%v", queued, store.requestCount, err)
	}
	deferred := string(store.provenance)
	if !strings.Contains(deferred, `"expected_analyzer":"","expected_analyzer_version":""`) {
		t.Fatalf("pending intent has incorrect identity provenance: %s", deferred)
	}
	p.SetAnalyzerIdentity("fixture", "v1")
	if queued, err := p.SchedulePostStoreAnalysis(context.Background(), track, PostStoreLibraryUpload); err != nil || queued || store.requestCount != 2 {
		t.Fatalf("existing pending claim was not honored: queued=%v claims=%d err=%v", queued, store.requestCount, err)
	}
	drainAnalysisForTest(t, p)
	if string(store.provenance) != deferred || len(client.requests) != 0 {
		t.Fatal("pending claim changed provenance or reached analyzer")
	}
}

type recordingDispatchRecovery struct {
	postStoreRecordingAnalysis
	recoveryErr error
}

func (s *recordingDispatchRecovery) MarkFailed(ctx context.Context, trackID int64, reason string, provenance json.RawMessage) error {
	if _, ok := ctx.Deadline(); !ok {
		s.recoveryErr = errors.New("queue recovery has no deadline")
		return s.recoveryErr
	}
	if err := ctx.Err(); err != nil {
		s.recoveryErr = err
		return err
	}
	return s.fakeAnalysisStore.MarkFailed(ctx, trackID, reason, provenance)
}

func TestPostStoreLibraryUploadRetiresClaimWhenQueueAdmissionCanceled(t *testing.T) {
	repo, _, _, track, _ := privateAnalysisFixture(t)
	owner, cancel := context.WithCancel(context.Background())
	defer cancel()
	store := &recordingDispatchRecovery{postStoreRecordingAnalysis: postStoreRecordingAnalysis{decisions: []bool{true}, onClaim: cancel}}
	queue := make(chan analysisTask, 1)
	queue <- analysisTask{request: analyzer.Request{TrackID: 99}}
	p := &Processor{
		trackRepo: repo, analysisRepo: store, analyzerClient: &fakeAnalyzerClient{},
		analysisCtx: owner, analysisQueue: queue, analysisStop: make(chan struct{}),
		analysisOutstanding: make(map[uint64]analyzer.Request),
	}
	if queued, err := p.SchedulePostStoreAnalysis(context.Background(), track, PostStoreLibraryUpload); queued || !errors.Is(err, context.Canceled) {
		t.Fatalf("full queue after processor cancellation: queued=%v err=%v", queued, err)
	}
	if store.requestCount != 1 || store.failedCount != 1 || store.recoveryErr != nil || len(p.analysisOutstanding) != 0 || len(queue) != 1 || (<-queue).request.TrackID != 99 {
		t.Fatalf("queue failure did not retire its own claim: claims=%d failed=%d recovery err=%v outstanding=%d", store.requestCount, store.failedCount, store.recoveryErr, len(p.analysisOutstanding))
	}
}
