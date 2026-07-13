package download

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const (
	// Redis key prefixes
	keyJobQueue  = "download:queue"
	keyJobStatus = "download:job:"
	keyProgress  = "download:progress"

	// Default timeout for blocking operations
	defaultBlockTimeout = 5 * time.Second
)

var (
	ErrJobNotFound     = errors.New("job not found")
	ErrQueueEmpty      = errors.New("queue is empty")
	ErrJobNotRetryable = errors.New("job is not retryable")
)

// Queue manages download jobs using Redis
type Queue struct {
	client *redis.Client
}

// SourceCandidate carries normalized discovery metadata into the download worker.
type SourceCandidate struct {
	CandidateID  string
	Provider     string
	SourceID     string
	SourceURL    string
	Title        string
	Artist       string
	Album        string
	Uploader     string
	DurationMs   int
	ThumbnailURL string
	Metadata     map[string]interface{}
}

// NewQueue creates a new job queue with the given Redis URL
func NewQueue(redisURL string) (*Queue, error) {
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

	return &Queue{client: client}, nil
}

// Client returns the underlying Redis client for pub/sub operations
func (q *Queue) Client() *redis.Client {
	return q.client
}

// Close closes the Redis connection
func (q *Queue) Close() error {
	return q.client.Close()
}

// Enqueue adds a new job to the queue
func (q *Queue) Enqueue(ctx context.Context, userID, url, sourceType string, mbRecordingID *string) (*DownloadJob, error) {
	return q.enqueueJob(ctx, &DownloadJob{
		UserID:        userID,
		URL:           url,
		SourceType:    sourceType,
		MBRecordingID: mbRecordingID,
	})
}

// EnqueueCandidate adds a discovery source candidate to the queue with enough
// metadata for the worker to create a local playable track.
func (q *Queue) EnqueueCandidate(ctx context.Context, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	return q.EnqueueCandidateWithID(ctx, "", userID, candidate, mbRecordingID)
}

// EnqueueCandidateWithID adds a discovery source candidate with a caller-provided
// job ID. This lets API handlers persist a visible queue item before publishing
// the job to workers.
func (q *Queue) EnqueueCandidateWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	return q.enqueueJob(ctx, &DownloadJob{
		ID:            jobID,
		UserID:        userID,
		URL:           candidate.SourceURL,
		SourceType:    candidate.Provider,
		MBRecordingID: mbRecordingID,
		CandidateID:   candidate.CandidateID,
		SourceID:      candidate.SourceID,
		Title:         candidate.Title,
		Artist:        candidate.Artist,
		Album:         candidate.Album,
		Uploader:      candidate.Uploader,
		DurationMs:    candidate.DurationMs,
		ThumbnailURL:  candidate.ThumbnailURL,
		Metadata:      candidate.Metadata,
	})
}

// EnsureCandidateWithID restores a missing queue-list entry after a process
// restart without creating another entry for a job that is already queued.
func (q *Queue) EnsureCandidateWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	job, err := q.GetJob(ctx, jobID)
	if err == nil {
		if job.UserID != userID {
			return nil, fmt.Errorf("download job %s belongs to another user", jobID)
		}
		if !job.IsTerminal() {
			_, positionErr := q.client.LPos(ctx, keyJobQueue, jobID, redis.LPosArgs{}).Result()
			switch {
			case positionErr == nil:
				return job, nil
			case errors.Is(positionErr, redis.Nil):
				if err := q.client.LPush(ctx, keyJobQueue, jobID).Err(); err != nil {
					return nil, fmt.Errorf("restore queued job: %w", err)
				}
				return job, nil
			default:
				return nil, fmt.Errorf("check queued job: %w", positionErr)
			}
		}
		return job, nil
	} else if !errors.Is(err, ErrJobNotFound) {
		return nil, err
	}
	return q.EnqueueCandidateWithID(ctx, jobID, userID, candidate, mbRecordingID)
}

