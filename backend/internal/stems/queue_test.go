package stems

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// fakeRedis is a deterministic in-memory stand-in for the narrow RedisClient
// slice this queue uses. It keeps list semantics honest (LPUSH at the head,
// BRPOP from the tail) so ordering and position arithmetic are actually tested,
// not mocked away.
type fakeRedis struct {
	mu sync.Mutex

	lists  map[string][]string
	values map[string]string

	published []string

	llenErr  error
	lpushErr error
	setErr   error
	closed   bool
}

func newFakeRedis() *fakeRedis {
	return &fakeRedis{
		lists:  map[string][]string{},
		values: map[string]string{},
	}
}

func (f *fakeRedis) LLen(_ context.Context, key string) *redis.IntCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.llenErr != nil {
		return redis.NewIntResult(0, f.llenErr)
	}
	return redis.NewIntResult(int64(len(f.lists[key])), nil)
}

func (f *fakeRedis) LPos(_ context.Context, key string, value string, _ redis.LPosArgs) *redis.IntCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	for index, item := range f.lists[key] {
		if item == value {
			return redis.NewIntResult(int64(index), nil)
		}
	}
	return redis.NewIntResult(0, redis.Nil)
}

func (f *fakeRedis) LPush(_ context.Context, key string, values ...interface{}) *redis.IntCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.lpushErr != nil {
		return redis.NewIntResult(0, f.lpushErr)
	}
	for _, value := range values {
		text, ok := value.(string)
		if !ok {
			return redis.NewIntResult(0, errors.New("fake redis only stores strings"))
		}
		f.lists[key] = append([]string{text}, f.lists[key]...)
	}
	return redis.NewIntResult(int64(len(f.lists[key])), nil)
}

func (f *fakeRedis) BRPop(_ context.Context, _ time.Duration, keys ...string) *redis.StringSliceCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, key := range keys {
		items := f.lists[key]
		if len(items) == 0 {
			continue
		}
		last := items[len(items)-1]
		f.lists[key] = items[:len(items)-1]
		return redis.NewStringSliceResult([]string{key, last}, nil)
	}
	return redis.NewStringSliceResult(nil, redis.Nil)
}

func (f *fakeRedis) Get(_ context.Context, key string) *redis.StringCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	value, ok := f.values[key]
	if !ok {
		return redis.NewStringResult("", redis.Nil)
	}
	return redis.NewStringResult(value, nil)
}

func (f *fakeRedis) Set(_ context.Context, key string, value interface{}, _ time.Duration) *redis.StatusCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.setErr != nil {
		return redis.NewStatusResult("", f.setErr)
	}
	switch typed := value.(type) {
	case string:
		f.values[key] = typed
	case []byte:
		f.values[key] = string(typed)
	default:
		return redis.NewStatusResult("", errors.New("fake redis only stores strings"))
	}
	return redis.NewStatusResult("OK", nil)
}

func (f *fakeRedis) Del(_ context.Context, keys ...string) *redis.IntCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	deleted := int64(0)
	for _, key := range keys {
		if _, ok := f.values[key]; ok {
			delete(f.values, key)
			deleted++
		}
	}
	return redis.NewIntResult(deleted, nil)
}

func (f *fakeRedis) Publish(_ context.Context, channel string, _ interface{}) *redis.IntCmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.published = append(f.published, channel)
	return redis.NewIntResult(1, nil)
}

func (f *fakeRedis) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
	return nil
}

func (f *fakeRedis) listLen(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.lists[key])
}

func testEnqueueRequest(trackID int64) EnqueueRequest {
	return EnqueueRequest{
		TrackID:          trackID,
		ChannelSet:       ChannelSetStems5Hybrid,
		StemModelVersion: StemModelVersionStems5,
		StorageKey:       "tracks/youtube/fixture.mp3",
	}
}

func TestQueueEnqueueCreatesDeterministicJob(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	job, created, err := queue.Enqueue(ctx, testEnqueueRequest(42))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if !created {
		t.Fatal("created = false, want true for a new job")
	}
	wantID := "42:" + ChannelSetStems5Hybrid + ":" + StemModelVersionStems5
	if job.ID != wantID {
		t.Fatalf("job ID = %q, want %q", job.ID, wantID)
	}
	if job.Status != JobStatusQueued {
		t.Fatalf("status = %q, want %q", job.Status, JobStatusQueued)
	}
	if fake.listLen(keyJobQueue) != 1 {
		t.Fatalf("queue length = %d, want 1", fake.listLen(keyJobQueue))
	}
	if queue.MaxDepth() != DefaultMaxDepth {
		t.Fatalf("MaxDepth = %d, want %d", queue.MaxDepth(), DefaultMaxDepth)
	}
}

