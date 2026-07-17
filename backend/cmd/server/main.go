package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/aiassist"
	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/health"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/metrics"
	"github.com/openmusicplayer/backend/internal/middleware"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/playlistimport"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/queue"
	"github.com/openmusicplayer/backend/internal/search"
	"github.com/openmusicplayer/backend/internal/storage"
	"github.com/openmusicplayer/backend/internal/websocket"
)

const version = "1.0.0"

const (
	// Startup drains stale rows in repeated bounded batches so queue pressure and
	// database transactions stay predictable without requiring another restart.
	startupAnalyzerRepairLimit   = 50
	startupAnalyzerRepairWorkers = 4
	startupAnalyzerRepairTimeout = 15 * time.Second
	startupAnalyzerRetryInterval = 30 * time.Second
)

type analyzerInfoClient interface {
	Info(ctx context.Context) (analyzer.Info, error)
}

type analyzerVersionStore interface {
	MarkStaleByAnalyzerVersion(ctx context.Context, analyzerName, analyzerVersion string) (int64, error)
}

type analyzerMaintenanceTrackStore interface {
	GetMaintenanceCandidates(ctx context.Context, includeMetadata, includeAnalysis bool, staleAfter time.Duration, limit int) ([]db.Track, error)
}

type analyzerMaintenanceProcessor interface {
	SetAnalyzerIdentity(analyzerName, analyzerVersion string)
	RequestAnalysisRepair(ctx context.Context, track *db.Track, opts processor.AnalysisRepairOptions) (processor.AnalysisRepairResult, error)
}

// sourceSelectionPlaybackRecovery adapts the Redis playback queue to the
// database lifecycle without creating a db -> queue package dependency.
type sourceSelectionPlaybackRecovery struct {
	service *queue.Service
}

func (r sourceSelectionPlaybackRecovery) EnsureSourceCandidateWithID(ctx context.Context, userID, queueItemID string, candidate download.SourceCandidate, downloadJobID, position string) error {
	_, err := r.service.EnsureSourceCandidateWithID(ctx, userID, queueItemID, queue.SourceCandidate{
		CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID,
		SourceURL: candidate.SourceURL, Title: candidate.Title, Artist: candidate.Artist, Album: candidate.Album,
		Uploader: candidate.Uploader, DurationMs: candidate.DurationMs, ThumbnailURL: candidate.ThumbnailURL,
		Downloadable: true, Metadata: candidate.Metadata,
	}, downloadJobID, position)
	return err
}

type analyzerMaintenanceReport struct {
	Analyzer        string
	AnalyzerVersion string
	MarkedStale     int64
	Candidates      int
	Queued          int
	Skipped         int
	Failures        int
	Batches         int
}

// newSourceQualityJudge creates the optional discovery dependency exclusively
// from the loaded server configuration. A disabled config produces nil, which
// keeps discovery on deterministic ranking.
func newSourceQualityJudge(cfg *config.Config) discovery.SourceQualityJudge {
	if cfg == nil {
		return nil
	}
	judge := discovery.NewOllamaSourceQualityJudge(discovery.OllamaSourceQualityConfig{
		Enabled: cfg.SourceQualityLLMEnabled,
		BaseURL: cfg.SourceQualityLLMBaseURL,
		Model:   cfg.SourceQualityLLMModel,
		Timeout: cfg.SourceQualityLLMTimeout,
		APIKey:  cfg.SourceQualityLLMAPIKey,
	})
	if judge == nil {
		return nil
	}
	return judge
}

// newAgentToolsHandler wires the private research gateway independently from
// ordinary discovery. A missing service token returns nil, so no gateway route
// is registered and deterministic discovery remains untouched.
func newAgentToolsHandler(cfg *config.Config, search *discovery.Service) *discovery.AgentToolsHandler {
	if cfg == nil {
		return nil
	}
	return discovery.NewAgentToolsHandler(discovery.AgentToolsConfig{
		ServiceToken:    cfg.AgentServiceToken,
		FirecrawlAPIKey: cfg.FirecrawlAPIKey,
		Search:          search,
	})
}

