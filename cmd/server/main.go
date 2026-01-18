package main

import (
	"log"
	"net/http"

	"github.com/openmusicplayer/openmusicplayer/internal/config"
	"github.com/openmusicplayer/openmusicplayer/internal/database"
	"github.com/openmusicplayer/openmusicplayer/internal/handlers"
	"github.com/openmusicplayer/openmusicplayer/internal/middleware"
)

func main() {
	cfg := config.Load()

	db, err := database.New(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	if err := db.Migrate(); err != nil {
		log.Fatalf("Failed to run migrations: %v", err)
	}

	authHandler := handlers.NewAuthHandler(db, cfg)
	authMiddleware := middleware.NewAuthMiddleware(cfg.JWTSecret)

	mux := http.NewServeMux()

	// Public auth endpoints
	mux.HandleFunc("POST /api/v1/auth/register", authHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", authHandler.Login)
	mux.HandleFunc("POST /api/v1/auth/refresh", authHandler.Refresh)

	// Protected endpoints
	mux.Handle("POST /api/v1/auth/logout", authMiddleware.Authenticate(http.HandlerFunc(authHandler.Logout)))

	log.Printf("Server starting on port %s", cfg.ServerPort)
	if err := http.ListenAndServe(":"+cfg.ServerPort, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
