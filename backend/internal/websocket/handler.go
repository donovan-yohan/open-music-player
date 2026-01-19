package websocket

import (
	"log"
	"net/http"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"

	"github.com/openmusicplayer/backend/internal/auth"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// TODO: Configure allowed origins for production
		return true
	},
}

// Handler handles WebSocket connections.
type Handler struct {
	hub         *Hub
	authService *auth.Service
}

// NewHandler creates a new WebSocket handler.
func NewHandler(hub *Hub, authService *auth.Service) *Handler {
	return &Handler{
		hub:         hub,
		authService: authService,
	}
}

// ServeWS handles WebSocket requests from clients.
// Authentication is done via query parameter: ?token=<jwt_token>
// This is necessary because browser WebSocket API doesn't support custom headers.
func (h *Handler) ServeWS(w http.ResponseWriter, r *http.Request) {
	// Get token from query parameter
	token := r.URL.Query().Get("token")
	if token == "" {
		http.Error(w, `{"code":"UNAUTHORIZED","message":"missing token parameter"}`, http.StatusUnauthorized)
		return
	}

	// Validate the token
	claims, err := h.authService.ValidateAccessToken(token)
	if err != nil {
		if err == auth.ErrTokenExpired {
			http.Error(w, `{"code":"TOKEN_EXPIRED","message":"access token has expired"}`, http.StatusUnauthorized)
			return
		}
		http.Error(w, `{"code":"UNAUTHORIZED","message":"invalid access token"}`, http.StatusUnauthorized)
		return
	}

	userID, err := uuid.Parse(claims.UserID)
	if err != nil {
		http.Error(w, `{"code":"UNAUTHORIZED","message":"invalid user ID in token"}`, http.StatusUnauthorized)
		return
	}

	// Upgrade HTTP connection to WebSocket
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade failed: %v", err)
		return
	}

	// Convert UUID to int64 for client tracking
	// Using the first 8 bytes of the UUID as a unique identifier
	userIDInt := uuidToInt64(userID)

	client := NewClient(h.hub, conn, userIDInt)
	h.hub.register <- client

	// Start the client's read and write pumps
	go client.WritePump()
	go client.ReadPump()
}

// uuidToInt64 converts a UUID to an int64 using the first 8 bytes.
// This provides a unique identifier suitable for map keys.
func uuidToInt64(u uuid.UUID) int64 {
	bytes := u[:]
	var result int64
	for i := 0; i < 8; i++ {
		result = (result << 8) | int64(bytes[i])
	}
	return result
}

// GetHub returns the hub instance for external access.
func (h *Handler) GetHub() *Hub {
	return h.hub
}