// EnsurePlaylistImportItemWithID restores a playlist-import job with its
// processor metadata intact. It is separate from generic source recovery so a
// recovered job can still attach the completed track at the intended position.
func (q *Queue) EnsurePlaylistImportItemWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, importJobID string, importItemID, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	job, err := q.GetJob(ctx, jobID)
	if err == nil {
		if job.UserID != userID {
			return nil, fmt.Errorf("download job %s belongs to another user", jobID)
		}
		if !job.IsTerminal() {
			if job.PlaylistImportJobID != importJobID || job.PlaylistImportItemID != importItemID || job.PlaylistID != playlistID || job.PlaylistPosition != playlistPosition {
				return nil, fmt.Errorf("playlist import metadata mismatch for download job %s", jobID)
			}
			_, positionErr := q.client.LPos(ctx, keyJobQueue, jobID, redis.LPosArgs{}).Result()
			switch {
			case positionErr == nil:
			case errors.Is(positionErr, redis.Nil):
				if err := q.client.LPush(ctx, keyJobQueue, jobID).Err(); err != nil {
					return nil, fmt.Errorf("restore queued playlist import job: %w", err)
				}
			default:
				return nil, fmt.Errorf("check queued playlist import job: %w", positionErr)
			}
			return job, nil
		}
		return job, nil
	} else if !errors.Is(err, ErrJobNotFound) {
		return nil, err
	}
	return q.EnqueuePlaylistImportItemWithID(ctx, jobID, userID, candidate, importJobID, importItemID, playlistID, playlistPosition)
}

// EnqueuePlaylistImportItem queues a playlist import item with target playlist
// placement metadata for the processor to attach the completed/reused track.
func (q *Queue) EnqueuePlaylistImportItem(ctx context.Context, userID string, candidate SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	return q.EnqueuePlaylistImportItemWithID(ctx, "", userID, candidate, importJobID, importItemID, playlistID, playlistPosition)
}

// EnqueuePlaylistImportItemWithID publishes a playlist item using a durable
// caller-provided job ID. Source-selection ingestion uses it after SQL commit.
func (q *Queue) EnqueuePlaylistImportItemWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	return q.enqueueJob(ctx, &DownloadJob{
		ID:                   jobID,
		UserID:               userID,
		URL:                  candidate.SourceURL,
		SourceType:           candidate.Provider,
		CandidateID:          candidate.CandidateID,
		SourceID:             candidate.SourceID,
		Title:                candidate.Title,
		Artist:               candidate.Artist,
		Album:                candidate.Album,
		Uploader:             candidate.Uploader,
		DurationMs:           candidate.DurationMs,
		ThumbnailURL:         candidate.ThumbnailURL,
		Metadata:             candidate.Metadata,
		PlaylistImportJobID:  importJobID,
		PlaylistImportItemID: importItemID,
		PlaylistID:           playlistID,
		PlaylistPosition:     playlistPosition,
	})
}

func (q *Queue) enqueueJob(ctx context.Context, job *DownloadJob) (*DownloadJob, error) {
	now := time.Now()
	if job.ID == "" {
		job.ID = uuid.New().String()
	}
	job.Status = StatusQueued
	job.Progress = 0
	job.RetryCount = 0
	job.CreatedAt = now
	job.UpdatedAt = now

	if err := q.saveJob(ctx, job); err != nil {
		return nil, err
	}

	if err := q.client.LPush(ctx, keyJobQueue, job.ID).Err(); err != nil {
		_ = q.client.Del(ctx, keyJobStatus+job.ID).Err()
		return nil, fmt.Errorf("failed to enqueue job: %w", err)
	}

	return job, nil
}

// Dequeue retrieves and removes a job from the queue (blocking)
func (q *Queue) Dequeue(ctx context.Context, timeout time.Duration) (*DownloadJob, error) {
	if timeout == 0 {
		timeout = defaultBlockTimeout
	}

	result, err := q.client.BRPop(ctx, timeout, keyJobQueue).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrQueueEmpty
		}
		return nil, fmt.Errorf("failed to dequeue job: %w", err)
	}

	if len(result) < 2 {
		return nil, ErrQueueEmpty
	}

	jobID := result[1]
	return q.GetJob(ctx, jobID)
}

// GetJob retrieves a job by ID
func (q *Queue) GetJob(ctx context.Context, jobID string) (*DownloadJob, error) {
	data, err := q.client.Get(ctx, keyJobStatus+jobID).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrJobNotFound
		}
		return nil, fmt.Errorf("failed to get job: %w", err)
	}

	var job DownloadJob
	if err := json.Unmarshal([]byte(data), &job); err != nil {
		return nil, fmt.Errorf("failed to unmarshal job: %w", err)
	}

	return &job, nil
}

// UpdateStatus updates the job status and publishes a progress event
func (q *Queue) UpdateStatus(ctx context.Context, jobID, status string, progress int, errMsg string) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}

	job.Status = status
	job.Progress = progress
	job.Error = errMsg
	job.UpdatedAt = time.Now()

	if status == StatusDownloading && job.StartedAt == nil {
		now := time.Now()
		job.StartedAt = &now
	}

	if status == StatusComplete || status == StatusFailed {
		now := time.Now()
		job.CompletedAt = &now
	}

	if err := q.saveJob(ctx, job); err != nil {
		return err
	}

	return q.publishProgress(ctx, job)
}

