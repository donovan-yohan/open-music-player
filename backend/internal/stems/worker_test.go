package stems

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

// fakeSeparator records the requests it was given and returns a scripted
// outcome. Separation itself is out of process, so what this package can prove
// is which calls it makes and which durable transitions follow them.
type fakeSeparator struct {
	mu       sync.Mutex
	requests []Request
	manifest *Manifest
	err      error
	block    chan struct{}
}

func (f *fakeSeparator) Separate(ctx context.Context, req Request) (*Manifest, error) {
	f.mu.Lock()
	f.requests = append(f.requests, req)
	block := f.block
	manifest, err := f.manifest, f.err
	f.mu.Unlock()

	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if err != nil {
		return nil, err
	}
	return manifest, nil
}

func (f *fakeSeparator) calls() []Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Request(nil), f.requests...)
}

type storeCall struct {
	method  string
	trackID int64
	detail  string
}

type fakeStore struct {
	mu    sync.Mutex
	calls []storeCall

	markSeparatingErr error
	storeResultErr    error
	markFailedErr     error

	recovered  int64
	recoverErr error
	pending    []db.TrackStems
	pendingErr error

	staleMarked int64
	staleErr    error
}

func (f *fakeStore) record(method string, trackID int64, detail string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, storeCall{method: method, trackID: trackID, detail: detail})
}

func (f *fakeStore) methods() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	names := make([]string, 0, len(f.calls))
	for _, call := range f.calls {
		names = append(names, call.method)
	}
	return names
}

func (f *fakeStore) callsFor(method string) []storeCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	var matches []storeCall
	for _, call := range f.calls {
		if call.method == method {
			matches = append(matches, call)
		}
	}
	return matches
}

func (f *fakeStore) MarkSeparating(_ context.Context, trackID int64, identity db.StemsIdentity, provenance json.RawMessage) error {
	f.record("MarkSeparating", trackID, string(provenance)+"|"+identity.ChannelSet)
	return f.markSeparatingErr
}

func (f *fakeStore) StoreResult(_ context.Context, trackID int64, result db.StemsResult) error {
	f.record("StoreResult", trackID, result.SourceFileHash)
	return f.storeResultErr
}

func (f *fakeStore) MarkFailed(_ context.Context, trackID int64, _ db.StemsIdentity, errText string, _ json.RawMessage) error {
	f.record("MarkFailed", trackID, errText)
	return f.markFailedErr
}

func (f *fakeStore) RecoverInFlight(_ context.Context, _ time.Duration) (int64, error) {
	f.record("RecoverInFlight", 0, "")
	return f.recovered, f.recoverErr
}

func (f *fakeStore) ListPendingSeparations(_ context.Context, _ int) ([]db.TrackStems, error) {
	f.record("ListPendingSeparations", 0, "")
	return f.pending, f.pendingErr
}

func (f *fakeStore) MarkStaleBySourceHash(_ context.Context, trackID int64, sourceFileHash string) (int64, error) {
	f.record("MarkStaleBySourceHash", trackID, sourceFileHash)
	return f.staleMarked, f.staleErr
}

type fakeTrackHashes struct {
	mu       sync.Mutex
	calls    []string
	previous string
	changed  bool
	err      error
}

func (f *fakeTrackHashes) ReconcileSourceFileHash(_ context.Context, _ int64, sourceFileHash string) (string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, sourceFileHash)
	return f.previous, f.changed, f.err
}

func (f *fakeTrackHashes) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func testManifest() *Manifest {
	return &Manifest{
		SchemaVersion:    SchemaVersion,
		TrackID:          42,
		ChannelSet:       ChannelSetStems5Hybrid,
		StemModelVersion: StemModelVersionStems5,
		SourceFileHash:   "sha256:newbytes",
		Artifacts:        json.RawMessage(`{"objects":[]}`),
		Provenance:       json.RawMessage(`{"worker":"stemsep-worker","worker_version":"2026-08-03-1"}`),
	}
}

func testJob() *Job {
	return &Job{
		ID:               JobID(42, ChannelSetStems5Hybrid, StemModelVersionStems5),
		TrackID:          42,
		ChannelSet:       ChannelSetStems5Hybrid,
		StemModelVersion: StemModelVersionStems5,
		StorageKey:       "tracks/youtube/x.mp3",
		Status:           JobStatusQueued,
	}
}