// reconcileAnalyzerVersion invalidates rows owned by another analyzer version,
// then drains stale work in bounded batches. Analysis overrides are owned by
// the repository and are never modified by this reconciliation.
func reconcileAnalyzerVersion(
	ctx context.Context,
	client analyzerInfoClient,
	analysisStore analyzerVersionStore,
	tracks analyzerMaintenanceTrackStore,
	repairs analyzerMaintenanceProcessor,
) (analyzerMaintenanceReport, error) {
	report := analyzerMaintenanceReport{}
	if client == nil || analysisStore == nil || tracks == nil || repairs == nil {
		return report, nil
	}
	infoCtx, infoCancel := context.WithTimeout(ctx, startupAnalyzerRepairTimeout)
	defer infoCancel()
	info, err := client.Info(infoCtx)
	if err != nil {
		return report, err
	}
	report.Analyzer = info.Analyzer
	report.AnalyzerVersion = info.AnalyzerVersion
	repairs.SetAnalyzerIdentity(info.Analyzer, info.AnalyzerVersion)
	markNewlyStale := func() (int64, error) {
		marked, markErr := analysisStore.MarkStaleByAnalyzerVersion(ctx, info.Analyzer, info.AnalyzerVersion)
		report.MarkedStale += marked
		return marked, markErr
	}
	if _, err := markNewlyStale(); err != nil {
		return report, err
	}
	for {
		candidates, err := tracks.GetMaintenanceCandidates(ctx, false, true, 0, startupAnalyzerRepairLimit)
		if err != nil {
			return report, err
		}
		if len(candidates) == 0 {
			marked, err := markNewlyStale()
			if err != nil {
				return report, err
			}
			if marked == 0 {
				return report, nil
			}
			continue
		}
		if len(candidates) > startupAnalyzerRepairLimit {
			candidates = candidates[:startupAnalyzerRepairLimit]
		}
		report.Batches++
		report.Candidates += len(candidates)
		batchQueued, batchSkipped, batchFailures := queueAnalyzerRepairBatch(ctx, repairs, candidates, info)
		report.Queued += batchQueued
		report.Skipped += batchSkipped
		report.Failures += batchFailures
		if batchFailures > 0 {
			return report, fmt.Errorf("%d analyzer repairs failed to queue", batchFailures)
		}
		if batchQueued == 0 {
			marked, err := markNewlyStale()
			if err != nil {
				return report, err
			}
			if marked == 0 {
				return report, nil
			}
		}
	}
}

// queueAnalyzerRepairBatch claims stale rows with bounded concurrency. The
// repository claim is idempotent, so concurrent startup retries can safely
// race without turning a stale batch into duplicate analyzer work.
func queueAnalyzerRepairBatch(ctx context.Context, repairs analyzerMaintenanceProcessor, candidates []db.Track, info analyzer.Info) (queued, skipped, failures int) {
	type outcome struct {
		queued bool
		err    error
	}
	workers := startupAnalyzerRepairWorkers
	if workers > len(candidates) {
		workers = len(candidates)
	}
	if workers == 0 {
		return 0, 0, 0
	}

	semaphore := make(chan struct{}, workers)
	outcomes := make(chan outcome, len(candidates))
	var wg sync.WaitGroup
	for index := range candidates {
		semaphore <- struct{}{}
		track := candidates[index]
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-semaphore }()
			result, err := repairs.RequestAnalysisRepair(ctx, &track, processor.AnalysisRepairOptions{
				OnlyStale:               true,
				ExpectedAnalyzer:        info.Analyzer,
				ExpectedAnalyzerVersion: info.AnalyzerVersion,
			})
			outcomes <- outcome{queued: result.Queued, err: err}
		}()
	}
	wg.Wait()
	close(outcomes)
	for outcome := range outcomes {
		if outcome.err != nil {
			failures++
		} else if outcome.queued {
			queued++
		} else {
			skipped++
		}
	}
	return queued, skipped, failures
}

