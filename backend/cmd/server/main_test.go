package main

import (
	"context"
	"errors"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/research"
)

func TestPrivateAnalysisStartupMaintenanceRetriesWithFreshHealth(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	peer := db.NewAnalysisRepository(openPrivateImportFixtureDB(t, ctx))
	source := fixtureSQLPrivateSource(t, ctx, database, tracks)
	const name, retired, worker, current = "startup-retry", "opaque-retired", "opaque-worker", "opaque-current"
	sampled, hold := make(chan struct{}), make(chan struct{})
	release := sync.OnceFunc(func() { close(hold) })
	var samples atomic.Int32
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, req *http.Request) {
		switch samples.Add(1) {
		case 1:
			close(sampled)
			select {
			case <-hold:
				writePrivateAnalysisHealth(w, name, retired)
			case <-req.Context().Done():
			}
		case 2:
			writePrivateAnalysisHealth(w, name, current)
		default:
			w.WriteHeader(http.StatusInternalServerError)
		}
	})
	type outcome struct {
		report analyzerMaintenanceReport
		err    error
	}
	attempts := make(chan outcome, 2)
	drained, advance := make(chan struct{}), make(chan struct{})
	var loop sync.WaitGroup
	defer func() { release(); cancel(); loop.Wait() }()
	loop.Go(func() {
		runAnalyzerStartupMaintenance(ctx, 0, func() error {
			report, err := reconcileAnalyzerVersion(ctx, client, analysis, tracks, &startupRepairProcessor{})
			select {
			case attempts <- outcome{report, err}:
			case <-ctx.Done():
			}
			return err
		}, func() {
			select {
			case drained <- struct{}{}:
			case <-ctx.Done():
				return
			}
			select {
			case <-advance:
			case <-ctx.Done():
			}
		})
	})
	awaitDrain := func() {
		t.Helper()
		select {
		case <-drained:
		case <-ctx.Done():
			t.Fatal("maintenance did not reach the drain boundary")
		}
	}
	awaitAttempt := func() outcome {
		t.Helper()
		select {
		case result := <-attempts:
			return result
		case <-ctx.Done():
			t.Fatal("maintenance did not attempt reconciliation")
			return outcome{}
		}
	}
	advanceLoop := func() {
		t.Helper()
		select {
		case advance <- struct{}{}:
		case <-ctx.Done():
			t.Fatal("maintenance did not accept a retry tick")
		}
	}
	awaitPrivateAnalysisStartupSignal(t, ctx, sampled)
	claim := uuid.New()
	requirePrivateClaim(t, ctx, peer, source, claim, name, worker, true)
	release()
	failed := awaitAttempt()
	requirePrivateAnalysisStartupConflict(t, failed.err)
	if failed.report.Analyzer != "" || failed.report.AnalyzerVersion != "" {
		t.Fatalf("failed attempt published analyzer identity: %+v", failed.report)
	}
	awaitDrain()
	if err := peer.MarkAnalyzing(ctx, source.TrackID, fixtureClaimProvenance(claim, name, worker)); err != nil {
		t.Fatalf("aborted observation disturbed the worker: %v", err)
	}
	advanceLoop()
	retried := awaitAttempt()
	if retried.err != nil || retried.report.Analyzer != name || retried.report.AnalyzerVersion != current || retried.report.MarkedStale != 1 {
		t.Fatalf("retry did not reconcile fresh health: %+v", retried)
	}
	awaitDrain()
	requirePrivateClaim(t, ctx, peer, source, uuid.New(), name, current, true)
	advanceLoop()
	awaitDrain()
	if samples.Load() != 2 || len(attempts) != 0 {
		t.Fatalf("maintenance re-sampled after a successful retry: samples=%d pending=%d", samples.Load(), len(attempts))
	}
}