func TestQueueEnqueueIsIdempotentForNonTerminalJob(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	first, created, err := queue.Enqueue(ctx, testEnqueueRequest(7))
	if err != nil || !created {
		t.Fatalf("first enqueue: job=%+v created=%v err=%v", first, created, err)
	}
	second, created, err := queue.Enqueue(ctx, testEnqueueRequest(7))
	if err != nil {
		t.Fatalf("second enqueue: %v", err)
	}
	if created {
		t.Fatal("created = true on repeat trigger, want idempotent no-op")
	}
	if second.ID != first.ID {
		t.Fatalf("job ID = %q, want existing %q", second.ID, first.ID)
	}
	if fake.listLen(keyJobQueue) != 1 {
		t.Fatalf("queue length = %d, want 1 (no duplicate entry)", fake.listLen(keyJobQueue))
	}
}

func TestQueueEnqueueRestoresLostListEntry(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	if _, _, err := queue.Enqueue(ctx, testEnqueueRequest(9)); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	// Simulate a lost list entry while the job record survives.
	fake.mu.Lock()
	fake.lists[keyJobQueue] = nil
	fake.mu.Unlock()

	job, created, err := queue.Enqueue(ctx, testEnqueueRequest(9))
	if err != nil {
		t.Fatalf("re-enqueue: %v", err)
	}
	if created {
		t.Fatal("created = true, want restoration of the existing job")
	}
	if job.Status != JobStatusQueued {
		t.Fatalf("status = %q, want %q", job.Status, JobStatusQueued)
	}
	if fake.listLen(keyJobQueue) != 1 {
		t.Fatalf("queue length = %d, want the entry restored", fake.listLen(keyJobQueue))
	}
}

func TestQueueEnqueueRejectsWhenFull(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{MaxDepth: 2})
	ctx := context.Background()

	for _, trackID := range []int64{1, 2} {
		if _, created, err := queue.Enqueue(ctx, testEnqueueRequest(trackID)); err != nil || !created {
			t.Fatalf("enqueue track %d: created=%v err=%v", trackID, created, err)
		}
	}
	_, _, err := queue.Enqueue(ctx, testEnqueueRequest(3))
	if !errors.Is(err, ErrQueueFull) {
		t.Fatalf("error = %v, want ErrQueueFull", err)
	}
	if fake.listLen(keyJobQueue) != 2 {
		t.Fatalf("queue length = %d, want 2 (rejected job not pushed)", fake.listLen(keyJobQueue))
	}
	if _, err := queue.GetJob(ctx, JobID(3, ChannelSetStems5Hybrid, StemModelVersionStems5)); !errors.Is(err, ErrJobNotFound) {
		t.Fatalf("rejected job persisted: %v", err)
	}
}

func TestQueueEnqueueFullStillAdmitsAnAlreadyQueuedJob(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{MaxDepth: 1})
	ctx := context.Background()

	if _, created, err := queue.Enqueue(ctx, testEnqueueRequest(11)); err != nil || !created {
		t.Fatalf("enqueue: created=%v err=%v", created, err)
	}
	// A repeat trigger for the SAME job must not be rejected by backpressure: it
	// adds no work, and rejecting it would make polling look like failure.
	job, created, err := queue.Enqueue(ctx, testEnqueueRequest(11))
	if err != nil {
		t.Fatalf("repeat enqueue at capacity: %v", err)
	}
	if created || job == nil {
		t.Fatalf("created=%v job=%+v, want existing job returned", created, job)
	}
}

func TestQueueEnqueueRollsBackJobRecordWhenPushFails(t *testing.T) {
	fake := newFakeRedis()
	fake.lpushErr = errors.New("redis down")
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	if _, _, err := queue.Enqueue(ctx, testEnqueueRequest(5)); err == nil {
		t.Fatal("enqueue error = nil, want push failure")
	}
	if _, err := queue.GetJob(ctx, JobID(5, ChannelSetStems5Hybrid, StemModelVersionStems5)); !errors.Is(err, ErrJobNotFound) {
		t.Fatalf("orphaned job record survived: %v", err)
	}
}

func TestQueueEnqueueRejectsInvalidRequests(t *testing.T) {
	queue := NewQueueWithClient(newFakeRedis(), QueueConfig{})
	ctx := context.Background()

	cases := []struct {
		name string
		req  EnqueueRequest
	}{
		{"missing track", EnqueueRequest{ChannelSet: ChannelSetStems5Hybrid, StemModelVersion: StemModelVersionStems5}},
		{"missing channel set", EnqueueRequest{TrackID: 1, StemModelVersion: StemModelVersionStems5}},
		{"missing model version", EnqueueRequest{TrackID: 1, ChannelSet: ChannelSetStems5Hybrid}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if _, _, err := queue.Enqueue(ctx, testCase.req); err == nil {
				t.Fatal("error = nil, want validation failure")
			}
		})
	}
}

func TestQueueDequeueIsFIFOAcrossEnqueues(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	for _, trackID := range []int64{1, 2, 3} {
		if _, _, err := queue.Enqueue(ctx, testEnqueueRequest(trackID)); err != nil {
			t.Fatalf("enqueue %d: %v", trackID, err)
		}
	}
	for _, want := range []int64{1, 2, 3} {
		job, err := queue.Dequeue(ctx, time.Second)
		if err != nil {
			t.Fatalf("dequeue: %v", err)
		}
		if job.TrackID != want {
			t.Fatalf("dequeued track %d, want %d", job.TrackID, want)
		}
	}
	if _, err := queue.Dequeue(ctx, time.Second); !errors.Is(err, ErrQueueEmpty) {
		t.Fatalf("drained dequeue error = %v, want ErrQueueEmpty", err)
	}
}

