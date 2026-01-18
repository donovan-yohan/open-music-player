package websocket

import "github.com/google/uuid"

// ProgressTracker provides an interface for broadcasting download progress updates.
type ProgressTracker struct {
	hub *Hub
}

// NewProgressTracker creates a new progress tracker.
func NewProgressTracker(hub *Hub) *ProgressTracker {
	return &ProgressTracker{hub: hub}
}

// UpdateProgress sends a progress update for a download job.
func (pt *ProgressTracker) UpdateProgress(userID uuid.UUID, jobID int64, status string, progress int, trackTitle, artistName string) {
	userIDInt := uuidToInt64(userID)
	pt.hub.BroadcastProgress(&ProgressMessage{
		Type:       "download_progress",
		JobID:      jobID,
		UserID:     userIDInt,
		Status:     status,
		Progress:   progress,
		TrackTitle: trackTitle,
		ArtistName: artistName,
	})
}

// SendError sends an error notification for a download job.
func (pt *ProgressTracker) SendError(userID uuid.UUID, jobID int64, errorMsg string) {
	userIDInt := uuidToInt64(userID)
	pt.hub.BroadcastProgress(&ProgressMessage{
		Type:   "download_progress",
		JobID:  jobID,
		UserID: userIDInt,
		Status: "failed",
		Error:  errorMsg,
	})
}

// SendCompletion sends a completion notification for a download job.
func (pt *ProgressTracker) SendCompletion(userID uuid.UUID, jobID int64, trackTitle, artistName string) {
	userIDInt := uuidToInt64(userID)
	pt.hub.BroadcastProgress(&ProgressMessage{
		Type:       "download_progress",
		JobID:      jobID,
		UserID:     userIDInt,
		Status:     "completed",
		Progress:   100,
		TrackTitle: trackTitle,
		ArtistName: artistName,
	})
}

// HasConnectedClients checks if a user has any active WebSocket connections.
func (pt *ProgressTracker) HasConnectedClients(userID uuid.UUID) bool {
	userIDInt := uuidToInt64(userID)
	return pt.hub.ClientCount(userIDInt) > 0
}
