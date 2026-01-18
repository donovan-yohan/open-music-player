package download

import (
	"context"
	"errors"
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

	// Exponential backoff parameters
	baseBackoff = 1 * time.Second
	maxBackoff  = 5 * time.Minute
)

// JobProcessor is the function signature for processing a download job
type JobProcessor func(ctx context.Context, job *DownloadJob, progress func(int)) error

// WorkerPool manages a pool of workers that process download jobs
type WorkerPool struct {
	queue       *Queue
	workerCount int
	maxRetries  int
	jobTimeout  time.Duration
	processor   JobProcessor

	wg       sync.WaitGroup
	stopChan chan struct{}
	mu       sync.RWMutex
	running  bool
}

// WorkerPoolConfig holds configuration for the worker pool
type WorkerPoolConfig struct {
	WorkerCount int
	MaxRetries  int
	JobTimeout  time.Duration
}

// NewWorkerPool creates a new worker pool
func NewWorkerPool(queue *Queue, processor JobProcessor, config *WorkerPoolConfig) *WorkerPool {
	if config == nil {
		config = &WorkerPoolConfig{}
	}

	workerCount := config.WorkerCount
	if workerCount <= 0 {
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

	return &WorkerPool{
		queue:       queue,
		workerCount: workerCount,
		maxRetries:  maxRetries,
		jobTimeout:  jobTimeout,
		processor:   processor,
		stopChan:    make(chan struct{}),
	}
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

	for i := 0; i < wp.workerCount; i++ {
		wp.wg.Add(1)
		go wp.worker(i)
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
func (wp *WorkerPool) worker(id int) {
	defer wp.wg.Done()

	log.Printf("Worker %d started", id)

	for {
		select {
		case <-wp.stopChan:
			log.Printf("Worker %d stopping", id)
			return
		default:
			wp.processNextJob(id)
		}
	}
}

// processNextJob dequeues and processes the next available job
func (wp *WorkerPool) processNextJob(workerID int) {
	ctx := context.Background()

	job, err := wp.queue.Dequeue(ctx, 5*time.Second)
	if err != nil {
		if errors.Is(err, ErrQueueEmpty) {
			return
		}
		log.Printf("Worker %d: failed to dequeue job: %v", workerID, err)
		return
	}

	log.Printf("Worker %d: processing job %s", workerID, job.ID)
	wp.processJob(ctx, workerID, job)
}

// processJob handles the full lifecycle of a single job
func (wp *WorkerPool) processJob(ctx context.Context, workerID int, job *DownloadJob) {
	jobCtx, cancel := context.WithTimeout(ctx, wp.jobTimeout)
	defer cancel()

	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusDownloading, 0, ""); err != nil {
		log.Printf("Worker %d: failed to update job status to downloading: %v", workerID, err)
		return
	}

	progressFn := func(progress int) {
		if err := wp.queue.UpdateStatus(ctx, job.ID, job.Status, progress, ""); err != nil {
			log.Printf("Worker %d: failed to update progress: %v", workerID, err)
		}
	}

	err := wp.processor(jobCtx, job, progressFn)

	if err != nil {
		wp.handleJobFailure(ctx, workerID, job, err)
		return
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

	if err := wp.queue.UpdateStatus(ctx, job.ID, StatusFailed, job.Progress, errMsg); err != nil {
		log.Printf("Worker %d: failed to update job status to failed: %v", workerID, err)
		return
	}

	updatedJob, err := wp.queue.GetJob(ctx, job.ID)
	if err != nil {
		log.Printf("Worker %d: failed to get updated job: %v", workerID, err)
		return
	}

	if updatedJob.CanRetry(wp.maxRetries) {
		backoff := calculateBackoff(updatedJob.RetryCount)
		log.Printf("Worker %d: scheduling retry for job %s in %v (attempt %d/%d)",
			workerID, job.ID, backoff, updatedJob.RetryCount+1, wp.maxRetries)

		time.Sleep(backoff)

		if err := wp.queue.IncrementRetry(ctx, job.ID); err != nil {
			log.Printf("Worker %d: failed to requeue job for retry: %v", workerID, err)
		}
	} else {
		log.Printf("Worker %d: job %s exceeded max retries (%d)", workerID, job.ID, wp.maxRetries)
	}
}

// calculateBackoff calculates the exponential backoff duration for a given retry count
func calculateBackoff(retryCount int) time.Duration {
	backoff := time.Duration(math.Pow(2, float64(retryCount))) * baseBackoff
	if backoff > maxBackoff {
		backoff = maxBackoff
	}
	return backoff
}