func newTestPool(t *testing.T, separator Separator, store Store, config WorkerPoolConfig) (*WorkerPool, *Queue, *fakeRedis) {
	t.Helper()
	redis := newFakeRedis()
	queue := NewQueueWithClient(redis, QueueConfig{MaxDepth: 8})
	pool, err := NewWorkerPool(queue, separator, store, config)
	if err != nil {
		t.Fatalf("NewWorkerPool: %v", err)
	}
	return pool, queue, redis
}

func TestWorkerPoolProcessesJobThroughDurableTransitions(t *testing.T) {
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{}
	pool, queue, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx := context.Background()
	job := testJob()
	if _, _, err := queue.Enqueue(ctx, EnqueueRequest{
		TrackID:          job.TrackID,
		ChannelSet:       job.ChannelSet,
		StemModelVersion: job.StemModelVersion,
		StorageKey:       job.StorageKey,
	}); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	pool.processNext(ctx, 0)

	got := store.methods()
	want := []string{"MarkSeparating", "StoreResult"}
	if len(got) != len(want) {
		t.Fatalf("store calls = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("store calls = %v, want %v", got, want)
		}
	}

	requests := separator.calls()
	if len(requests) != 1 {
		t.Fatalf("separator called %d times, want 1", len(requests))
	}
	// The worker must ask for the identity this build expects, otherwise the
	// repository's expected_worker guard would let another version's artifacts
	// land on this request.
	if requests[0].ExpectedWorker != WorkerName || requests[0].ExpectedWorkerVersion != WorkerVersion {
		t.Fatalf("separate request identity = %q/%q, want %q/%q",
			requests[0].ExpectedWorker, requests[0].ExpectedWorkerVersion, WorkerName, WorkerVersion)
	}
	if requests[0].StorageKey != job.StorageKey || requests[0].ChannelSet != job.ChannelSet {
		t.Fatalf("separate request = %+v, want storage key %q and channel set %q", requests[0], job.StorageKey, job.ChannelSet)
	}

	stored, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if stored.Status != JobStatusComplete {
		t.Fatalf("job status = %q, want %q", stored.Status, JobStatusComplete)
	}
}

func TestWorkerPoolSkipsSupersededClaim(t *testing.T) {
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{markSeparatingErr: db.ErrStemsResultSuperseded}
	pool, queue, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx := context.Background()
	job := testJob()
	pool.process(ctx, 0, job)

	if calls := separator.calls(); len(calls) != 0 {
		t.Fatalf("separator ran %d times for a superseded claim, want 0", len(calls))
	}
	if failed := store.callsFor("MarkFailed"); len(failed) != 0 {
		t.Fatalf("MarkFailed called %d times for a superseded claim, want 0", len(failed))
	}
	// The durable row belongs to someone else now; only the delivery record is
	// closed out so the queue does not keep reporting the job as live.
	if _, err := queue.GetJob(ctx, job.ID); !errors.Is(err, ErrJobNotFound) {
		t.Fatalf("GetJob err = %v, want ErrJobNotFound for a job that was never saved", err)
	}
}

func TestWorkerPoolMarksSeparationFailureDurable(t *testing.T) {
	separator := &fakeSeparator{err: ErrUnsupported}
	store := &fakeStore{}
	pool, queue, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx := context.Background()
	job := testJob()
	if _, _, err := queue.Enqueue(ctx, EnqueueRequest{
		TrackID:          job.TrackID,
		ChannelSet:       job.ChannelSet,
		StemModelVersion: job.StemModelVersion,
		StorageKey:       job.StorageKey,
	}); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	pool.processNext(ctx, 0)

	failed := store.callsFor("MarkFailed")
	if len(failed) != 1 {
		t.Fatalf("MarkFailed called %d times, want 1 (methods: %v)", len(failed), store.methods())
	}
	if failed[0].detail == "" {
		t.Fatal("MarkFailed recorded an empty error message")
	}
	if stored := store.callsFor("StoreResult"); len(stored) != 0 {
		t.Fatalf("StoreResult called %d times after a failed separation, want 0", len(stored))
	}

	stored, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if stored.Status != JobStatusFailed {
		t.Fatalf("job status = %q, want %q", stored.Status, JobStatusFailed)
	}
}

