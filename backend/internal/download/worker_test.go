package download

import (
	"context"
	"errors"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

func TestWorkerPool_StartStop(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}

	queue, err := NewQueue(redisURL)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	processor := func(ctx context.Context, job *DownloadJob, progress func(int)) error {
		return nil
	}

	pool := NewWorkerPool(queue, processor, &WorkerPoolConfig{
		WorkerCount: 2,
		MaxRetries:  3,
		JobTimeout:  1 * time.Minute,
	})

	if pool.IsRunning() {
		t.Error("Pool should not be running before Start()")
	}

	pool.Start()

	if !pool.IsRunning() {
		t.Error("Pool should be running after Start()")
	}

	// Start again should be idempotent
	pool.Start()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = pool.Stop(ctx)
	if err != nil {
		t.Errorf("Failed to stop pool: %v", err)
	}

	if pool.IsRunning() {
		t.Error("Pool should not be running after Stop()")
	}
}

func TestWorkerPool_ProcessJob(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}

	queue, err := NewQueue(redisURL)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	var processedCount int32

	processor := func(ctx context.Context, job *DownloadJob, progress func(int)) error {
		atomic.AddInt32(&processedCount, 1)
		progress(50)
		progress(100)
		return nil
	}

	pool := NewWorkerPool(queue, processor, &WorkerPoolConfig{
		WorkerCount: 1,
		MaxRetries:  3,
		JobTimeout:  1 * time.Minute,
	})

	ctx := context.Background()

	// Enqueue a job
	job, err := queue.Enqueue(ctx, "test-user", "https://example.com/test.mp3", "test", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	pool.Start()

	// Wait for job to be processed
	time.Sleep(500 * time.Millisecond)

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pool.Stop(stopCtx)

	if atomic.LoadInt32(&processedCount) != 1 {
		t.Errorf("Expected 1 processed job, got %d", processedCount)
	}

	// Verify job status
	updatedJob, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to get job: %v", err)
	}

	if updatedJob.Status != StatusComplete {
		t.Errorf("Expected status %s, got %s", StatusComplete, updatedJob.Status)
	}
}

func TestWorkerPool_RetryOnFailure(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}

	queue, err := NewQueue(redisURL)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	var attemptCount int32

	processor := func(ctx context.Context, job *DownloadJob, progress func(int)) error {
		count := atomic.AddInt32(&attemptCount, 1)
		if count < 3 {
			return errors.New("simulated failure")
		}
		return nil
	}

	pool := NewWorkerPool(queue, processor, &WorkerPoolConfig{
		WorkerCount: 1,
		MaxRetries:  3,
		JobTimeout:  1 * time.Minute,
	})

	ctx := context.Background()

	// Enqueue a job
	_, err = queue.Enqueue(ctx, "retry-user", "https://example.com/retry.mp3", "test", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	pool.Start()

	// Wait for retries to complete (with backoff)
	time.Sleep(8 * time.Second)

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pool.Stop(stopCtx)

	attempts := atomic.LoadInt32(&attemptCount)
	if attempts < 3 {
		t.Errorf("Expected at least 3 attempts, got %d", attempts)
	}
}

func TestCalculateBackoff(t *testing.T) {
	tests := []struct {
		retryCount int
		minBackoff time.Duration
		maxBackoff time.Duration
	}{
		{0, 1 * time.Second, 1 * time.Second},
		{1, 2 * time.Second, 2 * time.Second},
		{2, 4 * time.Second, 4 * time.Second},
		{3, 8 * time.Second, 8 * time.Second},
		{10, 5 * time.Minute, 5 * time.Minute}, // Capped at maxBackoff
	}

	for _, tt := range tests {
		got := calculateBackoff(tt.retryCount)
		if got < tt.minBackoff || got > tt.maxBackoff {
			t.Errorf("calculateBackoff(%d) = %v, want between %v and %v",
				tt.retryCount, got, tt.minBackoff, tt.maxBackoff)
		}
	}
}
