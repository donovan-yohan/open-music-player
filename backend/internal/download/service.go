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
}

// ServiceConfig holds configuration for the download service
type ServiceConfig struct {
	RedisURL    string
	WorkerCount int
	MaxRetries  int
	JobTimeout  time.Duration
}

// NewService creates a new download service
func NewService(config *ServiceConfig, processor JobProcessor) (*Service, error) {
	queue, err := NewQueue(config.RedisURL)
	if err != nil {
		return nil, err
	}

	workerPool := NewWorkerPool(queue, processor, &WorkerPoolConfig{
		WorkerCount: config.WorkerCount,
		MaxRetries:  config.MaxRetries,
		JobTimeout:  config.JobTimeout,
	})

	return &Service{
		queue:      queue,
		workerPool: workerPool,
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

// GetJob retrieves a job by ID
func (s *Service) GetJob(ctx context.Context, jobID string) (*DownloadJob, error) {
	return s.queue.GetJob(ctx, jobID)
}

// GetUserJobs retrieves all jobs for a user
func (s *Service) GetUserJobs(ctx context.Context, userID string) ([]*DownloadJob, error) {
	return s.queue.GetUserJobs(ctx, userID)
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
