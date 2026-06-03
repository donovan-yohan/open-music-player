package queue

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const (
	// Redis key prefix for user queues
	keyQueuePrefix = "playqueue:"

	// TTL for queue data (24 hours)
	queueTTL = 24 * time.Hour
)

var (
	ErrQueueEmpty      = errors.New("queue is empty")
	ErrInvalidPosition = errors.New("invalid position")
	ErrTrackNotFound   = errors.New("track not found in queue")
)

// QueueItem represents an entry in the playback queue. Source-backed entries
// are pending/non-playable until their download job resolves to a track ID.
type QueueItem struct {
	ID            string           `json:"id"`
	Position      int              `json:"position"`
	TrackID       *int64           `json:"track_id,omitempty"`
	PlaybackState string           `json:"playback_state"`
	DownloadJobID string           `json:"download_job_id,omitempty"`
	Source        *SourceCandidate `json:"source_candidate,omitempty"`
	AddedAt       time.Time        `json:"added_at"`
}

type SourceCandidate struct {
	CandidateID  string `json:"candidateId"`
	Provider     string `json:"provider"`
	SourceID     string `json:"sourceId,omitempty"`
	SourceURL    string `json:"sourceUrl"`
	Title        string `json:"title"`
	Artist       string `json:"artist,omitempty"`
	Album        string `json:"album,omitempty"`
	Uploader     string `json:"uploader,omitempty"`
	DurationMs   int    `json:"durationMs,omitempty"`
	ThumbnailURL string `json:"thumbnailUrl,omitempty"`
	Downloadable bool   `json:"downloadable"`
}

// QueueState represents the full state of a user's playback queue
type QueueState struct {
	Items           []QueueItem `json:"items"`
	CurrentPosition int         `json:"current_position"`
	UpdatedAt       time.Time   `json:"updated_at"`
}

// AddRequest represents a request to add tracks to the queue
type AddRequest struct {
	Type     string `json:"type"`     // "track" or "playlist"
	ID       int64  `json:"id"`       // track or playlist ID
	Position string `json:"position"` // "next", "last", or specific index
}

// ReorderRequest represents a request to reorder the queue
type ReorderRequest struct {
	FromPosition int `json:"from_position"`
	ToPosition   int `json:"to_position"`
}

// Service manages playback queues using Redis
type Service struct {
	client *redis.Client
}

// NewService creates a new queue service with the given Redis URL
func NewService(redisURL string) (*Service, error) {
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse redis URL: %w", err)
	}

	client := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to redis: %w", err)
	}

	return &Service{client: client}, nil
}

// Close closes the Redis connection
func (s *Service) Close() error {
	return s.client.Close()
}

// queueKey returns the Redis key for a user's queue
func (s *Service) queueKey(userID string) string {
	return keyQueuePrefix + userID
}

// GetQueue retrieves the current queue for a user
func (s *Service) GetQueue(ctx context.Context, userID string) (*QueueState, error) {
	data, err := s.client.Get(ctx, s.queueKey(userID)).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			// Return empty queue if none exists
			return &QueueState{
				Items:           []QueueItem{},
				CurrentPosition: 0,
				UpdatedAt:       time.Now(),
			}, nil
		}
		return nil, fmt.Errorf("failed to get queue: %w", err)
	}

	var state QueueState
	if err := json.Unmarshal([]byte(data), &state); err != nil {
		return nil, fmt.Errorf("failed to unmarshal queue: %w", err)
	}

	return &state, nil
}

// AddToQueue adds a track to the queue
func (s *Service) AddToQueue(ctx context.Context, userID string, trackID int64, position string) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	trackIDCopy := trackID
	newItem := QueueItem{
		ID:            uuid.NewString(),
		TrackID:       &trackIDCopy,
		PlaybackState: "playable",
		AddedAt:       time.Now(),
	}

	insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
	if err != nil {
		return nil, err
	}
	state.Items = insertAt(state.Items, insertIdx, newItem)
	if adjustCurrent {
		state.CurrentPosition++
	}

	// Recalculate positions
	s.recalculatePositions(state)
	state.UpdatedAt = time.Now()

	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}

	return state, nil
}

// ValidateInsertPosition verifies that a queue insertion position can be
// applied to the user's current queue before side effects like download enqueue.
func (s *Service) ValidateInsertPosition(ctx context.Context, userID string, position string) error {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return err
	}
	_, _, err = resolveInsertPosition(state, position)
	return err
}

func resolveInsertPosition(state *QueueState, position string) (int, bool, error) {
	switch strings.TrimSpace(position) {
	case "next":
		insertIdx := state.CurrentPosition + 1
		if insertIdx > len(state.Items) {
			insertIdx = len(state.Items)
		}
		return insertIdx, false, nil
	case "last", "":
		return len(state.Items), false, nil
	default:
		idx, err := strconv.Atoi(strings.TrimSpace(position))
		if err != nil {
			return 0, false, ErrInvalidPosition
		}
		if idx < 0 || idx > len(state.Items) {
			return 0, false, ErrInvalidPosition
		}
		return idx, idx <= state.CurrentPosition, nil
	}
}

