package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/processor"
)

func TestNewSourceQualityJudgeDisabledConfigReturnsNil(t *testing.T) {
	judge := newSourceQualityJudge(&config.Config{SourceQualityLLMEnabled: false})
	if judge != nil {
		t.Fatal("disabled source-quality config should not construct a judge")
	}
}

func TestNewSourceQualityJudgeEnabledConfigConstructsOllamaJudge(t *testing.T) {
	judge := newSourceQualityJudge(&config.Config{
		SourceQualityLLMEnabled: true,
		SourceQualityLLMBaseURL: "http://ollama.example:11434",
		SourceQualityLLMModel:   "source-quality-judge",
		SourceQualityLLMTimeout: time.Second,
		SourceQualityLLMAPIKey:  "test-secret",
	})
	if _, ok := judge.(*discovery.OllamaSourceQualityJudge); !ok {
		t.Fatalf("newSourceQualityJudge() = %T, want *discovery.OllamaSourceQualityJudge", judge)
	}
}

func TestNewAgentToolsHandlerRequiresServiceToken(t *testing.T) {
	search := discovery.NewService(discovery.ServiceConfig{})
	if handler := newAgentToolsHandler(&config.Config{FirecrawlAPIKey: "configured"}, search); handler != nil {
		t.Fatal("agent tools must be absent without service token")
	}
	if handler := newAgentToolsHandler(&config.Config{AgentServiceToken: "service-token"}, search); handler == nil {
		t.Fatal("agent tools should be created with service token even without Firecrawl")
	}
}

type startupInfoClient struct {
	info analyzer.Info
	err  error
}

func (c startupInfoClient) Info(context.Context) (analyzer.Info, error) {
	return c.info, c.err
}

type startupVersionStore struct {
	marked      int64
	markResults []int64
	calls       int
}

func (s *startupVersionStore) MarkStaleByAnalyzerVersion(_ context.Context, analyzerName, analyzerVersion string) (int64, error) {
	s.calls++
	if analyzerName != "omp-mir-analyzer" || analyzerVersion != "2026-07-11-3" {
		return 0, errors.New("unexpected analyzer identity")
	}
	if len(s.markResults) > 0 {
		marked := s.markResults[0]
		s.markResults = s.markResults[1:]
		return marked, nil
	}
	marked := s.marked
	s.marked = 0
	return marked, nil
}

type lateStartupTrackStore struct {
	versions *startupVersionStore
	returned bool
}

func (s *lateStartupTrackStore) GetMaintenanceCandidates(_ context.Context, includeMetadata, includeAnalysis bool, _ time.Duration, limit int) ([]db.Track, error) {
	if includeMetadata || !includeAnalysis || limit != startupAnalyzerRepairLimit {
		return nil, errors.New("unexpected maintenance criteria")
	}
	if s.versions.calls < 2 || s.returned {
		return nil, nil
	}
	s.returned = true
	return []db.Track{{ID: 43}}, nil
}

type startupTrackStore struct {
	candidates []db.Track
	calls      int
	limit      int
	next       int
	maxBatch   int
}

func (s *startupTrackStore) GetMaintenanceCandidates(_ context.Context, includeMetadata, includeAnalysis bool, _ time.Duration, limit int) ([]db.Track, error) {
	s.calls++
	s.limit = limit
	if includeMetadata || !includeAnalysis {
		return nil, errors.New("unexpected maintenance criteria")
	}
	if s.next >= len(s.candidates) {
		return nil, nil
	}
	end := s.next + limit
	if end > len(s.candidates) {
		end = len(s.candidates)
	}
	batch := append([]db.Track(nil), s.candidates[s.next:end]...)
	s.next = end
	if len(batch) > s.maxBatch {
		s.maxBatch = len(batch)
	}
	return batch, nil
}

type startupRepairProcessor struct {
	mu              sync.Mutex
	trackIDs        []int64
	analyzer        string
	analyzerVersion string
	active          int
	maxActive       int
	release         <-chan struct{}
}

func (p *startupRepairProcessor) SetAnalyzerIdentity(analyzerName, analyzerVersion string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.analyzer = analyzerName
	p.analyzerVersion = analyzerVersion
}