func TestQueuePositionCountsJobsAhead(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	for _, trackID := range []int64{1, 2, 3} {
		if _, _, err := queue.Enqueue(ctx, testEnqueueRequest(trackID)); err != nil {
			t.Fatalf("enqueue %d: %v", trackID, err)
		}
	}
	for trackID, want := range map[int64]int64{1: 0, 2: 1, 3: 2} {
		position, err := queue.QueuePosition(ctx, JobID(trackID, ChannelSetStems5Hybrid, StemModelVersionStems5))
		if err != nil {
			t.Fatalf("position for track %d: %v", trackID, err)
		}
		if position != want {
			t.Fatalf("track %d position = %d, want %d", trackID, position, want)
		}
	}
	position, err := queue.QueuePosition(ctx, JobID(99, ChannelSetStems5Hybrid, StemModelVersionStems5))
	if err != nil {
		t.Fatalf("absent job position: %v", err)
	}
	if position != -1 {
		t.Fatalf("absent job position = %d, want -1", position)
	}
}

func TestQueueUpdateStatusPersistsAndPublishes(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	job, _, err := queue.Enqueue(ctx, testEnqueueRequest(21))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if err := queue.UpdateStatus(ctx, job.ID, JobStatusFailed, "separation crashed"); err != nil {
		t.Fatalf("update status: %v", err)
	}
	stored, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("get job: %v", err)
	}
	if stored.Status != JobStatusFailed || stored.Error != "separation crashed" {
		t.Fatalf("stored job = %+v, want failed with error text", stored)
	}
	if !stored.IsTerminal() {
		t.Fatal("IsTerminal = false for a failed job")
	}
	fake.mu.Lock()
	published := append([]string(nil), fake.published...)
	fake.mu.Unlock()
	if len(published) != 1 || !strings.HasPrefix(published[0], keyProgress+":") {
		t.Fatalf("published channels = %v, want one stems:progress channel", published)
	}
}

func TestQueueEnqueueReplacesTerminalJob(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	job, _, err := queue.Enqueue(ctx, testEnqueueRequest(33))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if _, err := queue.Dequeue(ctx, time.Second); err != nil {
		t.Fatalf("dequeue: %v", err)
	}
	if err := queue.UpdateStatus(ctx, job.ID, JobStatusFailed, "boom"); err != nil {
		t.Fatalf("update status: %v", err)
	}

	retried, created, err := queue.Enqueue(ctx, testEnqueueRequest(33))
	if err != nil {
		t.Fatalf("retry enqueue: %v", err)
	}
	if !created {
		t.Fatal("created = false, want a terminal job to be retryable")
	}
	if retried.Status != JobStatusQueued || retried.Error != "" {
		t.Fatalf("retried job = %+v, want a clean queued job", retried)
	}
}

func TestQueueGetJobRejectsCorruptPayload(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	ctx := context.Background()

	fake.mu.Lock()
	fake.values[keyJobStatus+"corrupt"] = "{not json"
	fake.mu.Unlock()

	if _, err := queue.GetJob(ctx, "corrupt"); err == nil {
		t.Fatal("error = nil, want unmarshal failure")
	}
}

func TestQueueUsesIsolatedRedisKeyNamespace(t *testing.T) {
	// Queue isolation from downloads/analysis is the load-bearing property: a
	// saturated stems backlog must not touch the download list.
	for _, key := range []string{keyJobQueue, keyJobStatus, keyProgress} {
		if !strings.HasPrefix(key, "stems:") {
			t.Fatalf("key %q is not in the stems namespace", key)
		}
		if strings.HasPrefix(key, "download:") {
			t.Fatalf("key %q collides with the download namespace", key)
		}
	}
}

func TestQueueClosePassesThroughOnlyForOwnedClients(t *testing.T) {
	fake := newFakeRedis()
	queue := NewQueueWithClient(fake, QueueConfig{})
	if err := queue.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	fake.mu.Lock()
	closed := fake.closed
	fake.mu.Unlock()
	if closed {
		t.Fatal("injected client was closed; the owner keeps the lifecycle")
	}
}

func TestJobRoundTripsThroughJSON(t *testing.T) {
	job := Job{
		ID:               JobID(1, ChannelSetStems4Demucs, StemModelVersionStems4),
		TrackID:          1,
		ChannelSet:       ChannelSetStems4Demucs,
		StemModelVersion: StemModelVersionStems4,
		StorageKey:       "tracks/youtube/x.mp3",
		SourceFileHash:   "sha256:abc",
		Status:           JobStatusSeparating,
		CreatedAt:        time.Unix(0, 0).UTC(),
		UpdatedAt:        time.Unix(0, 0).UTC(),
	}
	encoded, err := json.Marshal(job)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded Job
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded != job {
		t.Fatalf("decoded = %+v, want %+v", decoded, job)
	}
}
