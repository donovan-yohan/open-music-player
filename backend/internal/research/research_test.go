package research

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestTransitionMatrix(t *testing.T) {
	states := []JobStatus{JobQueued, JobRunning, JobCancelRequested, JobCompleted, JobDegraded, JobCancelled}
	ok := map[JobStatus]map[JobStatus]bool{JobQueued: {JobRunning: true, JobCancelled: true}, JobRunning: {JobCancelRequested: true, JobCompleted: true, JobDegraded: true}, JobCancelRequested: {JobCancelled: true}, JobDegraded: {JobQueued: true}}
	for _, a := range states {
		for _, b := range states {
			if (TransitionJob(a, b) == nil) != ok[a][b] {
				t.Errorf("%s->%s", a, b)
			}
		}
	}
}
func TestRetryGuards(t *testing.T) {
	base := Job{Status: JobDegraded, RetrySafe: true, Attempts: 1, MaxAttempts: 2}
	if !CanRetry(base, &Degradation{Code: DegradationTransient, Retryable: true}) {
		t.Fatal("transient degraded should retry")
	}
	for _, d := range []*Degradation{{Code: DegradationSafetyRejected}, {Code: DegradationValidationRejected}} {
		if CanRetry(base, d) {
			t.Fatal("safety/validation retried")
		}
	}
	base.Attempts = 2
	if CanRetry(base, &Degradation{Code: DegradationTransient, Retryable: true}) {
		t.Fatal("retry bound ignored")
	}
	if TransitionJob(JobCancelled, JobQueued) == nil {
		t.Fatal("canceled job retried")
	}
	for _, code := range []DegradationCode{DegradationModelUnavailable, DegradationTransient, DegradationTimeout, DegradationLeaseExpired} {
		if degradation := effectiveDegradation(Job{Attempts: 2, MaxAttempts: 2}, PublicDegradation(code)); degradation.Retryable {
			t.Fatalf("%s stayed retryable at the attempt cap", code)
		}
	}
}
func TestServiceCreatesValidatedBaselineSnapshot(t *testing.T) {
	r := newMemory()
	s := NewService(ServiceConfig{Repository: r, Validator: validatorFunc{}})
	snap, err := s.Create(context.Background(), input())
	if err != nil {
		t.Fatal(err)
	}
	if snap.Job.LatestRevision != 1 || len(snap.Revisions) != 1 || snap.Revisions[0].Kind != RevisionBaseline {
		t.Fatalf("snapshot %#v", snap)
	}
	if len(r.events) != 2 {
		t.Fatalf("events %#v", r.events)
	}
}

