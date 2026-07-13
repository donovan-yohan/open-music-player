package download

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"sync"
	"time"
)

const (
	// Default configuration values
	DefaultWorkerCount = 3
	DefaultMaxRetries  = 3
	DefaultJobTimeout  = 10 * time.Minute

	// Worker dequeue timeout is kept short so Stop is not held behind a
	// Redis blocking pop when the queue is idle.
	workerDequeueTimeout = 1 * time.Second

	// Exponential backoff parameters
	baseBackoff = 1 * time.Second
	maxBackoff  = 5 * time.Minute
)

// JobProcessor is the function signature for processing a download job
type JobProcessor func(ctx context.Context, job *DownloadJob, progress func(int)) error

// JobLifecycle mirrors source-decision jobs into durable storage. Implementations
// must treat jobs without a source-selection decision as a no-op so legacy
// direct-download and playlist-import jobs keep their existing lifecycle.
type JobLifecycle interface {
	Sync(context.Context, *DownloadJob) error
	Complete(context.Context, *DownloadJob) error
	Fail(context.Context, *DownloadJob, error) error
	Requeue(context.Context, *DownloadJob, int) error
}

// WorkerPool manages a pool of workers that process download jobs
type WorkerPool struct {
	queue        *Queue
	workerCount  int
	maxRetries   int
	jobTimeout   time.Duration
	processor    JobProcessor
	lifecycle    JobLifecycle
	prepareRetry func(context.Context, string) (*DownloadJob, error)

	wg         sync.WaitGroup
	stopChan   chan struct{}
	stopCancel context.CancelFunc
	mu         sync.RWMutex
	running    bool
}

// WorkerPoolConfig holds configuration for the worker pool
type WorkerPoolConfig struct {
	WorkerCount *int
	MaxRetries  int
	JobTimeout  time.Duration
	Lifecycle   JobLifecycle
}

// NewWorkerPool creates a new worker pool
func NewWorkerPool(queue *Queue, processor JobProcessor, config *WorkerPoolConfig) *WorkerPool {
	if config == nil {
		config = &WorkerPoolConfig{}
	}

	workerCount := DefaultWorkerCount
	if config.WorkerCount != nil {
		workerCount = *config.WorkerCount
	}
	if workerCount < 0 {
		workerCount = DefaultWorkerCount
	}

	maxRetries := config.MaxRetries
	if maxRetries <= 0 {
		maxRetries = DefaultMaxRetries
	}

	jobTimeout := config.JobTimeout
	if jobTimeout <= 0 {
		jobTimeout = DefaultJobTimeout
	}

	pool := &WorkerPool{
		queue:       queue,
		workerCount: workerCount,
		maxRetries:  maxRetries,
		jobTimeout:  jobTimeout,
		processor:   processor,
		lifecycle:   config.Lifecycle,
		stopChan:    make(chan struct{}),
	}
	if queue != nil {
		pool.prepareRetry = queue.PrepareRetry
	}
	return pool
}

// Start launches the worker pool
func (wp *WorkerPool) Start() {
	wp.mu.Lock()
	defer wp.mu.Unlock()

	if wp.running {
		return
	}

	wp.running = true
	wp.stopChan = make(chan struct{})
	stopCtx, stopCancel := context.WithCancel(context.Background())
	wp.stopCancel = stopCancel

	for i := 0; i < wp.workerCount; i++ {
		wp.wg.Add(1)
		go wp.worker(stopCtx, i)
	}

	log.Printf("Worker pool started with %d workers", wp.workerCount)
}

// Stop gracefully stops the worker pool, waiting for current jobs to complete
func (wp *WorkerPool) Stop(ctx context.Context) error {
	wp.mu.Lock()
	if !wp.running {
		wp.mu.Unlock()
		return nil
	}
	wp.running = false
	if wp.stopCancel != nil {
		wp.stopCancel()
	}
	close(wp.stopChan)
	wp.mu.Unlock()

	done := make(chan struct{})
	go func() {
		wp.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Println("Worker pool stopped gracefully")
		return nil
	case <-ctx.Done():
		log.Println("Worker pool shutdown timed out")
		return ctx.Err()
	}
}

// IsRunning returns whether the worker pool is currently running
func (wp *WorkerPool) IsRunning() bool {
	wp.mu.RLock()
	defer wp.mu.RUnlock()
	return wp.running
}

// worker is the main loop for a single worker
func (wp *WorkerPool) worker(stopCtx context.Context, id int) {
	defer wp.wg.Done()

	log.Printf("Worker %d started", id)

	for {
		select {
		case <-stopCtx.Done():
			log.Printf("Worker %d stopping", id)
			return
		case <-wp.stopChan:
			log.Printf("Worker %d stopping", id)
			return
		default:
			wp.processNextJob(stopCtx, id)
		}
	}
}

// processNextJob dequeues and processes the next available job
func (wp *WorkerPool) processNextJob(dequeueCtx context.Context, workerID int) {
	job, err := wp.queue.Dequeue(dequeueCtx, workerDequeueTimeout)
	if err != nil {
		if errors.Is(err, ErrQueueEmpty) || errors.Is(err, context.Canceled) {
			return
		}
		log.Printf("Worker %d: failed to dequeue job: %v", workerID, err)
		return
	}

	log.Printf("Worker %d: processing job %s", workerID, job.ID)
	wp.processJob(context.Background(), workerID, job)
}