func (p *startupRepairProcessor) RequestAnalysisRepair(_ context.Context, track *db.Track, opts processor.AnalysisRepairOptions) (processor.AnalysisRepairResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if opts.Force {
		return processor.AnalysisRepairResult{}, errors.New("startup repairs must not force manual work")
	}
	if !opts.OnlyStale {
		return processor.AnalysisRepairResult{}, errors.New("startup repairs must only claim stale analysis")
	}
	if opts.ExpectedAnalyzer != "omp-mir-analyzer" || opts.ExpectedAnalyzerVersion != "2026-07-11-3" {
		return processor.AnalysisRepairResult{}, errors.New("startup repair missing expected analyzer identity")
	}
	if p.analyzer != opts.ExpectedAnalyzer || p.analyzerVersion != opts.ExpectedAnalyzerVersion {
		return processor.AnalysisRepairResult{}, errors.New("processor analyzer identity was not initialized")
	}
	p.active++
	if p.active > p.maxActive {
		p.maxActive = p.active
	}
	release := p.release
	p.mu.Unlock()
	if release != nil {
		<-release
	}
	p.mu.Lock()
	p.active--
	p.trackIDs = append(p.trackIDs, track.ID)
	return processor.AnalysisRepairResult{TrackID: track.ID, Queued: true, Status: db.AnalysisStatusPending}, nil
}

func TestReconcileAnalyzerVersionMarksAndQueuesBoundedRepairs(t *testing.T) {
	versions := &startupVersionStore{marked: 2}
	tracks := &startupTrackStore{candidates: []db.Track{{ID: 43}, {ID: 44}}}
	repairs := &startupRepairProcessor{}

	report, err := reconcileAnalyzerVersion(
		context.Background(),
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-11-3"}},
		versions,
		tracks,
		repairs,
	)
	if err != nil {
		t.Fatalf("reconcileAnalyzerVersion returned error: %v", err)
	}
	if report.MarkedStale != 2 || report.Candidates != 2 || report.Queued != 2 {
		t.Fatalf("report = %#v, want two marked and queued", report)
	}
	if tracks.limit != startupAnalyzerRepairLimit {
		t.Fatalf("repair limit = %d, want %d", tracks.limit, startupAnalyzerRepairLimit)
	}
	if len(repairs.trackIDs) != 2 || !containsTrackIDs(repairs.trackIDs, 43, 44) {
		t.Fatalf("queued tracks = %v, want [43 44]", repairs.trackIDs)
	}
}

func TestReconcileAnalyzerVersionDrainsMoreThanFiftyInBoundedBatches(t *testing.T) {
	candidates := make([]db.Track, startupAnalyzerRepairLimit+1)
	for index := range candidates {
		candidates[index].ID = int64(index + 1)
	}
	tracks := &startupTrackStore{candidates: candidates}
	repairs := &startupRepairProcessor{}

	report, err := reconcileAnalyzerVersion(
		context.Background(),
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-11-3"}},
		&startupVersionStore{},
		tracks,
		repairs,
	)
	if err != nil {
		t.Fatalf("reconcileAnalyzerVersion returned error: %v", err)
	}
	if report.Candidates != startupAnalyzerRepairLimit+1 || report.Queued != startupAnalyzerRepairLimit+1 || report.Batches != 2 {
		t.Fatalf("report = %#v, want 51 candidates drained in two batches", report)
	}
	if tracks.maxBatch != startupAnalyzerRepairLimit {
		t.Fatalf("max batch = %d, want %d", tracks.maxBatch, startupAnalyzerRepairLimit)
	}
	if len(repairs.trackIDs) != startupAnalyzerRepairLimit+1 || !containsTrackIDs(repairs.trackIDs, int64(startupAnalyzerRepairLimit+1)) {
		t.Fatalf("queued tracks = %v, want all 51 candidates", repairs.trackIDs)
	}
}