func TestStemsProductionCompositionKeepsReadsIndependentOfWorkerAdmission(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	source := func(node ast.Node) string {
		var b strings.Builder
		if err := format.Node(&b, fset, node); err != nil {
			t.Fatal(err)
		}
		return b.String()
	}
	compose := func(queue string) string {
		return "stemsHandlers = api.NewStemsHandlers(stemsRepo, " + queue + ", trackRepo, libraryRepo, storageClient)"
	}
	var startup *ast.FuncDecl
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok && fn.Name.Name == "runServer" {
			startup = fn
			break
		}
	}
	if startup == nil || startup.Body == nil {
		t.Fatal("missing production startup")
	}
	fallbackIndex, routerIndex := -1, -1
	for i, stmt := range startup.Body.List {
		if branch, ok := stmt.(*ast.IfStmt); ok && source(branch.Cond) == "cfg.StemsEnabled && stemsHandlers == nil" {
			if branch.Init != nil || branch.Else != nil || len(branch.Body.List) != 1 || source(branch.Body.List[0]) != compose("nil") {
				t.Fatal("the enabled fallback must wire the durable repositories and existing storage with a literal nil queue")
			}
			fallbackIndex = i
		}
		for node := range ast.Preorder(stmt) {
			call, ok := node.(*ast.CallExpr)
			if !ok || len(call.Args) != 1 || source(call.Fun) != "api.NewRouterWithConfig" {
				continue
			}
			ptr, ok := call.Args[0].(*ast.UnaryExpr)
			if !ok || ptr.Op != token.AND {
				continue
			}
			cfg, ok := ptr.X.(*ast.CompositeLit)
			if !ok {
				continue
			}
			for _, field := range cfg.Elts {
				if pair, ok := field.(*ast.KeyValueExpr); ok && source(pair.Key) == "StemsHandlers" && source(pair.Value) == "stemsHandlers" {
					routerIndex = i
				}
			}
		}
	}
	if fallbackIndex < 1 || routerIndex <= fallbackIndex {
		t.Fatal("startup must compose the enabled read fallback before wiring the production router")
	}
	admission, ok := startup.Body.List[fallbackIndex-1].(*ast.SwitchStmt)
	if !ok || len(admission.Body.List) == 0 {
		t.Fatal("read fallback must run after the worker admission switch")
	}
	first, ok := admission.Body.List[0].(*ast.CaseClause)
	if !ok || len(first.List) != 1 || source(first.List[0]) != "!cfg.StemsEnabled" {
		t.Fatal("explicit global off must bypass worker admission")
	}
	for node := range ast.Preorder(admission) {
		if clause, ok := node.(*ast.CaseClause); ok && len(clause.List) == 0 {
			for i, stmt := range clause.Body {
				if i > 0 && source(stmt) == compose("stemsQueue") && source(clause.Body[i-1]) == "stemsWorkers.Start(ctx)" {
					return
				}
			}
		}
	}
	t.Fatal("queue-backed stem handlers must wire existing member storage only after starting the admitted worker")
}

func TestMaintenanceStartupConfiguration(t *testing.T) {
	id := uuid.MustParse("53b676c8-7b11-4705-89a6-08dcebcbe674")
	for _, tc := range []struct {
		name, value string
		invalid     bool
		status      int
	}{
		{"default_denied", "", false, http.StatusForbidden},
		{"operator_admitted", id.String(), false, http.StatusServiceUnavailable},
		{"malformed_fails_startup", id.String() + ",nope", true, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("MAINTENANCE_ADMIN_USER_IDS", tc.value)
			cfg, err := maintenanceStartupConfig(config.Load())
			if (err != nil) != tc.invalid {
				t.Fatalf("startup error=%v, invalid=%v", err, tc.invalid)
			}
			if tc.invalid {
				return
			}
			handler := api.NewMaintenanceHandlers(nil, nil, cfg)
			req := httptest.NewRequest(http.MethodPost, "/api/v1/maintenance/repair", strings.NewReader(`{}`))
			req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: id}))
			response := httptest.NewRecorder()
			handler.RepairTracks(response, req)
			if response.Code != tc.status {
				t.Fatalf("configured handler status=%d, want %d", response.Code, tc.status)
			}
		})
	}
	if _, err := maintenanceStartupConfig(nil); err == nil {
		t.Fatal("nil config passed startup validation")
	}
}

