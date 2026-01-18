package api

import (
	"encoding/json"
	"net/http"

	"github.com/openmusicplayer/backend/internal/auth"
	apperrors "github.com/openmusicplayer/backend/internal/errors"
	"github.com/openmusicplayer/backend/internal/health"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/metrics"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/queue"
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
	musicbrainzHandlers *musicbrainz.Handlers
	wsHandler           *websocket.Handler
	validatorHandlers   *validators.Handlers
	matcherHandlers     *matcher.Handler
	libraryHandlers     *LibraryHandlers
	streamHandler       *stream.Handler
	queueHandlers       *queue.Handlers
	playlistHandlers    *PlaylistHandlers
	downloadHandlers    *DownloadHandlers
	healthHandler       *health.Handler
	metricsHandler      http.HandlerFunc
}

// RouterConfig holds configuration for creating a new router
type RouterConfig struct {
	AuthHandlers        *auth.Handlers
	AuthService         *auth.Service
	SearchHandlers      *search.Handlers
	MBClient            *musicbrainz.Client
	MBHandlers          *musicbrainz.Handlers
	WSHandler           *websocket.Handler
	MatcherHandlers     *matcher.Handler
	LibraryHandlers     *LibraryHandlers
	StreamHandler       *stream.Handler
	QueueHandlers       *queue.Handlers
	PlaylistHandlers    *PlaylistHandlers
	DownloadHandlers    *DownloadHandlers
	HealthHandler       *health.Handler
	Metrics             *metrics.Metrics
}

func NewRouter(authHandlers *auth.Handlers, authService *auth.Service, searchHandlers *search.Handlers, mbClient *musicbrainz.Client, mbHandlers *musicbrainz.Handlers, wsHandler *websocket.Handler, matcherHandlers *matcher.Handler, libraryHandlers *LibraryHandlers, streamHandler *stream.Handler, queueHandlers *queue.Handlers, playlistHandlers *PlaylistHandlers, downloadHandlers *DownloadHandlers) *Router {
	return NewRouterWithConfig(&RouterConfig{
		AuthHandlers:     authHandlers,
		AuthService:      authService,
		SearchHandlers:   searchHandlers,
		MBClient:         mbClient,
		MBHandlers:       mbHandlers,
		WSHandler:        wsHandler,
		MatcherHandlers:  matcherHandlers,
		LibraryHandlers:  libraryHandlers,
		StreamHandler:    streamHandler,
		QueueHandlers:    queueHandlers,
		PlaylistHandlers: playlistHandlers,
		DownloadHandlers: downloadHandlers,
	})
}

func NewRouterWithConfig(cfg *RouterConfig) *Router {
	validatorRegistry := validators.DefaultRegistry()

	var metricsHandler http.HandlerFunc
	if cfg.Metrics != nil {
		metricsHandler = cfg.Metrics.Handler()
	}

	r := &Router{
		mux:                 http.NewServeMux(),
		authHandlers:        cfg.AuthHandlers,
		authService:         cfg.AuthService,
		searchHandlers:      cfg.SearchHandlers,
		browseHandlers:      NewBrowseHandlers(cfg.MBClient),
		musicbrainzHandlers: cfg.MBHandlers,
		wsHandler:           cfg.WSHandler,
		validatorHandlers:   validators.NewHandlers(validatorRegistry),
		matcherHandlers:     cfg.MatcherHandlers,
		libraryHandlers:     cfg.LibraryHandlers,
		streamHandler:       cfg.StreamHandler,
		queueHandlers:       cfg.QueueHandlers,
		playlistHandlers:    cfg.PlaylistHandlers,
		downloadHandlers:    cfg.DownloadHandlers,
		healthHandler:       cfg.HealthHandler,
		metricsHandler:      metricsHandler,
	}
	r.setupRoutes()
	return r
}

func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	// Apply middleware chain: Recovery -> RequestID -> Logging -> Routes
	handler := logger.RecoveryMiddleware(
		apperrors.RequestIDMiddleware(
			logger.LoggingMiddleware(r.mux),
		),
	)
	handler.ServeHTTP(w, req)
}

