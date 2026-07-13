package download

import (
	"context"
	"errors"
	"sync"
	"testing"
)

type recordingJobLifecycle struct {
	mu    sync.Mutex
	calls []string
}

func (l *recordingJobLifecycle) Sync(_ context.Context, job *DownloadJob) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, "sync:"+job.Status)
	return nil
}

func (l *recordingJobLifecycle) Complete(_ context.Context, _ *DownloadJob) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, "complete")
	return nil
}

func (l *recordingJobLifecycle) Fail(_ context.Context, _ *DownloadJob, _ error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, "failed")
	return nil
}

func (l *recordingJobLifecycle) Requeue(_ context.Context, _ *DownloadJob, _ int) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, "requeue")
	return nil
}

func (l *recordingJobLifecycle) snapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.calls...)
}

func TestWorkerPoolMirrorsLifecycleBeforeRedisCompletion(t *testing.T) {
	queue := newTestQueue(t)
	lifecycle := &recordingJobLifecycle{}
	trackID := int64(42)
	processor := func(_ context.Context, job *DownloadJob, progress func(int)) error {
		progress(20)
		job.Status = StatusProcessing
		progress(75)
		job.TrackID = &trackID
		return nil
	}
	pool := NewWorkerPool(queue, processor, &WorkerPoolConfig{WorkerCount: workerCountPtr(0), Lifecycle: lifecycle})
	job, err := queue.Enqueue(context.Background(), "test-user", "https://example.test/audio", "youtube", nil)
	if err != nil {
		t.Fatal(err)
	}

	pool.processJob(context.Background(), 0, job)

	if got, want := lifecycle.snapshot(), []string{"sync:downloading", "sync:downloading", "sync:processing", "complete"}; !sameStrings(got, want) {
		t.Fatalf("lifecycle calls = %#v, want %#v", got, want)
	}
	updated, err := queue.GetJob(context.Background(), job.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Status != StatusComplete || updated.TrackID == nil || *updated.TrackID != trackID {
		t.Fatalf("redis job after lifecycle completion = %#v", updated)
	}
}

func TestWorkerPoolMirrorsFailureForJobsWithoutTrack(t *testing.T) {
	queue := newTestQueue(t)
	lifecycle := &recordingJobLifecycle{}
	pool := NewWorkerPool(queue, func(context.Context, *DownloadJob, func(int)) error {
		return errors.New("download exploded")
	}, &WorkerPoolConfig{WorkerCount: workerCountPtr(0), MaxRetries: 1, Lifecycle: lifecycle})
	job, err := queue.Enqueue(context.Background(), "test-user", "https://example.test/audio", "youtube", nil)
	if err != nil {
		t.Fatal(err)
	}
	job.RetryCount = 1 // Avoid sleeping for a retry in this terminal-failure test.
	if err := queue.saveJob(context.Background(), job); err != nil {
		t.Fatal(err)
	}

	pool.processJob(context.Background(), 0, job)

	if got, want := lifecycle.snapshot(), []string{"sync:downloading", "failed"}; !sameStrings(got, want) {
		t.Fatalf("lifecycle calls = %#v, want %#v", got, want)
	}
	updated, err := queue.GetJob(context.Background(), job.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Status != StatusFailed || updated.Error == "" {
		t.Fatalf("redis failure = %#v", updated)
	}
}

func TestWorkerPoolPersistsRequeueBeforeBackoffWithoutTerminalFailure(t *testing.T) {
	queue := newTestQueue(t)
	lifecycle := &recordingJobLifecycle{}
	pool := NewWorkerPool(queue, func(context.Context, *DownloadJob, func(int)) error {
		return errors.New("temporary download failure")
	}, &WorkerPoolConfig{WorkerCount: workerCountPtr(0), MaxRetries: 1, Lifecycle: lifecycle})
	job, err := queue.Enqueue(context.Background(), "test-user", "https://example.test/audio", "youtube", nil)
	if err != nil {
		t.Fatal(err)
	}

	pool.processJob(context.Background(), 0, job)

	if got, want := lifecycle.snapshot(), []string{"sync:downloading", "requeue"}; !sameStrings(got, want) {
		t.Fatalf("lifecycle calls = %#v, want %#v", got, want)
	}
	updated, err := queue.GetJob(context.Background(), job.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Status != StatusQueued || updated.RetryCount != 1 || updated.Error != "" {
		t.Fatalf("retry state = %#v", updated)
	}
}

func TestServiceRetryMirrorsDurableRequeueBeforeRedisRetry(t *testing.T) {
	queue := newTestQueue(t)
	lifecycle := &recordingJobLifecycle{}
	service := &Service{queue: queue, lifecycle: lifecycle, maxRetries: 2}
	job, err := queue.Enqueue(context.Background(), "test-user", "https://example.test/manual-retry", "youtube", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := queue.UpdateStatus(context.Background(), job.ID, StatusFailed, 0, "temporary failure"); err != nil {
		t.Fatal(err)
	}
	if err := service.RetryJob(context.Background(), job.ID); err != nil {
		t.Fatal(err)
	}
	if got, want := lifecycle.snapshot(), []string{"requeue"}; !sameStrings(got, want) {
		t.Fatalf("lifecycle calls = %#v, want %#v", got, want)
	}
	updated, err := queue.GetJob(context.Background(), job.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Status != StatusQueued || updated.RetryCount != 1 {
		t.Fatalf("manual retry state = %#v", updated)
	}
}

func sameStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}
