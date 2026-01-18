package websocket

import (
	"sync"
)

// Hub maintains the set of active clients and broadcasts messages to them.
type Hub struct {
	// Registered clients by user ID
	clients map[int64]map[*Client]bool

	// Register requests from clients
	register chan *Client

	// Unregister requests from clients
	unregister chan *Client

	// Broadcast channel for progress updates
	broadcast chan *ProgressMessage

	mu sync.RWMutex
}

// ProgressMessage represents a download progress update.
type ProgressMessage struct {
	Type       string `json:"type"`
	JobID      int64  `json:"job_id"`
	UserID     int64  `json:"-"` // Not sent to client, used for routing
	Status     string `json:"status"`
	Progress   int    `json:"progress"`
	Error      string `json:"error,omitempty"`
	TrackTitle string `json:"track_title,omitempty"`
	ArtistName string `json:"artist_name,omitempty"`
}

// NewHub creates a new Hub instance.
func NewHub() *Hub {
	return &Hub{
		clients:    make(map[int64]map[*Client]bool),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan *ProgressMessage),
	}
}

// Run starts the hub's main loop.
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			if h.clients[client.userID] == nil {
				h.clients[client.userID] = make(map[*Client]bool)
			}
			h.clients[client.userID][client] = true
			h.mu.Unlock()

		case client := <-h.unregister:
			h.mu.Lock()
			if clients, ok := h.clients[client.userID]; ok {
				if _, ok := clients[client]; ok {
					delete(clients, client)
					close(client.send)
					if len(clients) == 0 {
						delete(h.clients, client.userID)
					}
				}
			}
			h.mu.Unlock()

		case message := <-h.broadcast:
			h.mu.RLock()
			if clients, ok := h.clients[message.UserID]; ok {
				for client := range clients {
					select {
					case client.send <- message:
					default:
						// Client's buffer is full, close the connection
						close(client.send)
						delete(clients, client)
					}
				}
			}
			h.mu.RUnlock()
		}
	}
}

// BroadcastProgress sends a progress update to all clients of a specific user.
func (h *Hub) BroadcastProgress(msg *ProgressMessage) {
	h.broadcast <- msg
}

// ClientCount returns the number of connected clients for a user.
func (h *Hub) ClientCount(userID int64) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if clients, ok := h.clients[userID]; ok {
		return len(clients)
	}
	return 0
}

// TotalClients returns the total number of connected clients.
func (h *Hub) TotalClients() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	count := 0
	for _, clients := range h.clients {
		count += len(clients)
	}
	return count
}