func (r *Router) setupRoutes() {
	// Health check endpoints (Kubernetes-compatible)
	if r.healthHandler != nil {
		r.mux.HandleFunc("GET /health", r.healthHandler.HealthHandler)
		r.mux.HandleFunc("GET /health/live", r.healthHandler.LivenessHandler)
		r.mux.HandleFunc("GET /health/ready", r.healthHandler.ReadinessHandler)
	} else {
		// Fallback to simple health check if handler not configured
		r.mux.HandleFunc("GET /health", defaultHealthHandler)
	}

	// Metrics endpoint (Prometheus-compatible)
	if r.metricsHandler != nil {
		r.mux.HandleFunc("GET /metrics", r.metricsHandler)
	}

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
	r.mux.HandleFunc("POST /api/v1/tracks/{id}/link-mb", r.withAuth(r.matcherHandlers.HandleLinkMB))

	// Library routes (auth required)
	r.mux.HandleFunc("GET /api/v1/library", r.withAuth(r.libraryHandlers.GetLibrary))
	r.mux.HandleFunc("POST /api/v1/library/tracks/{track_id}", r.withAuth(r.libraryHandlers.AddTrackToLibrary))
	r.mux.HandleFunc("DELETE /api/v1/library/tracks/{track_id}", r.withAuth(r.libraryHandlers.RemoveTrackFromLibrary))

	// Audio streaming route (auth required)
	r.mux.HandleFunc("GET /api/v1/stream/{track_id}", r.withAuth(r.streamHandler.Stream))

	// Queue routes (auth required)
	r.mux.HandleFunc("GET /api/v1/queue", r.withAuth(r.queueHandlers.GetQueue))
	r.mux.HandleFunc("POST /api/v1/queue", r.withAuth(r.queueHandlers.AddToQueue))
	r.mux.HandleFunc("DELETE /api/v1/queue/{position}", r.withAuth(r.queueHandlers.RemoveFromQueue))
	r.mux.HandleFunc("PUT /api/v1/queue/reorder", r.withAuth(r.queueHandlers.ReorderQueue))
	r.mux.HandleFunc("DELETE /api/v1/queue", r.withAuth(r.queueHandlers.ClearQueue))

	// Playlist routes (auth required)
	r.mux.HandleFunc("GET /api/v1/playlists", r.withAuth(r.playlistHandlers.ListPlaylists))
	r.mux.HandleFunc("POST /api/v1/playlists", r.withAuth(r.playlistHandlers.CreatePlaylist))
	r.mux.HandleFunc("GET /api/v1/playlists/{id}", r.withAuth(r.playlistHandlers.GetPlaylist))
	r.mux.HandleFunc("PUT /api/v1/playlists/{id}", r.withAuth(r.playlistHandlers.UpdatePlaylist))
	r.mux.HandleFunc("DELETE /api/v1/playlists/{id}", r.withAuth(r.playlistHandlers.DeletePlaylist))
	r.mux.HandleFunc("POST /api/v1/playlists/{id}/tracks", r.withAuth(r.playlistHandlers.AddTracks))
	r.mux.HandleFunc("DELETE /api/v1/playlists/{id}/tracks/{trackId}", r.withAuth(r.playlistHandlers.RemoveTrack))
	r.mux.HandleFunc("PUT /api/v1/playlists/{id}/tracks/reorder", r.withAuth(r.playlistHandlers.ReorderTracks))

	// Download routes (auth required)
	r.mux.HandleFunc("POST /api/v1/downloads", r.withAuth(r.downloadHandlers.CreateDownload))
	r.mux.HandleFunc("GET /api/v1/downloads", r.withAuth(r.downloadHandlers.GetUserJobs))
	r.mux.HandleFunc("GET /api/v1/downloads/{job_id}", r.withAuth(r.downloadHandlers.GetJob))
}

func (r *Router) withAuth(next http.HandlerFunc) http.HandlerFunc {
	middleware := auth.Middleware(r.authService)
	return func(w http.ResponseWriter, req *http.Request) {
		middleware(http.HandlerFunc(next)).ServeHTTP(w, req)
	}
}

func defaultHealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok",
	})
}