// UpdateTrackID stores the created local track ID for a completed download job.
func (q *Queue) UpdateTrackID(ctx context.Context, jobID string, trackID int64) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	job.TrackID = &trackID
	job.UpdatedAt = time.Now()
	if err := q.saveJob(ctx, job); err != nil {
		return err
	}
	return q.publishProgress(ctx, job)
}

// IncrementRetry validates retry eligibility, increments retry metadata, and
// requeues the job as a single Redis pipeline so callers do not observe a queued
// job that was never pushed back onto the worker queue.
func (q *Queue) IncrementRetry(ctx context.Context, jobID string) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.Status != StatusFailed {
		return ErrJobNotRetryable
	}

	job.RetryCount++
	job.Status = StatusQueued
	job.Error = ""
	job.UpdatedAt = time.Now()

	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("failed to marshal job: %w", err)
	}

	pipe := q.client.TxPipeline()
	pipe.Set(ctx, keyJobStatus+job.ID, data, 0)
	pipe.LPush(ctx, keyJobQueue, jobID)
	_, err = pipe.Exec(ctx)
	return err
}

// PrepareRetry persists retry metadata before a worker waits for its backoff.
func (q *Queue) PrepareRetry(ctx context.Context, jobID string) (*DownloadJob, error) {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if job.IsTerminal() {
		return nil, ErrJobNotRetryable
	}
	job.RetryCount++
	job.Status = StatusQueued
	job.Progress = 0
	job.Error = ""
	job.UpdatedAt = time.Now()
	if err := q.saveJob(ctx, job); err != nil {
		return nil, err
	}
	if err := q.publishProgress(ctx, job); err != nil {
		return nil, err
	}
	return job, nil
}

// PublishQueuedRetry makes a prepared retry visible to workers without
// duplicating an entry restored by recovery or a prior publish attempt.
func (q *Queue) PublishQueuedRetry(ctx context.Context, jobID string) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.Status != StatusQueued {
		return ErrJobNotRetryable
	}
	_, err = q.client.LPos(ctx, keyJobQueue, jobID, redis.LPosArgs{}).Result()
	if err == nil {
		return nil
	}
	if !errors.Is(err, redis.Nil) {
		return fmt.Errorf("check queued retry: %w", err)
	}
	return q.client.LPush(ctx, keyJobQueue, jobID).Err()
}

// GetUserJobs retrieves all jobs for a specific user
func (q *Queue) GetUserJobs(ctx context.Context, userID string) ([]*DownloadJob, error) {
	pattern := keyJobStatus + "*"
	var jobs []*DownloadJob

	iter := q.client.Scan(ctx, 0, pattern, 100).Iterator()
	for iter.Next(ctx) {
		data, err := q.client.Get(ctx, iter.Val()).Result()
		if err != nil {
			continue
		}

		var job DownloadJob
		if err := json.Unmarshal([]byte(data), &job); err != nil {
			continue
		}

		if job.UserID == userID {
			jobs = append(jobs, &job)
		}
	}

	if err := iter.Err(); err != nil {
		return nil, fmt.Errorf("failed to scan jobs: %w", err)
	}

	return jobs, nil
}

// QueueLength returns the number of jobs waiting in the queue
func (q *Queue) QueueLength(ctx context.Context) (int64, error) {
	return q.client.LLen(ctx, keyJobQueue).Result()
}

// saveJob saves a job to Redis
func (q *Queue) saveJob(ctx context.Context, job *DownloadJob) error {
	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("failed to marshal job: %w", err)
	}

	return q.client.Set(ctx, keyJobStatus+job.ID, data, 0).Err()
}

// publishProgress publishes a progress event via Redis Pub/Sub
func (q *Queue) publishProgress(ctx context.Context, job *DownloadJob) error {
	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("failed to marshal progress event: %w", err)
	}

	channel := fmt.Sprintf("%s:%s", keyProgress, job.UserID)
	return q.client.Publish(ctx, channel, data).Err()
}

// SubscribeProgress subscribes to progress events for a specific user
func (q *Queue) SubscribeProgress(ctx context.Context, userID string) *redis.PubSub {
	channel := fmt.Sprintf("%s:%s", keyProgress, userID)
	return q.client.Subscribe(ctx, channel)
}