func TestReconcileAnalyzerVersionBoundsConcurrentRepairClaims(t *testing.T) {
	candidates := make([]db.Track, startupAnalyzerRepairWorkers+2)
	for index := range candidates {
		candidates[index].ID = int64(index + 1)
	}
	release := make(chan struct{})
	repairs := &startupRepairProcessor{release: release}
	done := make(chan error, 1)
	go func() {
		_, err := reconcileAnalyzerVersion(
			context.Background(),
			startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-11-3"}},
			&startupVersionStore{},
			&startupTrackStore{candidates: candidates},
			repairs,
		)
		done <- err
	}()

	deadline := time.After(time.Second)
	for {
		repairs.mu.Lock()
		active := repairs.active
		maxActive := repairs.maxActive
		repairs.mu.Unlock()
		if active == startupAnalyzerRepairWorkers {
			if maxActive > startupAnalyzerRepairWorkers {
				t.Fatalf("active repair claims = %d, want at most %d", maxActive, startupAnalyzerRepairWorkers)
			}
			break
		}
		select {
		case <-deadline:
			t.Fatalf("repair claims did not reach bounded concurrency; active=%d", active)
		case <-time.After(time.Millisecond):
		}
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatalf("reconcileAnalyzerVersion returned error: %v", err)
	}
}

func containsTrackIDs(got []int64, wanted ...int64) bool {
	seen := make(map[int64]bool, len(got))
	for _, id := range got {
		seen[id] = true
	}
	for _, id := range wanted {
		if !seen[id] {
			return false
		}
	}
	return true
}

func TestReconcileAnalyzerVersionIsIdempotentAfterFirstRepairBatch(t *testing.T) {
	versions := &startupVersionStore{}
	tracks := &startupTrackStore{candidates: []db.Track{{ID: 43}}}
	repairs := &startupRepairProcessor{}
	client := startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-11-3"}}

	if _, err := reconcileAnalyzerVersion(context.Background(), client, versions, tracks, repairs); err != nil {
		t.Fatalf("first reconciliation returned error: %v", err)
	}
	report, err := reconcileAnalyzerVersion(context.Background(), client, versions, tracks, repairs)
	if err != nil {
		t.Fatalf("second reconciliation returned error: %v", err)
	}
	if report.Queued != 0 || len(repairs.trackIDs) != 1 {
		t.Fatalf("second reconciliation queued repairs: report=%#v ids=%v", report, repairs.trackIDs)
	}
}

func TestReconcileAnalyzerVersionSettlesRowsCreatedDuringInitialMark(t *testing.T) {
	versions := &startupVersionStore{markResults: []int64{0, 1, 0}}
	tracks := &lateStartupTrackStore{versions: versions}
	repairs := &startupRepairProcessor{}

	report, err := reconcileAnalyzerVersion(
		context.Background(),
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-11-3"}},
		versions,
		tracks,
		repairs,
	)
	if err != nil {
		t.Fatalf("reconcileAnalyzerVersion returned error: %v", err)
	}
	if report.MarkedStale != 1 || report.Queued != 1 || len(repairs.trackIDs) != 1 {
		t.Fatalf("report = %#v repairs=%v, want late stale row queued", report, repairs.trackIDs)
	}
}

func TestReconcileAnalyzerVersionLeavesStartupUnblockedWhenAnalyzerUnavailable(t *testing.T) {
	versions := &startupVersionStore{}
	tracks := &startupTrackStore{}
	repairs := &startupRepairProcessor{}
	start := time.Now()
	_, err := reconcileAnalyzerVersion(
		context.Background(),
		startupInfoClient{err: errors.New("connection refused")},
		versions,
		tracks,
		repairs,
	)
	if err == nil {
		t.Fatal("reconcileAnalyzerVersion returned nil error for unavailable analyzer")
	}
	if time.Since(start) > 100*time.Millisecond {
		t.Fatalf("unavailable analyzer path blocked for %s", time.Since(start))
	}
	if versions.calls != 0 || tracks.calls != 0 || len(repairs.trackIDs) != 0 {
		t.Fatalf("unavailable analyzer mutated maintenance state: versions=%d tracks=%d repairs=%v", versions.calls, tracks.calls, repairs.trackIDs)
	}
}
