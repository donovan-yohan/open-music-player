package api

import (
	"encoding/json"
	"net/http"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/search"
)

type Router struct {
	mux                 *http.ServeMux
	authHandlers        *auth.Handlers
	authService         *auth.Service
	searchHandlers      *search.Handlers
	browseHandlers      *BrowseHandlers
	musicbrainzHandlers *musicbrainz.Handlers
}

func NewRouter(authHandlers *auth.Handlers, authService *auth.Service, searchHandlers *search.Handlers, mbClient *musicbrainz.Client, mbHandlers *musicbrainz.Handlers) *Router {
	r := &Router{
		mux:                 http.NewServeMux(),
		authHandlers:        authHandlers,
		authService:         authService,
		searchHandlers:      searchHandlers,
		browseHandlers:      NewBrowseHandlers(mbClient),
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

	// Search routes - local database (auth required)
	r.mux.HandleFunc("GET /api/v1/search/recordings", r.withAuth(r.searchHandlers.SearchRecordings))
	r.mux.HandleFunc("GET /api/v1/search/artists", r.withAuth(r.searchHandlers.SearchArtists))
	r.mux.HandleFunc("GET /api/v1/search/releases", r.withAuth(r.searchHandlers.SearchReleases))

	// Search routes - MusicBrainz with caching (auth required)
	r.mux.HandleFunc("GET /api/v1/musicbrainz/search/tracks", r.withAuth(r.musicbrainzHandlers.SearchTracks))
	r.mux.HandleFunc("GET /api/v1/musicbrainz/search/artists", r.withAuth(r.musicbrainzHandlers.SearchArtists))
	r.mux.HandleFunc("GET /api/v1/musicbrainz/search/albums", r.withAuth(r.musicbrainzHandlers.SearchAlbums))

	// Browse/discovery routes (auth required)
	r.mux.HandleFunc("GET /api/v1/artists/{mb_id}", r.withAuth(r.browseHandlers.GetArtist))
	r.mux.HandleFunc("GET /api/v1/albums/{mb_id}", r.withAuth(r.browseHandlers.GetAlbum))
	r.mux.HandleFunc("GET /api/v1/tracks/{mb_id}", r.withAuth(r.browseHandlers.GetTrack))
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
