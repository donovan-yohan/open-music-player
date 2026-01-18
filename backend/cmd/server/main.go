package main

import (
	"log"
	"net/http"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
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
	authService := auth.NewService(userRepo, tokenRepo, cfg.JWTSecret)
	authHandlers := auth.NewHandlers(authService)

	mbClient := musicbrainz.NewClient(redisCache)
	mbHandlers := musicbrainz.NewHandlers(mbClient)

	router := api.NewRouter(authHandlers, authService, mbHandlers)

	log.Printf("Starting server on %s", cfg.ServerAddr)
	if err := http.ListenAndServe(cfg.ServerAddr, router); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}