// AddSourceCandidate adds a non-playable discovery candidate to the queue.
func (s *Service) AddSourceCandidate(ctx context.Context, userID string, candidate SourceCandidate, downloadJobID, position string) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	newItem := QueueItem{
		ID:            uuid.NewString(),
		PlaybackState: "pendingDownload",
		DownloadJobID: downloadJobID,
		Source:        &candidate,
		AddedAt:       time.Now(),
	}

	insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
	if err != nil {
		return nil, err
	}
	state.Items = insertAt(state.Items, insertIdx, newItem)
	if adjustCurrent {
		state.CurrentPosition++
	}

	s.recalculatePositions(state)
	state.UpdatedAt = time.Now()
	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}
	return state, nil
}

// AddMultipleToQueue adds multiple tracks to the queue (for playlist support)
func (s *Service) AddMultipleToQueue(ctx context.Context, userID string, trackIDs []int64, position string) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	newItems := make([]QueueItem, len(trackIDs))
	for i, trackID := range trackIDs {
		trackIDCopy := trackID
		newItems[i] = QueueItem{
			ID:            uuid.NewString(),
			TrackID:       &trackIDCopy,
			PlaybackState: "playable",
			AddedAt:       now,
		}
	}

	insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
	if err != nil {
		return nil, err
	}
	state.Items = insertMultipleAt(state.Items, insertIdx, newItems)
	if adjustCurrent {
		state.CurrentPosition += len(newItems)
	}

	s.recalculatePositions(state)
	state.UpdatedAt = time.Now()

	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}

	return state, nil
}

// RemoveFromQueue removes a track at the specified position
func (s *Service) RemoveFromQueue(ctx context.Context, userID string, position int) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	if position < 0 || position >= len(state.Items) {
		return nil, ErrInvalidPosition
	}

	// Remove the item
	state.Items = append(state.Items[:position], state.Items[position+1:]...)

	// Adjust current position if needed
	if position < state.CurrentPosition {
		state.CurrentPosition--
	} else if position == state.CurrentPosition && state.CurrentPosition >= len(state.Items) {
		// If we removed the current track and it was the last one, move back
		if len(state.Items) > 0 {
			state.CurrentPosition = len(state.Items) - 1
		} else {
			state.CurrentPosition = 0
		}
	}

	s.recalculatePositions(state)
	state.UpdatedAt = time.Now()

	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}

	return state, nil
}

// ReorderQueue moves a track from one position to another
func (s *Service) ReorderQueue(ctx context.Context, userID string, fromPos, toPos int) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	if fromPos < 0 || fromPos >= len(state.Items) {
		return nil, ErrInvalidPosition
	}
	if toPos < 0 || toPos >= len(state.Items) {
		return nil, ErrInvalidPosition
	}

	if fromPos == toPos {
		return state, nil
	}

	// Remove item from original position
	item := state.Items[fromPos]
	state.Items = append(state.Items[:fromPos], state.Items[fromPos+1:]...)

	// Insert at new position
	state.Items = insertAt(state.Items, toPos, item)

	// Adjust current position
	if state.CurrentPosition == fromPos {
		state.CurrentPosition = toPos
	} else if fromPos < state.CurrentPosition && toPos >= state.CurrentPosition {
		state.CurrentPosition--
	} else if fromPos > state.CurrentPosition && toPos <= state.CurrentPosition {
		state.CurrentPosition++
	}

	s.recalculatePositions(state)
	state.UpdatedAt = time.Now()

	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}

	return state, nil
}

// ClearQueue clears all items from the queue
func (s *Service) ClearQueue(ctx context.Context, userID string) error {
	return s.client.Del(ctx, s.queueKey(userID)).Err()
}

// SetCurrentPosition updates the current playback position
func (s *Service) SetCurrentPosition(ctx context.Context, userID string, position int) (*QueueState, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return nil, err
	}

	if len(state.Items) == 0 {
		return nil, ErrQueueEmpty
	}

	if position < 0 || position >= len(state.Items) {
		return nil, ErrInvalidPosition
	}

	state.CurrentPosition = position
	state.UpdatedAt = time.Now()

	if err := s.saveQueue(ctx, userID, state); err != nil {
		return nil, err
	}

	return state, nil
}

// saveQueue saves the queue state to Redis with TTL
func (s *Service) saveQueue(ctx context.Context, userID string, state *QueueState) error {
	data, err := json.Marshal(state)
	if err != nil {
		return fmt.Errorf("failed to marshal queue: %w", err)
	}

	return s.client.Set(ctx, s.queueKey(userID), data, queueTTL).Err()
}

// recalculatePositions updates the position field for all items
func (s *Service) recalculatePositions(state *QueueState) {
	for i := range state.Items {
		state.Items[i].Position = i
	}
}

// insertAt inserts an item at the specified index
func insertAt(items []QueueItem, idx int, item QueueItem) []QueueItem {
	if idx >= len(items) {
		return append(items, item)
	}
	items = append(items[:idx+1], items[idx:]...)
	items[idx] = item
	return items
}

// insertMultipleAt inserts multiple items at the specified index
func insertMultipleAt(items []QueueItem, idx int, newItems []QueueItem) []QueueItem {
	if idx >= len(items) {
		return append(items, newItems...)
	}
	result := make([]QueueItem, 0, len(items)+len(newItems))
	result = append(result, items[:idx]...)
	result = append(result, newItems...)
	result = append(result, items[idx:]...)
	return result
}