func TestWorkerPoolLeavesCanceledRunForRecovery(t *testing.T) {
	// A separation interrupted by shutdown is not a failed separation. Marking
	// it failed would spend the user's retry on our own restart, so the row must
	// be left in `separating` for the next process's recovery sweep.
	separator := &fakeSeparator{block: make(chan struct{}), manifest: testManifest()}
	store := &fakeStore{}
	pool, _, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		pool.process(ctx, 0, testJob())
	}()

	// Wait until the separation is actually in flight before canceling.
	deadline := time.Now().Add(2 * time.Second)
	for len(separator.calls()) == 0 {
		if time.Now().After(deadline) {
			cancel()
			t.Fatal("separator was never called")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	<-done

	if failed := store.callsFor("MarkFailed"); len(failed) != 0 {
		t.Fatalf("MarkFailed called %d times for a canceled run, want 0", len(failed))
	}
	if stored := store.callsFor("StoreResult"); len(stored) != 0 {
		t.Fatalf("StoreResult called %d times for a canceled run, want 0", len(stored))
	}
}

func TestWorkerPoolTreatsSupersededResultAsNotAFailure(t *testing.T) {
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{storeResultErr: db.ErrStemsResultSuperseded}
	pool, queue, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx := context.Background()
	job := testJob()
	if _, _, err := queue.Enqueue(ctx, EnqueueRequest{
		TrackID:          job.TrackID,
		ChannelSet:       job.ChannelSet,
		StemModelVersion: job.StemModelVersion,
		StorageKey:       job.StorageKey,
	}); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	pool.processNext(ctx, 0)

	if failed := store.callsFor("MarkFailed"); len(failed) != 0 {
		t.Fatalf("MarkFailed called %d times for a superseded result, want 0", len(failed))
	}
	stored, err := queue.GetJob(ctx, job.ID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if stored.Status != JobStatusComplete {
		t.Fatalf("job status = %q, want %q", stored.Status, JobStatusComplete)
	}
}

func TestWorkerPoolBackfillsSourceHashWithoutInvalidating(t *testing.T) {
	// First separation of a track downloaded before hashes were recorded. The
	// hash becomes known, but nothing was ever derived from a contradicting
	// identity, so no artifact may be invalidated.
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{}
	tracks := &fakeTrackHashes{previous: "", changed: false}
	pool, _, _ := newTestPool(t, separator, store, WorkerPoolConfig{Tracks: tracks})

	pool.process(context.Background(), 0, testJob())

	if tracks.count() != 1 {
		t.Fatalf("ReconcileSourceFileHash called %d times, want 1", tracks.count())
	}
	if stale := store.callsFor("MarkStaleBySourceHash"); len(stale) != 0 {
		t.Fatalf("MarkStaleBySourceHash called %d times for a first-time hash, want 0", len(stale))
	}
}

func TestWorkerPoolInvalidatesStemsWhenSourceAudioChanged(t *testing.T) {
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{staleMarked: 2}
	tracks := &fakeTrackHashes{previous: "sha256:oldbytes", changed: true}
	pool, _, _ := newTestPool(t, separator, store, WorkerPoolConfig{Tracks: tracks})

	pool.process(context.Background(), 0, testJob())

	stale := store.callsFor("MarkStaleBySourceHash")
	if len(stale) != 1 {
		t.Fatalf("MarkStaleBySourceHash called %d times, want 1 (methods: %v)", len(stale), store.methods())
	}
	// It must be invalidated against the NEW hash: every set still carrying the
	// old identity is derived from bytes that no longer exist.
	if stale[0].detail != "sha256:newbytes" {
		t.Fatalf("MarkStaleBySourceHash hash = %q, want the newly separated hash", stale[0].detail)
	}
	if stale[0].trackID != 42 {
		t.Fatalf("MarkStaleBySourceHash track = %d, want 42", stale[0].trackID)
	}
}

func TestWorkerPoolRecoveryRequeuesPendingRows(t *testing.T) {
	// A restart drops the Redis list entries but not the durable rows. Without
	// re-publishing, a pending row waits forever.
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{
		recovered: 1,
		pending: []db.TrackStems{
			{TrackID: 42, ChannelSet: ChannelSetStems5Hybrid, StemModelVersion: StemModelVersionStems5, SourceStorageKey: "tracks/youtube/x.mp3"},
			{TrackID: 43, ChannelSet: ChannelSetStems4Demucs, StemModelVersion: StemModelVersionStems4, SourceStorageKey: "tracks/youtube/y.mp3"},
		},
	}
	pool, queue, _ := newTestPool(t, separator, store, WorkerPoolConfig{})

	ctx := context.Background()
	recovered, requeued, err := pool.Recover(ctx)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if recovered != 1 {
		t.Fatalf("recovered = %d, want 1", recovered)
	}
	if requeued != 2 {
		t.Fatalf("requeued = %d, want 2", requeued)
	}
	depth, err := queue.QueueLength(ctx)
	if err != nil {
		t.Fatalf("QueueLength: %v", err)
	}
	if depth != 2 {
		t.Fatalf("queue depth = %d, want 2", depth)
	}

	// A sweep that overlaps a healthy queue must be a no-op, not a duplicate.
	_, requeuedAgain, err := pool.Recover(ctx)
	if err != nil {
		t.Fatalf("second Recover: %v", err)
	}
	if requeuedAgain != 0 {
		t.Fatalf("second sweep requeued %d jobs, want 0", requeuedAgain)
	}
	depth, err = queue.QueueLength(ctx)
	if err != nil {
		t.Fatalf("QueueLength: %v", err)
	}
	if depth != 2 {
		t.Fatalf("queue depth after second sweep = %d, want 2", depth)
	}
}

func TestWorkerPoolStartRunsRecoveryThenStops(t *testing.T) {
	separator := &fakeSeparator{manifest: testManifest()}
	store := &fakeStore{}
	// Negative interval disables the periodic sweep so the test observes exactly
	// the startup pass.
	pool, _, _ := newTestPool(t, separator, store, WorkerPoolConfig{Concurrency: 2, RecoveryInterval: -1})

	pool.Start(context.Background())
	if !pool.IsRunning() {
		t.Fatal("pool is not running after Start")
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := pool.Stop(stopCtx); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if pool.IsRunning() {
		t.Fatal("pool still running after Stop")
	}

	if recoveries := store.callsFor("RecoverInFlight"); len(recoveries) != 1 {
		t.Fatalf("RecoverInFlight called %d times, want exactly 1 at startup", len(recoveries))
	}
	if listings := store.callsFor("ListPendingSeparations"); len(listings) != 1 {
		t.Fatalf("ListPendingSeparations called %d times, want exactly 1 at startup", len(listings))
	}
}

func TestNewWorkerPoolRequiresCollaborators(t *testing.T) {
	queue := NewQueueWithClient(newFakeRedis(), QueueConfig{})
	if _, err := NewWorkerPool(nil, &fakeSeparator{}, &fakeStore{}, WorkerPoolConfig{}); err == nil {
		t.Fatal("NewWorkerPool accepted a nil queue")
	}
	if _, err := NewWorkerPool(queue, nil, &fakeStore{}, WorkerPoolConfig{}); err == nil {
		t.Fatal("NewWorkerPool accepted a nil separator")
	}
	if _, err := NewWorkerPool(queue, &fakeSeparator{}, nil, WorkerPoolConfig{}); err == nil {
		t.Fatal("NewWorkerPool accepted a nil store")
	}
	pool, err := NewWorkerPool(queue, &fakeSeparator{}, &fakeStore{}, WorkerPoolConfig{})
	if err != nil {
		t.Fatalf("NewWorkerPool: %v", err)
	}
	if pool.concurrency != DefaultConcurrency {
		t.Fatalf("concurrency = %d, want default %d", pool.concurrency, DefaultConcurrency)
	}
}

func TestSleepCtxYieldsToShutdown(t *testing.T) {
	// The dequeue backoff must never hold up Stop: a pool waiting out a Redis
	// outage still has to unwind inside the shutdown budget.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	start := time.Now()
	sleepCtx(ctx, time.Minute)
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("sleepCtx waited %s on a canceled context, want an immediate return", elapsed)
	}

	// It must still actually pause when nothing is stopping it, otherwise the
	// backoff is decorative and the loop spins through an outage.
	start = time.Now()
	sleepCtx(context.Background(), 20*time.Millisecond)
	if elapsed := time.Since(start); elapsed < 10*time.Millisecond {
		t.Fatalf("sleepCtx returned after %s, want it to wait out the delay", elapsed)
	}
}
