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
	// Redis key prefix for user queues. Rename the playback-flavored `playqueue`
	// vocabulary toward import/readiness terms with the next schema-touching
	// change.
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
	ID            string           `json:"queueItemId"`
	Position      int              `json:"position"`
	Kind          string           `json:"kind"`
	TrackID       *int64           `json:"trackId"`
	PlaybackState string           `json:"playbackState"`
	DownloadJobID string           `json:"downloadJobId"`
	Source        *SourceCandidate `json:"sourceCandidate"`
	Progress      int              `json:"progress"`
	Error         string           `json:"error,omitempty"`
	CanPlay       bool             `json:"canPlay"`
	CanRetry      bool             `json:"canRetry"`
	CanRemove     bool             `json:"canRemove"`
	AddedAt       time.Time        `json:"addedAt"`
	UpdatedAt     time.Time        `json:"updatedAt"`
}

type SourceCandidate struct {
	CandidateID  string                 `json:"candidateId"`
	Provider     string                 `json:"provider"`
	SourceID     string                 `json:"sourceId,omitempty"`
	SourceURL    string                 `json:"sourceUrl"`
	Title        string                 `json:"title"`
	Artist       string                 `json:"artist,omitempty"`
	Album        string                 `json:"album,omitempty"`
	Uploader     string                 `json:"uploader,omitempty"`
	DurationMs   int                    `json:"durationMs,omitempty"`
	ThumbnailURL string                 `json:"thumbnailUrl,omitempty"`
	Downloadable bool                   `json:"downloadable"`
	Metadata     map[string]interface{} `json:"metadata,omitempty"`
}

// QueueState represents the full state of a user's playback queue
type QueueState struct {
	Items           []QueueItem `json:"items"`
	CurrentPosition int         `json:"currentPosition"`
	UpdatedAt       time.Time   `json:"updatedAt"`
}

// AddRequest represents a request to add tracks to the queue
type AddRequest struct {
	Type     string `json:"type"`     // "track" or "playlist"
	ID       int64  `json:"id"`       // track or playlist ID
	Position string `json:"position"` // "next", "last", or specific index
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
	return s.loadQueue(ctx, s.client, userID)
}

func (s *Service) loadQueue(ctx context.Context, client redis.Cmdable, userID string) (*QueueState, error) {
	data, err := client.Get(ctx, s.queueKey(userID)).Result()
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
	now := time.Now()
	trackIDCopy := trackID
	newItem := QueueItem{
		ID:            uuid.NewString(),
		Kind:          "track",
		TrackID:       &trackIDCopy,
		PlaybackState: "playable",
		Progress:      100,
		CanPlay:       true,
		CanRetry:      false,
		CanRemove:     true,
		AddedAt:       now,
		UpdatedAt:     now,
	}

	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
		if err != nil {
			return queueUnchanged, err
		}
		state.Items = insertAt(state.Items, insertIdx, newItem)
		if adjustCurrent {
			state.CurrentPosition++
		}
		return queueWrite, nil
	})
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
	return s.EnsureSourceCandidateWithID(ctx, userID, uuid.NewString(), candidate, downloadJobID, position)
}

// EnsureSourceCandidateWithID adds one source item for a durable intent. The
// stable item ID keeps restart recovery idempotent.
func (s *Service) EnsureSourceCandidateWithID(ctx context.Context, userID, queueItemID string, candidate SourceCandidate, downloadJobID, position string) (*QueueState, error) {
	now := time.Now()
	newItem := QueueItem{
		ID:            queueItemID,
		Kind:          "source",
		PlaybackState: "queued",
		DownloadJobID: downloadJobID,
		Source:        &candidate,
		Progress:      0,
		CanPlay:       false,
		CanRetry:      false,
		CanRemove:     true,
		AddedAt:       now,
		UpdatedAt:     now,
	}

	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		for _, item := range state.Items {
			if item.ID == queueItemID || item.DownloadJobID == downloadJobID {
				return queueUnchanged, nil
			}
		}
		insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
		if err != nil {
			return queueUnchanged, err
		}
		state.Items = insertAt(state.Items, insertIdx, newItem)
		if adjustCurrent {
			state.CurrentPosition++
		}
		return queueWrite, nil
	})
}

