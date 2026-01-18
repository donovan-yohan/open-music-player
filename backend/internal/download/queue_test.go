package download

import (
	"context"
	"os"
	"testing"
	"time"
)

func getTestRedisURL() string {
	url := os.Getenv("REDIS_URL")
	if url == "" {
		url = "redis://localhost:6380"
	}
	return url
}

func TestQueue_EnqueueDequeue(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()

	// Enqueue a job
	job, err := queue.Enqueue(ctx, "user-123", "https://example.com/track.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	if job.ID == "" {
		t.Error("Job ID should not be empty")
	}
	if job.Status != StatusQueued {
		t.Errorf("Expected status %s, got %s", StatusQueued, job.Status)
	}
	if job.UserID != "user-123" {
		t.Errorf("Expected user ID user-123, got %s", job.UserID)
	}

	// Dequeue the job
	dequeuedJob, err := queue.Dequeue(ctx, 1*time.Second)
	if err != nil {
		t.Fatalf("Failed to dequeue job: %v", err)
	}

	if dequeuedJob.ID != job.ID {
		t.Errorf("Expected job ID %s, got %s", job.ID, dequeuedJob.ID)
	}
}

func TestQueue_GetJob(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()

	// Enqueue a job
	job, err := queue.Enqueue(ctx, "user-456", "https://example.com/track2.mp3", "soundcloud", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	// Get the job by ID
	retrievedJob, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to get job: %v", err)
	}

	if retrievedJob.URL != job.URL {
		t.Errorf("Expected URL %s, got %s", job.URL, retrievedJob.URL)
	}

	// Clean up
	queue.Dequeue(ctx, 1*time.Second)
}

func TestQueue_UpdateStatus(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()

	// Enqueue a job
	job, err := queue.Enqueue(ctx, "user-789", "https://example.com/track3.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	// Update status to downloading
	err = queue.UpdateStatus(ctx, job.ID, StatusDownloading, 25, "")
	if err != nil {
		t.Fatalf("Failed to update status: %v", err)
	}

	// Verify the update
	updatedJob, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to get job: %v", err)
	}

	if updatedJob.Status != StatusDownloading {
		t.Errorf("Expected status %s, got %s", StatusDownloading, updatedJob.Status)
	}
	if updatedJob.Progress != 25 {
		t.Errorf("Expected progress 25, got %d", updatedJob.Progress)
	}
	if updatedJob.StartedAt == nil {
		t.Error("StartedAt should be set when status changes to downloading")
	}

	// Clean up
	queue.Dequeue(ctx, 1*time.Second)
}

func TestQueue_IncrementRetry(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()

	// Enqueue a job
	job, err := queue.Enqueue(ctx, "user-retry", "https://example.com/retry.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	// Dequeue it first
	_, err = queue.Dequeue(ctx, 1*time.Second)
	if err != nil {
		t.Fatalf("Failed to dequeue job: %v", err)
	}

	// Mark as failed
	err = queue.UpdateStatus(ctx, job.ID, StatusFailed, 0, "test error")
	if err != nil {
		t.Fatalf("Failed to update status: %v", err)
	}

	// Increment retry
	err = queue.IncrementRetry(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to increment retry: %v", err)
	}

	// Verify retry count
	updatedJob, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("Failed to get job: %v", err)
	}

	if updatedJob.RetryCount != 1 {
		t.Errorf("Expected retry count 1, got %d", updatedJob.RetryCount)
	}
	if updatedJob.Status != StatusQueued {
		t.Errorf("Expected status %s, got %s", StatusQueued, updatedJob.Status)
	}

	// Clean up
	queue.Dequeue(ctx, 1*time.Second)
}

func TestQueue_QueueLength(t *testing.T) {
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queue.Close()

	ctx := context.Background()

	// Get initial length
	initialLen, err := queue.QueueLength(ctx)
	if err != nil {
		t.Fatalf("Failed to get queue length: %v", err)
	}

	// Enqueue jobs
	_, err = queue.Enqueue(ctx, "user-len1", "https://example.com/len1.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}
	_, err = queue.Enqueue(ctx, "user-len2", "https://example.com/len2.mp3", "youtube", nil)
	if err != nil {
		t.Fatalf("Failed to enqueue job: %v", err)
	}

	// Verify length increased
	newLen, err := queue.QueueLength(ctx)
	if err != nil {
		t.Fatalf("Failed to get queue length: %v", err)
	}

	if newLen != initialLen+2 {
		t.Errorf("Expected queue length %d, got %d", initialLen+2, newLen)
	}

	// Clean up
	queue.Dequeue(ctx, 1*time.Second)
	queue.Dequeue(ctx, 1*time.Second)
}

func TestDownloadJob_IsTerminal(t *testing.T) {
	tests := []struct {
		status   string
		expected bool
	}{
		{StatusQueued, false},
		{StatusDownloading, false},
		{StatusProcessing, false},
		{StatusUploading, false},
		{StatusComplete, true},
		{StatusFailed, true},
	}

	for _, tt := range tests {
		job := &DownloadJob{Status: tt.status}
		if got := job.IsTerminal(); got != tt.expected {
			t.Errorf("IsTerminal() for status %s = %v, want %v", tt.status, got, tt.expected)
		}
	}
}

func TestDownloadJob_CanRetry(t *testing.T) {
	maxRetries := 3

	tests := []struct {
		status     string
		retryCount int
		expected   bool
	}{
		{StatusFailed, 0, true},
		{StatusFailed, 1, true},
		{StatusFailed, 2, true},
		{StatusFailed, 3, false},
		{StatusFailed, 4, false},
		{StatusComplete, 0, false},
		{StatusQueued, 0, false},
	}

	for _, tt := range tests {
		job := &DownloadJob{Status: tt.status, RetryCount: tt.retryCount}
		if got := job.CanRetry(maxRetries); got != tt.expected {
			t.Errorf("CanRetry(%d) for status=%s, retryCount=%d = %v, want %v",
				maxRetries, tt.status, tt.retryCount, got, tt.expected)
		}
	}
}