func main() {
	// Initialize structured logger
	log := logger.Default()
	ctx := context.Background()

	log.Info(ctx, "Starting OpenMusicPlayer server", map[string]interface{}{
		"version": version,
	})

	cfg := config.Load()

	// Initialize database
	database, err := db.New(cfg.DBHost, cfg.DBPort, cfg.DBUser, cfg.DBPassword, cfg.DBName)
	if err != nil {
		log.Error(ctx, "Failed to connect to database", nil, err)
		os.Exit(1)
	}
	defer database.Close()
	log.Info(ctx, "Connected to database", map[string]interface{}{
		"host": cfg.DBHost,
		"port": cfg.DBPort,
		"name": cfg.DBName,
	})

	if err := database.Migrate(); err != nil {
		log.Error(ctx, "Failed to run migrations", nil, err)
		os.Exit(1)
	}
	log.Info(ctx, "Database migrations completed", nil)

	// Initialize optional Redis cache/queue support.
	var redisCache *cache.Cache
	if cfg.RedisEnabled {
		redisCache, err = cache.New(cfg.RedisAddr)
		if err != nil {
			log.Error(ctx, "Failed to connect to Redis", map[string]interface{}{
				"addr": cfg.RedisAddr,
			}, err)
			os.Exit(1)
		}
		defer redisCache.Close()
		log.Info(ctx, "Connected to Redis", map[string]interface{}{
			"addr": cfg.RedisAddr,
		})
	} else {
		log.Info(ctx, "Redis disabled; queue, download, and cached pub/sub features will return SERVICE_DISABLED", nil)
	}

	// Initialize repositories
	userRepo := db.NewUserRepository(database)
	tokenRepo := db.NewTokenRepository(database)
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	playlistSourceRepo := db.NewPlaylistSourceRepository(database)
	playlistImportRepo := playlistimport.NewImportRepository(database)
	trackSourceRepo := playlistimport.NewTrackSourceRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)
	playEventRepo := db.NewPlayEventRepository(database)
	sourceSelectionRepo := db.NewSourceSelectionRepository(database)

	// Initialize services
	authService := auth.NewService(userRepo, tokenRepo, cfg.JWTSecret)
	authHandlers := auth.NewHandlers(authService)
	searchHandlers := search.NewHandlers(trackRepo)
	mbClient := musicbrainz.NewClient(redisCache)
	mbHandlers := musicbrainz.NewHandlers(mbClient)
	sourceQualityJudge := newSourceQualityJudge(cfg)
	discoveryService := discovery.NewDefaultServiceWithCatalogAndSourceQualityJudge(mbClient, sourceQualityJudge)
	agentToolsHandler := newAgentToolsHandler(cfg, discoveryService)
	// AI assist is grounded against discovery/resolution; a nil client (unset or
	// disabled config) degrades to the disabled envelope without breaking search.
	assistClient := aiassist.NewClient(aiassist.Config{
		Enabled: cfg.AIAssistEnabled,
		BaseURL: cfg.AIAssistBaseURL,
		APIKey:  cfg.AIAssistAPIKey,
		Model:   cfg.AIAssistModel,
		Timeout: cfg.AIAssistTimeout,
	})
	assistService := discovery.NewAssistService(discovery.AssistConfig{
		Client:  assistClient,
		Search:  discoveryService,
		Timeout: cfg.AIAssistTimeout,
	})
	discoveryHandlers := discovery.NewHandlersWithAssistAndSelectionStore(discoveryService, assistService, sourceSelectionRepo)
	sourceSelectionHandlers := api.NewSourceSelectionHandlers(sourceSelectionRepo)
	log.Info(ctx, "Initialized discovery assist", map[string]interface{}{
		"ai_assist_enabled": assistClient != nil,
		"ai_assist_model":   cfg.AIAssistModel,
	})
	log.Info(ctx, "Initialized private agent research tools", map[string]interface{}{
		"agent_tools_enabled": agentToolsHandler != nil,
		"firecrawl_enabled":   agentToolsHandler != nil && cfg.FirecrawlAPIKey != "",
	})
	libraryHandlers := api.NewLibraryHandlers(trackRepo, libraryRepo)
	analysisHandlers := api.NewAnalysisHandlers(analysisRepo, libraryRepo)
	playlistHandlers := api.NewPlaylistHandlers(playlistRepo, trackRepo)
	mixPlanHandlers := api.NewMixPlanHandlers(mixPlanRepo)
	playlistMixHandlers := api.NewPlaylistMixHandlers(playlistRepo, mixPlanRepo, cfg.EnablePlaylistMix)
	playEventHandlers := api.NewPlayEventHandlers(playEventRepo, trackRepo)

	// Initialize storage client
	storageClient, err := storage.New(&storage.Config{
		Endpoint:       cfg.MinioEndpoint,
		PublicEndpoint: cfg.MinioPublicEndpoint,
		Region:         cfg.S3Region,
		AccessKey:      cfg.MinioAccessKey,
		SecretKey:      cfg.MinioSecretKey,
		Bucket:         cfg.MinioBucket,
		UseSSL:         cfg.MinioUseSSL,
	})
	if err != nil {
		log.Error(ctx, "Failed to initialize storage client", nil, err)
		os.Exit(1)
	}
	log.Info(ctx, "Initialized storage client", map[string]interface{}{
		"endpoint":        cfg.MinioEndpoint,
		"public_endpoint": cfg.MinioPublicEndpoint,
		"bucket":          cfg.MinioBucket,
	})

	// Initialize playback URL handlers. Normal audio bytes are served by object
	// storage/CDN through short-lived signed URLs; the backend does not register a
	// byte-proxy streaming route in the normal playback path.
	playbackHandlers := api.NewPlaybackHandlers(trackRepo, libraryRepo, storageClient)

	// Initialize WebSocket hub and handler
	wsHub := websocket.NewHub()
	go wsHub.Run()
	wsHandler := websocket.NewHandler(wsHub, authService)

	// Initialize matcher service. The Ollama disambiguator is optional and only
	// selects among MusicBrainz candidates; unavailable local providers fall back
	// to normal deterministic matching.
	metadataDisambiguator := matcher.NewOllamaDisambiguator(matcher.OllamaConfig{
		Enabled: cfg.MetadataLLMEnabled,
		BaseURL: cfg.MetadataLLMBaseURL,
		Model:   cfg.MetadataLLMModel,
		Timeout: cfg.MetadataLLMTimeout,
	})
	matcherService := matcher.NewMatcherWithDisambiguator(mbClient, metadataDisambiguator)
	log.Info(ctx, "Initialized metadata disambiguator", map[string]interface{}{
		"metadata_llm_enabled": metadataDisambiguator != nil,
		"metadata_llm_model":   cfg.MetadataLLMModel,
	})
	matcherHandlers := matcher.NewHandler(matcherService, trackRepo)
	serviceAnalyzerClient, err := analyzer.NewServiceClient(analyzer.ServiceConfig{
		Enabled:   cfg.AnalyzerEnabled,
		BaseURL:   cfg.AnalyzerBaseURL,
		AuthToken: cfg.AnalyzerAuthToken,
		Timeout:   cfg.AnalyzerTimeout,
	})
	if err != nil {
		log.Error(ctx, "Failed to initialize analyzer client", map[string]interface{}{
			"base_url": cfg.AnalyzerBaseURL,
		}, err)
		os.Exit(1)
	}
	var analyzerClient analyzer.Client
	if serviceAnalyzerClient != nil {
		analyzerClient = serviceAnalyzerClient
	}
	log.Info(ctx, "Initialized audio analyzer client", map[string]interface{}{
		"analyzer_enabled": analyzerClient != nil,
		"base_url":         cfg.AnalyzerBaseURL,
	})

	// Initialize job processor with matching integration
	jobProcessor := processor.New(&processor.ProcessorConfig{
		Matcher:                 matcherService,
		TrackRepo:               trackRepo,
		LibraryRepo:             libraryRepo,
		PlaylistRepo:            playlistRepo,
		ImportRepo:              playlistImportRepo,
		SourceRepo:              trackSourceRepo,
		PlaylistSourceRepo:      playlistSourceRepo,
		AnalysisRepo:            analysisRepo,
		AnalyzerClient:          analyzerClient,
		AnalysisConcurrency:     cfg.AnalyzerConcurrency,
		RequireAnalyzerIdentity: serviceAnalyzerClient != nil,
		Storage:                 storageClient,
	})
	stopAnalyzerMaintenance := func() {}
	if serviceAnalyzerClient != nil {
		maintenanceCtx, maintenanceCancel := context.WithCancel(context.Background())
		stopAnalyzerMaintenance = maintenanceCancel
		go func() {
			for {
				report, err := reconcileAnalyzerVersion(
					maintenanceCtx,
					serviceAnalyzerClient,
					analysisRepo,
					trackRepo,
					jobProcessor,
				)
				if err == nil {
					log.Info(ctx, "Analyzer version reconciliation completed", map[string]interface{}{
						"analyzer":         report.Analyzer,
						"analyzer_version": report.AnalyzerVersion,
						"marked_stale":     report.MarkedStale,
						"batches":          report.Batches,
						"candidates":       report.Candidates,
						"queued":           report.Queued,
						"skipped":          report.Skipped,
						"failures":         report.Failures,
					})
					return
				}
				log.Error(ctx, "Analyzer version reconciliation will retry", nil, err)
				select {
				case <-maintenanceCtx.Done():
					return
				case <-time.After(startupAnalyzerRetryInterval):
				}
			}
		}()
	}
	maintenanceHandlers := api.NewMaintenanceHandlers(trackRepo, jobProcessor)

	// Initialize Redis-backed download and playback queue services only when enabled.
	var downloadService *download.Service
	var downloadHandlers *api.DownloadHandlers
	var queueHandlers *queue.Handlers
	var playlistImportHandlers *api.PlaylistImportHandlers

	if cfg.RedisEnabled {
		sourceSelectionLifecycle := db.NewSourceSelectionDownloadLifecycle(database)
		sourceSelectionIngestion := db.NewSourceSelectionIngestion(database, sourceSelectionRepo)
		downloadService, err = download.NewService(&download.ServiceConfig{
			RedisURL:    cfg.RedisURL,
			WorkerCount: cfg.WorkerCount,
		}, jobProcessor.Process, sourceSelectionLifecycle)
		if err != nil {
			log.Error(ctx, "Failed to initialize download service", nil, err)
			os.Exit(1)
		}
		queueService, err := queue.NewService(cfg.RedisURL)
		if err != nil {
			log.Error(ctx, "Failed to initialize queue service", nil, err)
			os.Exit(1)
		}
		defer queueService.Close()
		// Recovery happens before workers start. It restores only durable,
		// nonterminal source-decision jobs from their persisted snapshots and is
		// idempotent when Redis already contains the same job ID.
		if recovered, err := sourceSelectionLifecycle.RecoverWithPlayback(ctx, downloadService, sourceSelectionPlaybackRecovery{service: queueService}, 0); err != nil {
			log.Error(ctx, "Failed to recover source-selection downloads", nil, err)
		} else if recovered > 0 {
			log.Info(ctx, "Recovered source-selection downloads", map[string]interface{}{"jobs": recovered})
		}
		downloadService.Start()
		log.Info(ctx, "Started download service", map[string]interface{}{
			"workers": cfg.WorkerCount,
		})
		downloadHandlers = api.NewDownloadHandlers(downloadService, sourceSelectionIngestion)
		ytdlpEnumerator := playlistimport.NewYTDLPEnumerator()
		playlistImportService := playlistimport.NewService(playlistimport.Config{
			Store:          playlistImportRepo,
			Playlists:      playlistRepo,
			Tracks:         trackSourceRepo,
			Library:        libraryRepo,
			Downloader:     downloadService,
			Selections:     sourceSelectionRepo,
			Ingestion:      sourceSelectionIngestion,
			Enumerator:     ytdlpEnumerator,
			SourceAdapter:  ytdlpEnumerator,
			SourceBindings: playlistSourceRepo,
		})
		playlistImportHandlers = api.NewPlaylistImportHandlers(playlistImportService)

		queueHandlers = queue.NewHandlersWithSourceSelections(queueService, downloadService, analysisRepo, sourceSelectionRepo, database)
	}

	// Initialize metrics
	appMetrics := metrics.New()

	var redisClient *redis.Client
	if redisCache != nil {
		redisClient = redisCache.Client()
	}

	// Initialize health checker
	healthChecker := health.NewChecker(&health.CheckerConfig{
		DB:    database.DB,
		Redis: redisClient,
		StorageCheck: func(ctx context.Context) error {
			return storageClient.Ping(ctx)
		},
		Version: version,
		Timeout: 5 * time.Second,
	})
	healthHandler := health.NewHandler(healthChecker)

	// Create router with all handlers
	router := api.NewRouterWithConfig(&api.RouterConfig{
		AuthHandlers:            authHandlers,
		AuthService:             authService,
		SearchHandlers:          searchHandlers,
		MBClient:                mbClient,
		MBHandlers:              mbHandlers,
		WSHandler:               wsHandler,
		MatcherHandlers:         matcherHandlers,
		LibraryHandlers:         libraryHandlers,
		AnalysisHandlers:        analysisHandlers,
		PlaybackHandlers:        playbackHandlers,
		QueueHandlers:           queueHandlers,
		DiscoveryHandlers:       discoveryHandlers,
		AgentToolsHandler:       agentToolsHandler,
		PlaylistHandlers:        playlistHandlers,
		PlaylistImportHandlers:  playlistImportHandlers,
		PlaylistMixHandlers:     playlistMixHandlers,
		MixPlanHandlers:         mixPlanHandlers,
		DownloadHandlers:        downloadHandlers,
		SourceSelectionHandlers: sourceSelectionHandlers,
		MaintenanceHandlers:     maintenanceHandlers,
		PlayEventHandlers:       playEventHandlers,
		HealthHandler:           healthHandler,
		Metrics:                 appMetrics,
		CORSAllowedOrigins:      cfg.CORSAllowedOrigins,
	})

	// Apply middleware chain
	handler := middleware.Chain(
		router,
		middleware.Recoverer(log),
		middleware.Logging(log),
		middleware.RequestID,
		metrics.MetricsMiddleware(appMetrics),
	)

	// Apply middleware chain (order: timing -> gzip -> etag -> handler)
	// Note: ETag is after gzip so it calculates hash on compressed content
	handler = middleware.Timing(middleware.Gzip(middleware.ETag(handler)))

	server := &http.Server{
		Addr:    cfg.ServerAddr,
		Handler: handler,
	}

	// Graceful shutdown handling
	shutdownComplete := make(chan struct{})
	go func() {
		defer close(shutdownComplete)
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigChan

		log.Info(ctx, "Received shutdown signal", map[string]interface{}{
			"signal": sig.String(),
		})
		stopAnalyzerMaintenance()

		// Stop accepting new requests
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Error(ctx, "HTTP server shutdown error", nil, err)
			_ = server.Close()
		}
		// Stop download workers (waits for current jobs to finish)
		if downloadService != nil {
			if err := downloadService.Stop(shutdownCtx); err != nil {
				log.Error(ctx, "Download service shutdown error", nil, err)
			}
		}
		if err := jobProcessor.Shutdown(shutdownCtx); err != nil {
			log.Error(ctx, "Analysis worker shutdown error", nil, err)
		}

		log.Info(ctx, "Server shutdown complete", nil)
	}()

	log.Info(ctx, "Server starting", map[string]interface{}{
		"addr": cfg.ServerAddr,
	})

	serveErr := server.ListenAndServe()
	if serveErr != nil && serveErr != http.ErrServerClosed {
		log.Error(ctx, "Server failed to start", nil, serveErr)
		os.Exit(1)
	}
	if serveErr == http.ErrServerClosed {
		<-shutdownComplete
	}
}
