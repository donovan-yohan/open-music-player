package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
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
	playlistImportRepo := playlistimport.NewImportRepository(database)
	trackSourceRepo := playlistimport.NewTrackSourceRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)
	playEventRepo := db.NewPlayEventRepository(database)

	// Initialize services
	authService := auth.NewService(userRepo, tokenRepo, cfg.JWTSecret)
	authHandlers := auth.NewHandlers(authService)
	searchHandlers := search.NewHandlers(trackRepo)
	mbClient := musicbrainz.NewClient(redisCache)
	mbHandlers := musicbrainz.NewHandlers(mbClient)
	discoveryService := discovery.NewDefaultServiceWithCatalog(mbClient)
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
	discoveryHandlers := discovery.NewHandlersWithAssist(discoveryService, assistService)
	log.Info(ctx, "Initialized discovery assist", map[string]interface{}{
		"ai_assist_enabled": assistClient != nil,
		"ai_assist_model":   cfg.AIAssistModel,
	})
	libraryHandlers := api.NewLibraryHandlers(trackRepo, libraryRepo)
	analysisHandlers := api.NewAnalysisHandlers(analysisRepo, libraryRepo)
	playlistHandlers := api.NewPlaylistHandlers(playlistRepo, trackRepo)
	mixPlanHandlers := api.NewMixPlanHandlers(mixPlanRepo)
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
		Matcher:        matcherService,
		TrackRepo:      trackRepo,
		LibraryRepo:    libraryRepo,
		PlaylistRepo:   playlistRepo,
		ImportRepo:     playlistImportRepo,
		SourceRepo:     trackSourceRepo,
		AnalysisRepo:   analysisRepo,
		AnalyzerClient: analyzerClient,
		Storage:        storageClient,
	})
	maintenanceHandlers := api.NewMaintenanceHandlers(trackRepo, jobProcessor)

	// Initialize Redis-backed download and playback queue services only when enabled.
	var downloadService *download.Service
	var downloadHandlers *api.DownloadHandlers
	var queueHandlers *queue.Handlers
	var playlistImportHandlers *api.PlaylistImportHandlers

	if cfg.RedisEnabled {
		downloadService, err = download.NewService(&download.ServiceConfig{
			RedisURL:    cfg.RedisURL,
			WorkerCount: cfg.WorkerCount,
		}, jobProcessor.Process)
		if err != nil {
			log.Error(ctx, "Failed to initialize download service", nil, err)
			os.Exit(1)
		}
		downloadService.Start()
		log.Info(ctx, "Started download service", map[string]interface{}{
			"workers": cfg.WorkerCount,
		})
		downloadHandlers = api.NewDownloadHandlers(downloadService)
		playlistImportService := playlistimport.NewService(playlistimport.Config{
			Store:      playlistImportRepo,
			Playlists:  playlistRepo,
			Tracks:     trackSourceRepo,
			Library:    libraryRepo,
			Downloader: downloadService,
			Enumerator: playlistimport.NewYTDLPEnumerator(),
		})
		playlistImportHandlers = api.NewPlaylistImportHandlers(playlistImportService)

		queueService, err := queue.NewService(cfg.RedisURL)
		if err != nil {
			log.Error(ctx, "Failed to initialize queue service", nil, err)
			os.Exit(1)
		}
		defer queueService.Close()
		queueHandlers = queue.NewHandlersWithAnalysis(queueService, downloadService, analysisRepo)
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
		AuthHandlers:           authHandlers,
		AuthService:            authService,
		SearchHandlers:         searchHandlers,
		MBClient:               mbClient,
		MBHandlers:             mbHandlers,
		WSHandler:              wsHandler,
		MatcherHandlers:        matcherHandlers,
		LibraryHandlers:        libraryHandlers,
		AnalysisHandlers:       analysisHandlers,
		PlaybackHandlers:       playbackHandlers,
		QueueHandlers:          queueHandlers,
		DiscoveryHandlers:      discoveryHandlers,
		PlaylistHandlers:       playlistHandlers,
		PlaylistImportHandlers: playlistImportHandlers,
		MixPlanHandlers:        mixPlanHandlers,
		DownloadHandlers:       downloadHandlers,
		MaintenanceHandlers:    maintenanceHandlers,
		PlayEventHandlers:      playEventHandlers,
		HealthHandler:          healthHandler,
		Metrics:                appMetrics,
		CORSAllowedOrigins:     cfg.CORSAllowedOrigins,
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
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigChan

		log.Info(ctx, "Received shutdown signal", map[string]interface{}{
			"signal": sig.String(),
		})

		// Stop accepting new requests
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Error(ctx, "HTTP server shutdown error", nil, err)
		}

		// Stop download workers (waits for current jobs to finish)
		if downloadService != nil {
			if err := downloadService.Stop(shutdownCtx); err != nil {
				log.Error(ctx, "Download service shutdown error", nil, err)
			}
		}

		log.Info(ctx, "Server shutdown complete", nil)
	}()

	log.Info(ctx, "Server starting", map[string]interface{}{
		"addr": cfg.ServerAddr,
	})

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Error(ctx, "Server failed to start", nil, err)
		os.Exit(1)
	}
}