func TestServiceCanonicalizesRequestHash(t *testing.T) {
	r := newMemory()
	s := NewService(ServiceConfig{Repository: r, Validator: validatorFunc{}})
	input := input()
	input.Request = []byte(`{"limit":2,"query":"fixture","providers":["youtube"]}`)
	input.RequestHash = "caller-controlled"
	snapshot, err := s.Create(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	canonical, hash, err := CanonicalRequestHash([]byte(`{"providers":["youtube"],"query":"fixture","limit":2}`))
	if err != nil || snapshot.Job.RequestHash != hash || string(snapshot.Job.Request) != string(canonical) {
		t.Fatalf("canonical request=%s hash=%s want=%s", snapshot.Job.Request, snapshot.Job.RequestHash, hash)
	}
}

func TestCancelReturnsBaselinePreservingSnapshot(t *testing.T) {
	r := newMemory()
	_, _ = r.Create(context.Background(), input())
	claim, err := r.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	snap, err := r.Cancel(context.Background(), "j", "o")
	if err != nil || snap.Job.Status != JobCancelRequested || len(snap.Revisions) != 1 {
		t.Fatalf("%v %#v", err, snap)
	}
	snap, err = r.Finish(context.Background(), *claim, JobCancelled)
	if err != nil || snap.Job.Status != JobCancelled || len(snap.Revisions) != 1 {
		t.Fatalf("%v %#v", err, snap)
	}
}
func TestWorkerRejectsInvalidEnhancement(t *testing.T) {
	for _, validator := range []Validator{rejectValidator{}, safetyValidator{}} {
		r := newMemory()
		_, _ = r.Create(context.Background(), input())
		w := worker(r, runnerFunc(func(c context.Context, _ RunRequest, s EnhancementSink) error {
			return s.Append(c, RevisionInput{ID: "bad", Payload: []byte(`{"candidates":[{"candidateId":"unknown"}]}`)})
		}), validator)
		if _, err := w.RunOnce(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(r.snapshot().Revisions) != 1 {
			t.Fatal("invalid enhancement appended")
		}
		if r.snapshot().Job.Status != JobDegraded {
			t.Fatal("invalid enhancement did not degrade job")
		}
	}
}
func TestWorkerDegradesAndRetriesOnlyTransient(t *testing.T) {
	r := newMemory()
	_, _ = r.Create(context.Background(), input())
	w := worker(r, runnerFunc(func(context.Context, RunRequest, EnhancementSink) error { return Transient(errors.New("down")) }), validatorFunc{})
	_, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if r.snapshot().Job.Status != JobQueued {
		t.Fatalf("%#v", r.snapshot().Job)
	}
	r = newMemory()
	_, _ = r.Create(context.Background(), input())
	w = worker(r, runnerFunc(func(context.Context, RunRequest, EnhancementSink) error { return Safety(errors.New("unsafe")) }), validatorFunc{})
	_, err = w.RunOnce(context.Background())
	if err != nil || r.snapshot().Job.Status != JobDegraded {
		t.Fatalf("%v %#v", err, r.snapshot().Job)
	}
}
func TestWorkerTimeoutAndLeaseLossPreserveBaseline(t *testing.T) {
	r := newMemory()
	_, _ = r.Create(context.Background(), input())
	w := worker(r, runnerFunc(func(context.Context, RunRequest, EnhancementSink) error { return context.DeadlineExceeded }), validatorFunc{})
	_, _ = w.RunOnce(context.Background())
	if r.snapshot().Job.Status != JobQueued {
		t.Fatal("timeout was not retried")
	}
	r = newMemory()
	_, _ = r.Create(context.Background(), input())
	r.renewErr = ErrLeaseLost
	tick := &manual{c: make(chan time.Time, 1)}
	started := make(chan struct{})
	w = worker(r, runnerFunc(func(c context.Context, _ RunRequest, _ EnhancementSink) error {
		close(started)
		<-c.Done()
		return c.Err()
	}), validatorFunc{})
	w.tickers = func(time.Duration) Ticker { return tick }
	done := make(chan error, 1)
	go func() { _, e := w.RunOnce(context.Background()); done <- e }()
	<-started
	tick.c <- time.Now()
	if !errors.Is(<-done, ErrLeaseLost) {
		t.Fatal("lease loss not surfaced")
	}
	if len(r.snapshot().Revisions) != 1 {
		t.Fatal("baseline lost")
	}
}
func TestReviewValidation(t *testing.T) {
	if ValidateReview(ReviewInput{RevisionID: "r", RevisionNumber: 1, CandidateID: "c", Action: ReviewAccepted, IdempotencyKey: "k"}) != nil {
		t.Fatal("valid review")
	}
	if ValidateReview(ReviewInput{RevisionID: "r", RevisionNumber: 1, CandidateID: "c", Action: ReviewAccepted, IdempotencyKey: "k", Reason: string(make([]byte, 513))}) == nil {
		t.Fatal("reason bound")
	}
}

func TestStopDeadlineCancelsActiveRunner(t *testing.T) {
	r := newMemory()
	_, _ = r.Create(context.Background(), input())
	started, canceled := make(chan struct{}), make(chan struct{})
	w := worker(r, runnerFunc(func(ctx context.Context, _ RunRequest, _ EnhancementSink) error {
		close(started)
		<-ctx.Done()
		close(canceled)
		return ctx.Err()
	}), validatorFunc{})
	w.Start()
	<-started
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if !errors.Is(w.Stop(ctx), context.Canceled) {
		t.Fatal("stop deadline was not returned")
	}
	<-canceled
}

type runnerFunc func(context.Context, RunRequest, EnhancementSink) error

func (f runnerFunc) Run(c context.Context, r RunRequest, s EnhancementSink) error { return f(c, r, s) }

type validatorFunc struct{}

func (validatorFunc) ValidateBaseline(_ context.Context, i RevisionInput) error { return shape(i) }
func (validatorFunc) ValidateEnhancement(_ context.Context, _ Snapshot, i RevisionInput) error {
	return shape(i)
}

type rejectValidator struct{ validatorFunc }

func (rejectValidator) ValidateEnhancement(context.Context, Snapshot, RevisionInput) error {
	return errors.New("unknown candidate")
}

type safetyValidator struct{ validatorFunc }

func (safetyValidator) ValidateEnhancement(context.Context, Snapshot, RevisionInput) error {
	return Safety(errors.New("unsafe candidate"))
}
func shape(i RevisionInput) error {
	if i.ID == "" || len(i.Payload) == 0 {
		return errors.New("invalid shape")
	}
	return nil
}
func input() CreateInput {
	return CreateInput{ID: "j", OwnerID: "o", Request: []byte(`{}`), RequestHash: "h", RetrySafe: true, MaxAttempts: 2, IdempotencyKey: "i", Baseline: RevisionInput{ID: "r1", Payload: []byte(`{"candidates":[]}`)}}
}

type manual struct{ c chan time.Time }

func (m *manual) Chan() <-chan time.Time { return m.c }
func (*manual) Stop()                    {}
func worker(r Repository, run Runner, v Validator) *Worker {
	return NewWorker(WorkerConfig{Repository: r, Runner: run, Validator: v, WorkerID: "w", Clock: func() time.Time { return time.Unix(1, 0) }, Jitter: func(time.Duration) time.Duration { return 0 }})
}

type memory struct {
	mu       sync.Mutex
	s        Snapshot
	events   []Event
	claimed  bool
	renewErr error
}

func newMemory() *memory { return &memory{} }
func (m *memory) Create(_ context.Context, i CreateInput) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ValidateCreate(i); err != nil {
		return nil, err
	}
	now := time.Unix(1, 0)
	m.s = Snapshot{Job: Job{ID: i.ID, OwnerID: i.OwnerID, Request: i.Request, RequestHash: i.RequestHash, IdempotencyKey: i.IdempotencyKey, Status: JobQueued, RetrySafe: i.RetrySafe, MaxAttempts: i.MaxAttempts, AvailableAt: now, LatestRevision: 1, LatestRevisionID: i.Baseline.ID}, Revisions: []Revision{{ID: i.Baseline.ID, JobID: i.ID, Number: 1, Kind: RevisionBaseline, Payload: i.Baseline.Payload, ValidatedAt: now}}}
	m.events = []Event{{Sequence: 1, Kind: EventCreated}, {Sequence: 2, Kind: EventRevisionAppended, Revision: 1, RevisionID: i.Baseline.ID}}
	return m.copyLocked(), nil
}
func (m *memory) Get(_ context.Context, _, _ string) (*Snapshot, error) { return m.copy(), nil }
func (m *memory) Events(context.Context, string, string, int64, int) ([]Event, error) {
	return append([]Event(nil), m.events...), nil
}
func (m *memory) Cancel(context.Context, string, string) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := TransitionJob(m.s.Job.Status, JobCancelRequested); err != nil {
		return nil, err
	}
	m.s.Job.Status = JobCancelRequested
	return m.copyLocked(), nil
}
func (m *memory) Retry(context.Context, string, string) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !CanRetry(m.s.Job, m.s.LatestDegradation) {
		return nil, ErrInvalidTransition
	}
	m.s.Job.Status = JobQueued
	return m.copyLocked(), nil
}
func (*memory) Review(context.Context, string, string, ReviewInput) error { return nil }
func (m *memory) Claim(_ context.Context, w string, lease time.Time) (*Claim, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.claimed || m.s.Job.Status != JobQueued {
		return nil, ErrNoJobAvailable
	}
	m.claimed = true
	m.s.Job.Status = JobRunning
	m.s.Job.Attempts++
	return &Claim{Snapshot: *m.copyLocked(), Run: Run{ID: "run", JobID: m.s.Job.ID, WorkerID: w, Status: RunRunning, LeaseExpiresAt: lease}}, nil
}
func (m *memory) RenewLease(context.Context, Claim, time.Time) (bool, error) {
	return false, m.renewErr
}
func (*memory) RecoverExpiredLeases(context.Context, time.Time) (int, error) { return 0, nil }
func (m *memory) AppendEnhancement(_ context.Context, _ Claim, i RevisionInput) (*Revision, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.s.Job.Status != JobRunning {
		return nil, ErrLeaseLost
	}
	r := Revision{ID: i.ID, JobID: m.s.Job.ID, Number: len(m.s.Revisions) + 1, Kind: RevisionEnhancement, Payload: i.Payload}
	m.s.Revisions = append(m.s.Revisions, r)
	m.s.Job.LatestRevision = r.Number
	m.s.Job.LatestRevisionID = r.ID
	return &r, nil
}
func (m *memory) RecordTerminal(_ context.Context, _ Claim, telemetry TerminalTelemetry) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ValidateTerminalTelemetry(telemetry); err != nil {
		return err
	}
	copy := telemetry
	m.s.LatestTerminalTelemetry = &copy
	return nil
}
func (m *memory) Degrade(_ context.Context, _ Claim, d Degradation) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ValidateDegradation(d); err != nil {
		return nil, err
	}
	if err := TransitionJob(m.s.Job.Status, JobDegraded); err != nil {
		return nil, err
	}
	m.s.Job.Status = JobDegraded
	m.s.LatestDegradation = &d
	return m.copyLocked(), nil
}
func (m *memory) RetryClaim(_ context.Context, _ Claim, _ time.Time) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !CanRetry(m.s.Job, m.s.LatestDegradation) {
		return nil, ErrInvalidTransition
	}
	m.s.Job.Status = JobQueued
	m.claimed = false
	return m.copyLocked(), nil
}
func (m *memory) Finish(_ context.Context, _ Claim, status JobStatus) (*Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := TransitionJob(m.s.Job.Status, status); err != nil {
		return nil, err
	}
	m.s.Job.Status = status
	return m.copyLocked(), nil
}
func (m *memory) copy() *Snapshot { m.mu.Lock(); defer m.mu.Unlock(); return m.copyLocked() }
func (m *memory) copyLocked() *Snapshot {
	s := m.s
	s.Revisions = append([]Revision(nil), m.s.Revisions...)
	if m.s.LatestDegradation != nil {
		d := *m.s.LatestDegradation
		s.LatestDegradation = &d
	}
	return &s
}
func (m *memory) snapshot() Snapshot { return *m.copy() }