// processJob handles the full lifecycle of a single job
func (wp *WorkerPool) processJob(ctx context.Context, workerID int, job *DownloadJob) {
	jobCtx, cancel := context.WithTimeout(ctx, wp.jobTimeout)
	defer cancel()

	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusDownloading, 0, ""); err != nil {
		log.Printf("Worker %d: failed to update job status to downloading: %v", workerID, err)
		return
	}
	job.Status = StatusDownloading
	job.Progress = 0
	job.Error = ""
	if wp.lifecycle != nil {
		if err := wp.lifecycle.Sync(ctx, job); err != nil {
			wp.handleJobFailure(ctx, workerID, job, err)
			return
		}
	}

	progressFn := func(progress int) {
		job.Progress = progress
		if err := wp.queue.UpdateStatus(ctx, job.ID, job.Status, progress, ""); err != nil {
			log.Printf("Worker %d: failed to update progress: %v", workerID, err)
		}
		if wp.lifecycle != nil {
			if err := wp.lifecycle.Sync(ctx, job); err != nil {
				log.Printf("Worker %d: failed to mirror progress for job %s: %v", workerID, job.ID, err)
			}
		}
	}

	err := wp.processor(jobCtx, job, progressFn)

	if err != nil {
		wp.handleJobFailure(ctx, workerID, job, err)
		return
	}

	if wp.lifecycle != nil {
		// The SQL adapter attaches the track to its decision in the same
		// transaction that marks durable completion. Do this before Redis
		// publishes completion so a visible complete state is never ahead.
		if err := wp.lifecycle.Complete(ctx, job); err != nil {
			wp.handleJobFailure(ctx, workerID, job, err)
			return
		}
	}

	if job.TrackID != nil {
		if err := wp.queue.UpdateTrackID(ctx, job.ID, *job.TrackID); err != nil {
			log.Printf("Worker %d: failed to store track id for job %s: %v", workerID, job.ID, err)
		}
	}

	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusComplete, 100, ""); err != nil {
		log.Printf("Worker %d: failed to update job status to complete: %v", workerID, err)
	}

	log.Printf("Worker %d: job %s completed successfully", workerID, job.ID)
}

// handleJobFailure handles a failed job, implementing retry logic with exponential backoff
func (wp *WorkerPool) handleJobFailure(ctx context.Context, workerID int, job *DownloadJob, jobErr error) {
	errMsg := jobErr.Error()
	log.Printf("Worker %d: job %s failed: %v", workerID, job.ID, jobErr)
	if isRetryable(jobErr) && job.RetryCount < wp.maxRetries {
		retrying := *job
		retrying.Status = StatusQueued
		retrying.Progress = 0
		retrying.Error = ""
		retrying.RetryCount++
		if wp.lifecycle != nil {
			if err := wp.lifecycle.Requeue(ctx, &retrying, retrying.RetryCount); err != nil {
				log.Printf("Worker %d: failed to persist retry for job %s: %v", workerID, job.ID, err)
				wp.failRetryPreparation(ctx, workerID, job, fmt.Errorf("persist retry: %w", err))
				return
			}
		}
		prepared, err := wp.prepareRetry(ctx, job.ID)
		if err != nil {
			log.Printf("Worker %d: failed to prepare retry for job %s: %v", workerID, job.ID, err)
			wp.failRetryPreparation(ctx, workerID, job, fmt.Errorf("prepare retry: %w", err))
			return
		}
		backoff := calculateBackoff(prepared.RetryCount - 1)
		log.Printf("Worker %d: scheduling retry for job %s in %v (attempt %d/%d)",
			workerID, job.ID, backoff, prepared.RetryCount, wp.maxRetries)

		time.Sleep(backoff)
		if err := wp.queue.PublishQueuedRetry(ctx, job.ID); err != nil {
			log.Printf("Worker %d: failed to requeue job for retry: %v", workerID, err)
		}
		return
	}

	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusFailed, job.Progress, errMsg); err != nil {
		log.Printf("Worker %d: failed to update job status to failed: %v", workerID, err)
		return
	}
	job.Status = StatusFailed
	job.Error = errMsg
	if wp.lifecycle != nil {
		if err := wp.lifecycle.Fail(ctx, job, jobErr); err != nil {
			log.Printf("Worker %d: failed to mirror job failure for %s: %v", workerID, job.ID, err)
		}
	}
}

// failRetryPreparation reconciles retry setup failures to a terminal state. A
// durable requeue may have completed before Redis preparation fails, so both
// stores are explicitly failed rather than leaving an invisible downloading job.
func (wp *WorkerPool) failRetryPreparation(ctx context.Context, workerID int, job *DownloadJob, cause error) {
	failure := fmt.Errorf("retry preparation failed: %w", cause)
	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusFailed, job.Progress, failure.Error()); err != nil {
		log.Printf("Worker %d: failed to mark retry preparation failure for job %s in Redis: %v", workerID, job.ID, err)
	}
	failed := *job
	failed.Status = StatusFailed
	failed.Error = failure.Error()
	if wp.lifecycle != nil {
		if err := wp.lifecycle.Fail(ctx, &failed, failure); err != nil {
			log.Printf("Worker %d: failed to mark retry preparation failure for job %s durable: %v", workerID, job.ID, err)
		}
	}
}

type retryableError interface{ Retryable() bool }

func isRetryable(err error) bool {
	var classified retryableError
	return !errors.As(err, &classified) || classified.Retryable()
}

// calculateBackoff calculates the exponential backoff duration for a given retry count
func calculateBackoff(retryCount int) time.Duration {
	backoff := time.Duration(math.Pow(2, float64(retryCount))) * baseBackoff
	if backoff > maxBackoff {
		backoff = maxBackoff
	}
	return backoff
}