func TestDiscoveryServiceConfigFromEnvDefaults(t *testing.T) {
	cfg := discoveryServiceConfigFromEnv(func(string) string { return "" })
	if cfg.PerProviderTimeout != discovery.DefaultPerProviderTimeout {
		t.Fatalf("per-provider timeout = %s, want %s", cfg.PerProviderTimeout, discovery.DefaultPerProviderTimeout)
	}
	if cfg.SoundCloudTimeout != discovery.DefaultSoundCloudTimeout {
		t.Fatalf("SoundCloud timeout = %s, want %s", cfg.SoundCloudTimeout, discovery.DefaultSoundCloudTimeout)
	}
	if cfg.OverallTimeout != discovery.DefaultOverallTimeout {
		t.Fatalf("overall timeout = %s, want %s", cfg.OverallTimeout, discovery.DefaultOverallTimeout)
	}
	if cfg.YouTubeMusicMetadataEnrichmentTimeout != discovery.DefaultYouTubeMusicMetadataEnrichmentTimeout || cfg.YouTubeMusicMetadataEnrichmentConcurrency != discovery.DefaultYouTubeMusicMetadataEnrichmentConcurrency {
		t.Fatalf("metadata enrichment defaults = %#v", cfg)
	}
}

func TestDiscoveryServiceConfigFromEnvOverrides(t *testing.T) {
	values := map[string]string{
		"DISCOVERY_PER_PROVIDER_TIMEOUT_SECONDS":           "11",
		"DISCOVERY_SOUNDCLOUD_TIMEOUT_SECONDS":             "13",
		"DISCOVERY_OVERALL_TIMEOUT_SECONDS":                "15",
		"DISCOVERY_YOUTUBE_MUSIC_METADATA_TIMEOUT_SECONDS": "7",
		"DISCOVERY_YOUTUBE_MUSIC_METADATA_CONCURRENCY":     "4",
	}
	cfg := discoveryServiceConfigFromEnv(func(key string) string { return values[key] })
	if cfg.PerProviderTimeout != 11*time.Second {
		t.Fatalf("per-provider timeout = %s, want 11s", cfg.PerProviderTimeout)
	}
	if cfg.SoundCloudTimeout != 13*time.Second {
		t.Fatalf("SoundCloud timeout = %s, want 13s", cfg.SoundCloudTimeout)
	}
	if cfg.OverallTimeout != 15*time.Second {
		t.Fatalf("overall timeout = %s, want 15s", cfg.OverallTimeout)
	}
	if cfg.YouTubeMusicMetadataEnrichmentTimeout != 7*time.Second || cfg.YouTubeMusicMetadataEnrichmentConcurrency != 4 {
		t.Fatalf("metadata enrichment overrides = %#v", cfg)
	}
}

func TestDiscoveryServiceConfigFromEnvInvalidValuesUseDefaultsAndClampMaximum(t *testing.T) {
	values := map[string]string{
		"DISCOVERY_PER_PROVIDER_TIMEOUT_SECONDS":           "9223372036854775807",
		"DISCOVERY_SOUNDCLOUD_TIMEOUT_SECONDS":             "0",
		"DISCOVERY_OVERALL_TIMEOUT_SECONDS":                "0",
		"DISCOVERY_YOUTUBE_MUSIC_METADATA_TIMEOUT_SECONDS": "0",
		"DISCOVERY_YOUTUBE_MUSIC_METADATA_CONCURRENCY":     "26",
	}
	cfg := discoveryServiceConfigFromEnv(func(key string) string { return values[key] })
	if cfg.PerProviderTimeout != discovery.DefaultPerProviderTimeout || cfg.SoundCloudTimeout != discovery.DefaultSoundCloudTimeout || cfg.OverallTimeout != discovery.DefaultOverallTimeout || cfg.YouTubeMusicMetadataEnrichmentTimeout != discovery.DefaultYouTubeMusicMetadataEnrichmentTimeout {
		t.Fatalf("invalid env timeout config = %#v, want timeout defaults", cfg)
	}
	if cfg.YouTubeMusicMetadataEnrichmentConcurrency != discovery.MaxYouTubeMusicMetadataEnrichmentConcurrency {
		t.Fatalf("metadata concurrency = %d, want maximum %d", cfg.YouTubeMusicMetadataEnrichmentConcurrency, discovery.MaxYouTubeMusicMetadataEnrichmentConcurrency)
	}
}

