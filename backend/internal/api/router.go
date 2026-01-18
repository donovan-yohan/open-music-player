package api

import (
	"encoding/json"
	"net/http"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/search"
	"github.com/openmusicplayer/backend/internal/stream"
	"github.com/openmusicplayer/backend/internal/validators"
	"github.com/openmusicplayer/backend/internal/websocket"
)

type Router struct {
	mux                 *http.ServeMux
	authHandlers        *auth.Handlers
	authService         *auth.Service
	searchHandlers      *search.Handlers
	browseHandlers      *BrowseHandlers
	wsHandler           *websocket.Handler
	validatorHandlers   *validators.Handlers
	matcherHandlers     *matcher.Handler
	libraryHandlers     *LibraryHandlers
	streamHandler       *stream.Handler
}

func NewRouter(authHandlers *auth.Handlers, authService *auth.Service, searchHandlers *search.Handlers, mbClient *musicbrainz.Client, mbHandlers *musicbrainz.Handlers, wsHandler *websocket.Handler, matcherHandlers *matcher.Handler, libraryHandlers *LibraryHandlers, streamHandler *stream.Handler) *Router {
	validatorRegistry := validators.DefaultRegistry()

	r := &Router{
		mux:                 http.NewServeMux(),
		authHandlers:        authHandlers,
		authService:         authService,
		searchHandlers:      searchHandlers,
		browseHandlers:      NewBrowseHandlers(mbClient),
		musicbrainzHandlers: mbHandlers,
		wsHandler:           wsHandler,
		validatorHandlers:   validators.NewHandlers(validatorRegistry),
		matcherHandlers:     matcherHandlers,
		libraryHandlers:     libraryHandlers,
		streamHandler:       streamHandler,
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

	// WebSocket route (auth via query param)
	r.mux.HandleFunc("GET /api/v1/ws/progress", r.wsHandler.ServeWS)

	// URL validation routes (auth required)
	r.mux.HandleFunc("POST /api/v1/validate/url", r.withAuth(r.validatorHandlers.ValidateURL))
	r.mux.HandleFunc("GET /api/v1/validate/url", r.withAuth(r.validatorHandlers.ValidateURLQuery))
	r.mux.HandleFunc("GET /api/v1/validate/sources", r.withAuth(r.validatorHandlers.GetSupportedSources))

	// Auto-matching routes (auth required)
	r.mux.HandleFunc("POST /api/v1/match", r.withAuth(r.matcherHandlers.HandleMatch))
	r.mux.HandleFunc("POST /api/v1/tracks/{id}/match", r.withAuth(r.matcherHandlers.HandleMatchTrack))
	r.mux.HandleFunc("POST /api/v1/tracks/{id}/confirm-match", r.withAuth(r.matcherHandlers.HandleConfirmMatch))

	// Library routes (auth required)
	r.mux.HandleFunc("GET /api/v1/library", r.withAuth(r.libraryHandlers.GetLibrary))
	r.mux.HandleFunc("POST /api/v1/library/tracks/{track_id}", r.withAuth(r.libraryHandlers.AddTrackToLibrary))
	r.mux.HandleFunc("DELETE /api/v1/library/tracks/{track_id}", r.withAuth(r.libraryHandlers.RemoveTrackFromLibrary))

	// Audio streaming route (auth required)
	r.mux.HandleFunc("GET /api/v1/stream/{track_id}", r.withAuth(r.streamHandler.Stream))
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
