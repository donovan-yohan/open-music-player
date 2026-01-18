package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/middleware"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/queue"
	"github.com/openmusicplayer/backend/internal/search"
	"github.com/openmusicplayer/backend/internal/storage"
	"github.com/openmusicplayer/backend/internal/stream"
	"github.com/openmusicplayer/backend/internal/websocket"
)

func main() {
	cfg := config.Load()

	database, err := db.New(cfg.DBHost, cfg.DBPort, cfg.DBUser, cfg.DBPassword, cfg.DBName)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer database.Close()

	if err := database.Migrate(); err != nil {
		log.Fatalf("Failed to run migrations: %v", err)
	}

	redisCache, err := cache.New(cfg.RedisAddr)
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	defer redisCache.Close()

	userRepo := db.NewUserRepository(database)
	tokenRepo := db.NewTokenRepository(database)
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	authService := auth.NewService(userRepo, tokenRepo, cfg.JWTSecret)
	authHandlers := auth.NewHandlers(authService)
	searchHandlers := search.NewHandlers(trackRepo)
	libraryHandlers := api.NewLibraryHandlers(trackRepo, libraryRepo)
	playlistHandlers := api.NewPlaylistHandlers(playlistRepo, trackRepo)

	mbClient := musicbrainz.NewClient(redisCache)
	mbHandlers := musicbrainz.NewHandlers(mbClient)

	// Initialize storage client
	storageClient, err := storage.New(&storage.Config{
		Endpoint:  cfg.MinioEndpoint,
		AccessKey: cfg.MinioAccessKey,
		SecretKey: cfg.MinioSecretKey,
		Bucket:    cfg.MinioBucket,
		UseSSL:    cfg.MinioUseSSL,
	})
	if err != nil {
		log.Fatalf("Failed to initialize storage client: %v", err)
	}

	// Initialize stream handler
	streamHandler := stream.NewHandler(trackRepo, storageClient)

	// Initialize WebSocket hub and handler
	wsHub := websocket.NewHub()
	go wsHub.Run()
	wsHandler := websocket.NewHandler(wsHub, authService)

	// Initialize matcher service
	matcherService := matcher.NewMatcher(mbClient)
	matcherHandlers := matcher.NewHandler(matcherService, trackRepo)

	// Initialize job processor with matching integration
	jobProcessor := processor.New(&processor.ProcessorConfig{
		Matcher:     matcherService,
		TrackRepo:   trackRepo,
		LibraryRepo: libraryRepo,
		Storage:     storageClient,
	})

	// Initialize download service with job queue
	downloadService, err := download.NewService(&download.ServiceConfig{
		RedisURL:    cfg.RedisURL,
		WorkerCount: cfg.WorkerCount,
	}, jobProcessor.Process)
	if err != nil {
		log.Fatalf("Failed to initialize download service: %v", err)
	}
	downloadService.Start()

	// Initialize queue service
	queueService, err := queue.NewService(cfg.RedisURL)
	if err != nil {
		log.Fatalf("Failed to initialize queue service: %v", err)
	}
	defer queueService.Close()
	queueHandlers := queue.NewHandlers(queueService)

	// Initialize download handlers
	downloadHandlers := api.NewDownloadHandlers(downloadService)

	router := api.NewRouter(authHandlers, authService, searchHandlers, mbClient, mbHandlers, wsHandler, matcherHandlers, libraryHandlers, streamHandler, queueHandlers, playlistHandlers, downloadHandlers)

	// Apply middleware chain (order: timing -> gzip -> etag -> router)
	// Note: ETag is after gzip so it calculates hash on compressed content
	handler := middleware.Timing(middleware.Gzip(middleware.ETag(router)))

	server := &http.Server{
		Addr:    cfg.ServerAddr,
		Handler: handler,
	}

	// Graceful shutdown handling
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		log.Println("Shutting down...")

		// Stop accepting new requests
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("HTTP server shutdown error: %v", err)
		}

		// Stop download workers (waits for current jobs to finish)
		if err := downloadService.Stop(shutdownCtx); err != nil {
			log.Printf("Download service shutdown error: %v", err)
		}
	}()

	log.Printf("Starting server on %s", cfg.ServerAddr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server failed to start: %v", err)
	}

	log.Println("Server stopped")
}
