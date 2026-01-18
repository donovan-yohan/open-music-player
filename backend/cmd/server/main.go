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
	"github.com/openmusicplayer/backend/internal/musicbrainz"
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
	authService := auth.NewService(userRepo, tokenRepo, cfg.JWTSecret)
	authHandlers := auth.NewHandlers(authService)
	searchHandlers := search.NewHandlers(trackRepo)
	libraryHandlers := api.NewLibraryHandlers(trackRepo, libraryRepo)

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

	// Initialize download service with job queue
	downloadService, err := download.NewService(&download.ServiceConfig{
		RedisURL:    cfg.RedisURL,
		WorkerCount: cfg.WorkerCount,
	}, defaultJobProcessor)
	if err != nil {
		log.Fatalf("Failed to initialize download service: %v", err)
	}
	downloadService.Start()

	// Initialize matcher service
	matcherService := matcher.NewMatcher(mbClient)
	matcherHandlers := matcher.NewHandler(matcherService, trackRepo)

	router := api.NewRouter(authHandlers, authService, searchHandlers, mbClient, mbHandlers, wsHandler, matcherHandlers, libraryHandlers, streamHandler)

	server := &http.Server{
		Addr:    cfg.ServerAddr,
		Handler: router,
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

// defaultJobProcessor is a placeholder processor that will be replaced
// when the actual download logic is implemented
func defaultJobProcessor(ctx context.Context, job *download.DownloadJob, progress func(int)) error {
	// Placeholder: actual download logic will be implemented in a future task
	log.Printf("Processing job %s: URL=%s, SourceType=%s", job.ID, job.URL, job.SourceType)

	// Simulate progress through lifecycle stages
	stages := []struct {
		status   string
		progress int
	}{
		{download.StatusDownloading, 25},
		{download.StatusProcessing, 50},
		{download.StatusUploading, 75},
	}

	for _, stage := range stages {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			progress(stage.progress)
			time.Sleep(100 * time.Millisecond) // Simulated work
		}
	}

	return nil
}
