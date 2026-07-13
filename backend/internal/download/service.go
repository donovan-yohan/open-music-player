package download

import (
	"context"
	"log"
	"time"
)

// Service provides download job management functionality
type Service struct {
	queue      *Queue
	workerPool *WorkerPool
	lifecycle  JobLifecycle
	maxRetries int
}

// ServiceConfig holds configuration for the download service
type ServiceConfig struct {
	RedisURL    string
	WorkerCount int
	MaxRetries  int
	JobTimeout  time.Duration
}

// NewService creates a new download service
func NewService(config *ServiceConfig, processor JobProcessor, lifecycle ...JobLifecycle) (*Service, error) {
	queue, err := NewQueue(config.RedisURL)
	if err != nil {
		return nil, err
	}

	workerCount := config.WorkerCount
	maxRetries := config.MaxRetries
	if maxRetries <= 0 {
		maxRetries = DefaultMaxRetries
	}
	workerConfig := &WorkerPoolConfig{
		WorkerCount: &workerCount,
		MaxRetries:  maxRetries,
		JobTimeout:  config.JobTimeout,
	}
	if len(lifecycle) > 0 {
		workerConfig.Lifecycle = lifecycle[0]
	}
	workerPool := NewWorkerPool(queue, processor, workerConfig)

	return &Service{
		queue:      queue,
		workerPool: workerPool,
		lifecycle:  workerConfig.Lifecycle,
		maxRetries: maxRetries,
	}, nil
}

// Start starts the worker pool
func (s *Service) Start() {
	s.workerPool.Start()
}

// Stop gracefully stops the service
func (s *Service) Stop(ctx context.Context) error {
	if err := s.workerPool.Stop(ctx); err != nil {
		log.Printf("Worker pool stop error: %v", err)
	}
	return s.queue.Close()
}

// Queue returns the underlying job queue
func (s *Service) Queue() *Queue {
	return s.queue
}

// EnqueueDownload adds a new download job to the queue
func (s *Service) EnqueueDownload(ctx context.Context, userID, url, sourceType string, mbRecordingID *string) (*DownloadJob, error) {
	return s.queue.Enqueue(ctx, userID, url, sourceType, mbRecordingID)
}

// EnqueueSourceCandidate queues a normalized discovery candidate for download.
func (s *Service) EnqueueSourceCandidate(ctx context.Context, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	return s.queue.EnqueueCandidate(ctx, userID, candidate, mbRecordingID)
}

// EnqueueSourceCandidateWithID queues a normalized discovery candidate using a
// job ID already persisted in the playback queue item.
func (s *Service) EnqueueSourceCandidateWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	return s.queue.EnqueueCandidateWithID(ctx, jobID, userID, candidate, mbRecordingID)
}

// EnsureSourceCandidateWithID leaves an existing non-terminal Redis job alone.
// Startup recovery uses this to remain idempotent when a previous boot already
// restored the durable job.
func (s *Service) EnsureSourceCandidateWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, mbRecordingID *string) (*DownloadJob, error) {
	return s.queue.EnsureCandidateWithID(ctx, jobID, userID, candidate, mbRecordingID)
}

func (s *Service) EnqueuePlaylistImportItem(ctx context.Context, userID string, candidate SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	return s.queue.EnqueuePlaylistImportItem(ctx, userID, candidate, importJobID, importItemID, playlistID, playlistPosition)
}

func (s *Service) EnqueuePlaylistImportItemWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	return s.queue.EnqueuePlaylistImportItemWithID(ctx, jobID, userID, candidate, importJobID, importItemID, playlistID, playlistPosition)
}

func (s *Service) EnsurePlaylistImportItemWithID(ctx context.Context, jobID, userID string, candidate SourceCandidate, importJobID string, importItemID, playlistID int64, playlistPosition int) (*DownloadJob, error) {
	return s.queue.EnsurePlaylistImportItemWithID(ctx, jobID, userID, candidate, importJobID, importItemID, playlistID, playlistPosition)
}

// GetJob retrieves a job by ID
func (s *Service) GetJob(ctx context.Context, jobID string) (*DownloadJob, error) {
	return s.queue.GetJob(ctx, jobID)
}

// GetUserJobs retrieves all jobs for a user
func (s *Service) GetUserJobs(ctx context.Context, userID string) ([]*DownloadJob, error) {
	return s.queue.GetUserJobs(ctx, userID)
}

// RetryJob increments retry metadata and places a failed job back on the queue.
func (s *Service) RetryJob(ctx context.Context, jobID string) error {
	job, err := s.queue.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if !job.CanRetry(s.maxRetries) {
		return ErrJobNotRetryable
	}
	if s.lifecycle != nil {
		retrying := *job
		retrying.Status = StatusQueued
		retrying.Progress = 0
		retrying.Error = ""
		retrying.RetryCount++
		if err := s.lifecycle.Requeue(ctx, &retrying, retrying.RetryCount); err != nil {
			return err
		}
	}
	return s.queue.IncrementRetry(ctx, jobID)
}

// GetQueueLength returns the number of pending jobs
func (s *Service) GetQueueLength(ctx context.Context) (int64, error) {
	return s.queue.QueueLength(ctx)
}

// UpdateJobProgress updates the progress of a job
func (s *Service) UpdateJobProgress(ctx context.Context, jobID string, status string, progress int) error {
	return s.queue.UpdateStatus(ctx, jobID, status, progress, "")
}

// SubscribeToUserProgress returns a subscription for user-specific progress events
func (s *Service) SubscribeToUserProgress(ctx context.Context, userID string) *ProgressSubscription {
	pubsub := s.queue.SubscribeProgress(ctx, userID)
	return &ProgressSubscription{
		pubsub: pubsub,
		ch:     pubsub.Channel(),
	}
}

// IsRunning returns whether the worker pool is running
func (s *Service) IsRunning() bool {
	return s.workerPool.IsRunning()
}