// AddMultipleToQueue adds multiple tracks to the queue (for playlist support)
func (s *Service) AddMultipleToQueue(ctx context.Context, userID string, trackIDs []int64, position string) (*QueueState, error) {
	now := time.Now()
	newItems := make([]QueueItem, len(trackIDs))
	for i, trackID := range trackIDs {
		trackIDCopy := trackID
		newItems[i] = QueueItem{
			ID:            uuid.NewString(),
			Kind:          "track",
			TrackID:       &trackIDCopy,
			PlaybackState: "playable",
			Progress:      100,
			CanPlay:       true,
			CanRetry:      false,
			CanRemove:     true,
			AddedAt:       now,
			UpdatedAt:     now,
		}
	}
	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		insertIdx, adjustCurrent, err := resolveInsertPosition(state, position)
		if err != nil {
			return queueUnchanged, err
		}
		state.Items = insertMultipleAt(state.Items, insertIdx, newItems)
		if adjustCurrent {
			state.CurrentPosition += len(newItems)
		}
		return queueWrite, nil
	})
}

// RemoveFromQueue removes a track at the specified position
func (s *Service) RemoveFromQueue(ctx context.Context, userID string, position int) (*QueueState, error) {
	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		return removeQueuePosition(state, position)
	})
}

func removeQueuePosition(state *QueueState, position int) (queueMutation, error) {
	if position < 0 || position >= len(state.Items) {
		return queueUnchanged, ErrInvalidPosition
	}
	state.Items = append(state.Items[:position], state.Items[position+1:]...)
	if position < state.CurrentPosition {
		state.CurrentPosition--
	} else if position == state.CurrentPosition && state.CurrentPosition >= len(state.Items) {
		if len(state.Items) > 0 {
			state.CurrentPosition = len(state.Items) - 1
		} else {
			state.CurrentPosition = 0
		}
	}
	return queueWrite, nil
}

// ReorderQueue moves a track from one position to another
func (s *Service) ReorderQueue(ctx context.Context, userID string, fromPos, toPos int) (*QueueState, error) {
	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		return reorderQueuePositions(state, fromPos, toPos)
	})
}

func reorderQueuePositions(state *QueueState, fromPos, toPos int) (queueMutation, error) {
	if fromPos < 0 || fromPos >= len(state.Items) || toPos < 0 || toPos >= len(state.Items) {
		return queueUnchanged, ErrInvalidPosition
	}
	if fromPos == toPos {
		return queueUnchanged, nil
	}
	item := state.Items[fromPos]
	state.Items = append(state.Items[:fromPos], state.Items[fromPos+1:]...)
	state.Items = insertAt(state.Items, toPos, item)
	if state.CurrentPosition == fromPos {
		state.CurrentPosition = toPos
	} else if fromPos < state.CurrentPosition && toPos >= state.CurrentPosition {
		state.CurrentPosition--
	} else if fromPos > state.CurrentPosition && toPos <= state.CurrentPosition {
		state.CurrentPosition++
	}
	return queueWrite, nil
}

// RemoveQueueItem removes the queue item with the specified server ID.
func (s *Service) RemoveQueueItem(ctx context.Context, userID, queueItemID string) (*QueueState, error) {
	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		for i, item := range state.Items {
			if item.ID == queueItemID {
				return removeQueuePosition(state, i)
			}
		}
		return queueUnchanged, ErrTrackNotFound
	})
}

// ReorderQueueItem moves a queue item by server ID.
func (s *Service) ReorderQueueItem(ctx context.Context, userID, queueItemID string, toPos int) (*QueueState, error) {
	return s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		for i, item := range state.Items {
			if item.ID == queueItemID {
				return reorderQueuePositions(state, i, toPos)
			}
		}
		return queueUnchanged, ErrTrackNotFound
	})
}

// QueueItemDownloadJobID returns the download job backing a queue item without
// mutating queue state. Retry handlers use this to validate/enqueue the download
// retry before projecting the queue item back to queued.
func (s *Service) QueueItemDownloadJobID(ctx context.Context, userID, queueItemID string) (string, error) {
	state, err := s.GetQueue(ctx, userID)
	if err != nil {
		return "", err
	}
	for i := range state.Items {
		item := &state.Items[i]
		if item.ID != queueItemID {
			continue
		}
		if item.DownloadJobID == "" {
			return "", ErrTrackNotFound
		}
		return item.DownloadJobID, nil
	}
	return "", ErrTrackNotFound
}