func TestDiscoveryServiceConfigFromEnvLeavesProviderClampingToService(t *testing.T) {
	values := map[string]string{
		"DISCOVERY_PER_PROVIDER_TIMEOUT_SECONDS":           "12",
		"DISCOVERY_SOUNDCLOUD_TIMEOUT_SECONDS":             "14",
		"DISCOVERY_OVERALL_TIMEOUT_SECONDS":                "5",
		"DISCOVERY_YOUTUBE_MUSIC_METADATA_TIMEOUT_SECONDS": "15",
	}
	cfg := discoveryServiceConfigFromEnv(func(key string) string { return values[key] })
	if cfg.OverallTimeout != cfg.PerProviderTimeout {
		t.Fatalf("overall timeout = %s, want generic provider timeout %s before providers are registered", cfg.OverallTimeout, cfg.PerProviderTimeout)
	}
	if cfg.YouTubeMusicMetadataEnrichmentTimeout != cfg.PerProviderTimeout {
		t.Fatalf("metadata timeout = %s, want it clamped to per-provider timeout %s", cfg.YouTubeMusicMetadataEnrichmentTimeout, cfg.PerProviderTimeout)
	}
}

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

func TestNewResearchRunnerUsesDisabledRunnerUntilResearchIsEnabled(t *testing.T) {
	runner, err := newResearchRunner(&config.Config{ResearchEnabled: false})
	if err != nil {
		t.Fatalf("newResearchRunner() returned error: %v", err)
	}
	if _, ok := runner.(research.DisabledRunner); !ok {
		t.Fatalf("runner = %T, want research.DisabledRunner", runner)
	}
}

func TestShouldStartResearchWorkerRequiresResearchEnabled(t *testing.T) {
	if shouldStartResearchWorker(&config.Config{ResearchWorkerEnabled: true}) {
		t.Fatal("worker starts while RESEARCH_ENABLED is false")
	}
	if !shouldStartResearchWorker(&config.Config{ResearchEnabled: true, ResearchWorkerEnabled: true}) {
		t.Fatal("enabled research worker did not start")
	}
}

func TestValidateResearchStartupRejectsUnsafeRolloutBeforeRuntimeWiring(t *testing.T) {
	err := validateResearchStartup(&config.Config{ResearchEnabled: true, ResearchDeepAgentEnabled: true})
	if err == nil {
		t.Fatal("unsafe deep-agent rollout passed startup validation")
	}
}

func TestNewResearchRunnerRequiresCommandWhenEnabled(t *testing.T) {
	if _, err := newResearchRunner(&config.Config{ResearchEnabled: true, ResearchDirectJudgeEnabled: true}); err == nil {
		t.Fatal("enabled research without a worker command should fail startup wiring")
	}
}

func TestNewResearchRunnerBuildsBoundedCommandRunner(t *testing.T) {
	runner, err := newResearchRunner(&config.Config{
		ResearchEnabled:            true,
		ResearchDirectJudgeEnabled: true,
		ResearchCommand:            "candidate-assembly-worker",
		ResearchCommandArgs:        []string{"--once"},
		ResearchCancelGrace:        time.Second,
		ResearchModelBaseURL:       "https://models.example/v1",
		ResearchModelAPIKey:        "model-only-secret",
		ResearchModel:              "candidate-judge",
		ResearchModelTimeout:       2 * time.Second,
		ResearchModelRunTimeout:    time.Minute,
	})
	if err != nil {
		t.Fatalf("newResearchRunner() returned error: %v", err)
	}
	if _, ok := runner.(*research.CommandRunner); !ok {
		t.Fatalf("runner = %T, want *research.CommandRunner", runner)
	}
}

