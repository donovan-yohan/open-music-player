package download

import (
	"context"
	"errors"
	"testing"
)

func TestQueue_IncrementRetryRejectsNonFailedJob(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()
	job, err := queue.Enqueue(ctx, "user-retry-not-failed", "https://example.com/not-failed.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	if err := queue.IncrementRetry(ctx, job.ID); !errors.Is(err, ErrJobNotRetryable) {
		t.Fatalf("IncrementRetry for queued job error = %v, want %v", err, ErrJobNotRetryable)
	}

	updatedJob, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to get job: %v", err)
	}
	if updatedJob.RetryCount != 0 {
		t.Fatalf("RetryCount changed to %d for non-retryable job", updatedJob.RetryCount)
	}
	if updatedJob.Status != StatusQueued {
		t.Fatalf("Status changed to %s for non-retryable job", updatedJob.Status)
	}

	// Clean up original enqueue.
	queue.Dequeue(ctx, 0)
}