// RetryQueueItem marks a failed download-backed item as queued again.
func (s *Service) RetryQueueItem(ctx context.Context, userID, queueItemID string) (*QueueState, string, error) {
	jobID := ""
	state, err := s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		for i := range state.Items {
			item := &state.Items[i]
			if item.ID != queueItemID || item.DownloadJobID == "" {
				continue
			}
			item.PlaybackState = "queued"
			item.Progress = 0
			item.Error = ""
			item.CanPlay = false
			item.CanRetry = false
			item.CanRemove = true
			item.UpdatedAt = time.Now()
			jobID = item.DownloadJobID
			return queueWrite, nil
		}
		return queueUnchanged, ErrTrackNotFound
	})
	if err != nil {
		return nil, "", err
	}
	return state, jobID, nil
}

// ClearQueue clears all items from the queue
func (s *Service) ClearQueue(ctx context.Context, userID string) error {
	_, err := s.mutateQueue(ctx, userID, func(state *QueueState) (queueMutation, error) {
		state.Items = []QueueItem{}
		state.CurrentPosition = 0
		return queueDelete, nil
	})
	return err
}

type queueMutation uint8

const (
	queueUnchanged queueMutation = iota
	queueWrite
	queueDelete
	maxQueueMutationAttempts = 32
)

// mutateQueue is the only queue write authority. Each attempt reads and edits
// the value watched by this transaction; callbacks must have no external side
// effects and must not retain state between attempts. In particular, stable IDs
// must be resolved again here, never translated to positions before WATCH.
func (s *Service) mutateQueue(ctx context.Context, userID string, mutate func(*QueueState) (queueMutation, error)) (*QueueState, error) {
	key := s.queueKey(userID)
	for attempt := 0; attempt < maxQueueMutationAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var result *QueueState
		err := s.client.Watch(ctx, func(tx *redis.Tx) error {
			state, err := s.loadQueue(ctx, tx, userID)
			if err != nil {
				return err
			}
			action, err := mutate(state)
			if err != nil {
				return err
			}
			if action == queueUnchanged {
				result = state
				return nil
			}
			var data []byte
			if action == queueWrite {
				s.recalculatePositions(state)
				state.UpdatedAt = time.Now()
				data, err = json.Marshal(state)
				if err != nil {
					return fmt.Errorf("failed to marshal queue: %w", err)
				}
			}
			_, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
				if action == queueDelete {
					pipe.Del(ctx, key)
				} else {
					pipe.Set(ctx, key, data, queueTTL)
				}
				return nil
			})
			if err == nil {
				result = state
			}
			return err
		}, key)
		if !errors.Is(err, redis.TxFailedErr) {
			return result, err
		}
		if attempt+1 < maxQueueMutationAttempts {
			delay := time.NewTimer(time.Duration(min(attempt+1, 10)) * time.Millisecond)
			select {
			case <-ctx.Done():
				delay.Stop()
				return nil, ctx.Err()
			case <-delay.C:
			}
		}
	}
	return nil, fmt.Errorf("queue mutation conflicted after %d attempts: %w", maxQueueMutationAttempts, redis.TxFailedErr)
}

// recalculatePositions updates the position field for all items
func (s *Service) recalculatePositions(state *QueueState) {
	now := time.Now()
	for i := range state.Items {
		item := &state.Items[i]
		item.Position = i
		if item.Kind == "" {
			if item.Source != nil {
				item.Kind = "source"
			} else {
				item.Kind = "track"
			}
		}
		if item.PlaybackState == "" || item.PlaybackState == "pendingDownload" {
			item.PlaybackState = "queued"
		}
		if item.TrackID != nil && item.PlaybackState == "playable" {
			item.Progress = 100
			item.CanPlay = true
		}
		if item.PlaybackState == "failed" {
			item.CanRetry = true
			item.CanPlay = false
		}
		item.CanRemove = true
		if item.UpdatedAt.IsZero() {
			item.UpdatedAt = now
		}
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