func TestNewResearchRunnerUsesDisabledRunnerWhenAllStagesAreDisabled(t *testing.T) {
	runner, err := newResearchRunner(&config.Config{
		ResearchEnabled:            true,
		ResearchDirectJudgeEnabled: false,
		ResearchDeepAgentEnabled:   false,
	})
	if err != nil {
		t.Fatalf("newResearchRunner() returned error: %v", err)
	}
	if _, ok := runner.(research.DisabledRunner); !ok {
		t.Fatalf("runner = %T, want research.DisabledRunner", runner)
	}
}

func TestResearchCommandRunnerConfigPassesStagesAndBudgets(t *testing.T) {
	cfg := &config.Config{
		ResearchCommand:            "candidate-assembly-worker",
		ResearchCommandArgs:        []string{"--once"},
		ResearchCancelGrace:        2 * time.Second,
		ResearchModelBaseURL:       "https://models.example/v1",
		ResearchModelAPIKey:        "model-only-secret",
		ResearchModel:              "candidate-judge",
		ResearchModelTimeout:       7 * time.Second,
		ResearchModelRunTimeout:    2 * time.Minute,
		ResearchDirectJudgeEnabled: false,
		ResearchDeepAgentEnabled:   true,
		ResearchMaxToolCalls:       7,
		ResearchMaxModelCalls:      9,
		ResearchRecursionLimit:     11,
		ResearchMaxCandidatesIn:    24,
		ResearchMaxRecommendations: 8,
		ResearchWallClock:          45 * time.Second,
		ResearchMaxRequestBytes:    4096,
		ResearchMaxResponseBytes:   8192,
		ResearchMaxTokens:          2048,
	}
	runnerConfig := researchCommandRunnerConfig(cfg)
	if runnerConfig.Command != cfg.ResearchCommand || len(runnerConfig.Args) != 1 || runnerConfig.Args[0] != "--once" || runnerConfig.CancelGrace != 2*time.Second {
		t.Fatalf("runner command config = %#v", runnerConfig)
	}
	if runnerConfig.Stages.DirectJudge || !runnerConfig.Stages.DeepAgent {
		t.Fatalf("runner stages = %#v", runnerConfig.Stages)
	}
	if runnerConfig.Budgets != (research.WorkerBudgetConfig{MaxToolCalls: 7, MaxModelCalls: 9, RecursionLimit: 11, MaxCandidatesIn: 24, MaxRecommendations: 8, WallClockMs: 45000, MaxRequestBytes: 4096, MaxResponseBytes: 8192, MaxTokensPerCompletion: 2048}) {
		t.Fatalf("runner budgets = %#v", runnerConfig.Budgets)
	}
	if runnerConfig.Environment["AGENT_SEARCH_MODEL"] != "candidate-judge" || runnerConfig.Environment["AGENT_SEARCH_TIMEOUT_S"] != "7" {
		t.Fatalf("runner environment = %#v", runnerConfig.Environment)
	}
	if _, leaked := runnerConfig.Environment["JWT_SECRET"]; leaked {
		t.Fatalf("runner environment leaked JWT_SECRET: %#v", runnerConfig.Environment)
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
	marked       int64
	markResults  []int64
	calls        int
	startupCalls int
}

func (s *startupVersionStore) ReconcilePrivateAnalyzerAtStartup(ctx context.Context, observe func(context.Context) (string, string, error)) (int64, error) {
	s.startupCalls++
	_, _, err := observe(ctx)
	return 0, err
}

func (s *startupVersionStore) MarkStaleByAnalyzerVersion(_ context.Context, analyzerName, analyzerVersion string) (int64, error) {
	s.calls++
	if analyzerName != "omp-mir-analyzer" || analyzerVersion != "2026-07-24-1" {
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
	if opts.ExpectedAnalyzer != "omp-mir-analyzer" || opts.ExpectedAnalyzerVersion != "2026-07-24-1" {
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
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-24-1"}},
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
	if versions.startupCalls != 1 || versions.calls < 2 {
		t.Fatalf("expected a single startup refence along with ordinary scans: startup=%d total=%d", versions.startupCalls, versions.calls)
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
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-24-1"}},
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
			startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-24-1"}},
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
	client := startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-24-1"}}

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
		startupInfoClient{info: analyzer.Info{Analyzer: "omp-mir-analyzer", AnalyzerVersion: "2026-07-24-1"}},
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
