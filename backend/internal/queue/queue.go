package queue

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	// Redis key prefix for user queues
	keyQueuePrefix = "playqueue:"

	// TTL for queue data (24 hours)
	queueTTL = 24 * time.Hour
)

var (
	ErrQueueEmpty     = errors.New("queue is empty")
	ErrInvalidPosition = errors.New("invalid position")
	ErrTrackNotFound  = errors.New("track not found in queue")
)

// QueueItem represents a track in the playback queue
type QueueItem struct {
	Position int        `json:"position"`
	TrackID  int64      `json:"track_id"`
	AddedAt  time.Time  `json:"added_at"`
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

	newItem := QueueItem{
		TrackID: trackID,
		AddedAt: time.Now(),
	}

	switch position {
	case "next":
		// Insert after current position
		insertIdx := state.CurrentPosition + 1
		if insertIdx > len(state.Items) {
			insertIdx = len(state.Items)
		}
		state.Items = insertAt(state.Items, insertIdx, newItem)
	case "last", "":
		// Append to end
		state.Items = append(state.Items, newItem)
	default:
		// Try to parse as index
		var idx int
		if _, err := fmt.Sscanf(position, "%d", &idx); err != nil {
			return nil, fmt.Errorf("invalid position: %s", position)
		}
		if idx < 0 || idx > len(state.Items) {
			return nil, ErrInvalidPosition
		}
		state.Items = insertAt(state.Items, idx, newItem)
		// Adjust current position if inserting before it
		if idx <= state.CurrentPosition {
			state.CurrentPosition++
		}
	}

	// Recalculate positions
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
		newItems[i] = QueueItem{
			TrackID: trackID,
			AddedAt: now,
		}
	}

	switch position {
	case "next":
		insertIdx := state.CurrentPosition + 1
		if insertIdx > len(state.Items) {
			insertIdx = len(state.Items)
		}
		state.Items = insertMultipleAt(state.Items, insertIdx, newItems)
	case "last", "":
		state.Items = append(state.Items, newItems...)
	default:
		var idx int
		if _, err := fmt.Sscanf(position, "%d", &idx); err != nil {
			return nil, fmt.Errorf("invalid position: %s", position)
		}
		if idx < 0 || idx > len(state.Items) {
			return nil, ErrInvalidPosition
		}
		state.Items = insertMultipleAt(state.Items, idx, newItems)
		if idx <= state.CurrentPosition {
			state.CurrentPosition += len(newItems)
		}
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
