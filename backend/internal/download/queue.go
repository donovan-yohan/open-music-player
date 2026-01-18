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
	ErrJobNotFound = errors.New("job not found")
	ErrQueueEmpty  = errors.New("queue is empty")
)

// Queue manages download jobs using Redis
type Queue struct {
	client *redis.Client
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
	now := time.Now()
	job := &DownloadJob{
		ID:            uuid.New().String(),
		UserID:        userID,
		URL:           url,
		SourceType:    sourceType,
		Status:        StatusQueued,
		Progress:      0,
		RetryCount:    0,
		MBRecordingID: mbRecordingID,
		CreatedAt:     now,
		UpdatedAt:     now,
	}

	if err := q.saveJob(ctx, job); err != nil {
		return nil, err
	}

	if err := q.client.LPush(ctx, keyJobQueue, job.ID).Err(); err != nil {
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

// IncrementRetry increments the retry count and requeues the job
func (q *Queue) IncrementRetry(ctx context.Context, jobID string) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}

	job.RetryCount++
	job.Status = StatusQueued
	job.Error = ""
	job.UpdatedAt = time.Now()

	if err := q.saveJob(ctx, job); err != nil {
		return err
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
