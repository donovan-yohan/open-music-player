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
		url = "redis://localhost:6380/15"
	}
	return url
}

func newTestQueue(t *testing.T) *Queue {
	t.Helper()
	queue, err := NewQueue(getTestRedisURL())
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	ctx := context.Background()
	if err := queue.client.FlushDB(ctx).Err(); err != nil {
		_ = queue.Close()
		t.Fatalf("failed to clear test Redis DB: %v", err)
	}
	t.Cleanup(func() {
		_ = queue.client.FlushDB(context.Background()).Err()
		_ = queue.Close()
	})
	return queue
}

func TestQueue_EnqueueDequeue(t *testing.T) {
	queue := newTestQueue(t)

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
	queue := newTestQueue(t)

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

func TestQueue_EnsureCandidateWithIDRestoresDequeuedJobWithoutDuplicates(t *testing.T) {
	queue := newTestQueue(t)
	ctx := context.Background()
	candidate := SourceCandidate{CandidateID: "youtube:test", Provider: "youtube", SourceID: "test", SourceURL: "https://example.com/test", Title: "Test"}

	job, err := queue.EnqueueCandidateWithID(ctx, "00000000-0000-4000-8000-000000000001", "user-ensure", candidate, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := queue.Dequeue(ctx, time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := queue.EnsureCandidateWithID(ctx, job.ID, job.UserID, candidate, nil); err != nil {
		t.Fatal(err)
	}
	if length, err := queue.QueueLength(ctx); err != nil || length != 1 {
		t.Fatalf("restored queue length = %d, %v; want 1, nil", length, err)
	}
	if _, err := queue.EnsureCandidateWithID(ctx, job.ID, job.UserID, candidate, nil); err != nil {
		t.Fatal(err)
	}
	if length, err := queue.QueueLength(ctx); err != nil || length != 1 {
		t.Fatalf("idempotent queue length = %d, %v; want 1, nil", length, err)
	}
}

func TestQueue_EnsureWithIDReturnsTerminalJobsUnchanged(t *testing.T) {
	ctx := context.Background()
	candidate := SourceCandidate{CandidateID: "youtube:new", Provider: "youtube", SourceID: "new", SourceURL: "https://example.com/new", Title: "New"}
	for _, status := range []string{StatusComplete, StatusFailed} {
		t.Run(status, func(t *testing.T) {
			queue := newTestQueue(t)
			job, err := queue.EnqueueCandidateWithID(ctx, "00000000-0000-4000-8000-00000000000"+map[string]string{StatusComplete: "2", StatusFailed: "3"}[status], "user-terminal", SourceCandidate{CandidateID: "youtube:original", Provider: "youtube", SourceID: "original", SourceURL: "https://example.com/original", Title: "Original"}, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := queue.Dequeue(ctx, time.Second); err != nil {
				t.Fatal(err)
			}
			if err := queue.UpdateStatus(ctx, job.ID, status, 100, "terminal"); err != nil {
				t.Fatal(err)
			}
			got, err := queue.EnsureCandidateWithID(ctx, job.ID, job.UserID, candidate, nil)
			if err != nil || got.Status != status || got.CandidateID != "youtube:original" {
				t.Fatalf("candidate ensure = %#v, %v", got, err)
			}
			if length, err := queue.QueueLength(ctx); err != nil || length != 0 {
				t.Fatalf("terminal queue length = %d, %v", length, err)
			}
		})
	}
}

func TestQueue_EnsurePlaylistImportItemWithIDReturnsTerminalJobUnchanged(t *testing.T) {
	queue := newTestQueue(t)
	ctx := context.Background()
	job, err := queue.EnqueuePlaylistImportItemWithID(ctx, "00000000-0000-4000-8000-000000000004", "user-terminal", SourceCandidate{CandidateID: "youtube:original", Provider: "youtube", SourceID: "original", SourceURL: "https://example.com/original", Title: "Original"}, "import", 1, 2, 3)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := queue.Dequeue(ctx, time.Second); err != nil {
		t.Fatal(err)
	}
	if err := queue.UpdateStatus(ctx, job.ID, StatusComplete, 100, ""); err != nil {
		t.Fatal(err)
	}
	got, err := queue.EnsurePlaylistImportItemWithID(ctx, job.ID, job.UserID, SourceCandidate{CandidateID: "youtube:new", Provider: "youtube", SourceID: "new", SourceURL: "https://example.com/new", Title: "New"}, "other", 9, 8, 7)
	if err != nil || got.Status != StatusComplete || got.PlaylistImportItemID != 1 || got.CandidateID != "youtube:original" {
		t.Fatalf("playlist ensure = %#v, %v", got, err)
	}
	if length, err := queue.QueueLength(ctx); err != nil || length != 0 {
		t.Fatalf("terminal queue length = %d, %v", length, err)
	}
}

func TestQueue_UpdateStatus(t *testing.T) {
	queue := newTestQueue(t)

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
	queue := newTestQueue(t)

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
	queue := newTestQueue(t)

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
