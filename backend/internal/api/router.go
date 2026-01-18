package api

import (
	"encoding/json"
	"net/http"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type Router struct {
	mux               *http.ServeMux
	authHandlers      *auth.Handlers
	authService       *auth.Service
	musicbrainzHandlers *musicbrainz.Handlers
}

func NewRouter(authHandlers *auth.Handlers, authService *auth.Service, mbHandlers *musicbrainz.Handlers) *Router {
	r := &Router{
		mux:                 http.NewServeMux(),
		authHandlers:        authHandlers,
		authService:         authService,
		musicbrainzHandlers: mbHandlers,
	}
	r.setupRoutes()
	return r
}

func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.mux.ServeHTTP(w, req)
}

func (r *Router) setupRoutes() {
	// Health check
	r.mux.HandleFunc("GET /health", healthHandler)

	// Auth routes (no auth required)
	r.mux.HandleFunc("POST /api/v1/auth/register", r.authHandlers.Register)
	r.mux.HandleFunc("POST /api/v1/auth/login", r.authHandlers.Login)
	r.mux.HandleFunc("POST /api/v1/auth/refresh", r.authHandlers.Refresh)

	// Auth routes (auth required)
	r.mux.HandleFunc("POST /api/v1/auth/logout", r.withAuth(r.authHandlers.Logout))

	// Search routes (auth required)
	r.mux.HandleFunc("GET /api/v1/search/tracks", r.withAuth(r.musicbrainzHandlers.SearchTracks))
	r.mux.HandleFunc("GET /api/v1/search/artists", r.withAuth(r.musicbrainzHandlers.SearchArtists))
	r.mux.HandleFunc("GET /api/v1/search/albums", r.withAuth(r.musicbrainzHandlers.SearchAlbums))
}

func (r *Router) withAuth(next http.HandlerFunc) http.HandlerFunc {
	middleware := auth.Middleware(r.authService)
	return func(w http.ResponseWriter, req *http.Request) {
		middleware(http.HandlerFunc(next)).ServeHTTP(w, req)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
	})
}
