package main

import (
	"log"
	"net/http"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/config"
)

func main() {
	cfg := config.Load()

	router := api.NewRouter()

	log.Printf("Starting server on %s", cfg.ServerAddr)
	if err := http.ListenAndServe(cfg.ServerAddr, router); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}
