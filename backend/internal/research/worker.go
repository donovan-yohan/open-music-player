package research

import (
	"context"
	"errors"
	"math/rand/v2"
	"sync"
	"time"
)

const (
	DefaultPollInterval   = time.Second
	DefaultLeaseDuration  = 30 * time.Second
	DefaultRenewInterval  = 10 * time.Second
	DefaultRunTimeout     = 2 * time.Minute
	DefaultBackoffBase    = time.Second
	DefaultBackoffMaximum = time.Minute
)

type Ticker interface {
	Chan() <-chan time.Time
	Stop()
}
type WorkerConfig struct {
	Repository                                                                          Repository
	Runner                                                                              Runner
	Validator                                                                           Validator
	WorkerID                                                                            string
	Clock                                                                               func() time.Time
	TickerFactory                                                                       func(time.Duration) Ticker
	Jitter                                                                              func(time.Duration) time.Duration
	PollInterval, LeaseDuration, RenewInterval, RunTimeout, BackoffBase, BackoffMaximum time.Duration
}
type Worker struct {
	repository                                 Repository
	runner                                     Runner
	validator                                  Validator
	workerID                                   string
	now                                        func() time.Time
	tickers                                    func(time.Duration) Ticker
	jitter                                     func(time.Duration) time.Duration
	poll, lease, renew, timeout, base, maximum time.Duration
	mu                                         sync.Mutex
	running                                    bool
	stop                                       context.CancelFunc
	activeCancel                               context.CancelFunc
	wg                                         sync.WaitGroup
}

func NewWorker(c WorkerConfig) *Worker {
	if c.Clock == nil {
		c.Clock = time.Now
	}
	if c.TickerFactory == nil {
		c.TickerFactory = newTimeTicker
	}
	if c.Jitter == nil {
		c.Jitter = defaultJitter
	}
	if c.PollInterval <= 0 {
		c.PollInterval = DefaultPollInterval
	}
	if c.LeaseDuration <= 0 {
		c.LeaseDuration = DefaultLeaseDuration
	}
	if c.RenewInterval <= 0 || c.RenewInterval >= c.LeaseDuration {
		c.RenewInterval = c.LeaseDuration / 3
	}
	if c.RenewInterval <= 0 {
		c.RenewInterval = time.Nanosecond
	}
	if c.RunTimeout <= 0 {
		c.RunTimeout = DefaultRunTimeout
	}
	if c.BackoffBase <= 0 {
		c.BackoffBase = DefaultBackoffBase
	}
	if c.BackoffMaximum < c.BackoffBase {
		c.BackoffMaximum = DefaultBackoffMaximum
	}
	return &Worker{c.Repository, c.Runner, c.Validator, c.WorkerID, c.Clock, c.TickerFactory, c.Jitter, c.PollInterval, c.LeaseDuration, c.RenewInterval, c.RunTimeout, c.BackoffBase, c.BackoffMaximum, sync.Mutex{}, false, nil, nil, sync.WaitGroup{}}
}
func (w *Worker) Start() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.running {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	w.running = true
	w.stop = cancel
	w.wg.Add(1)
	go w.loop(ctx)
}
func (w *Worker) Stop(ctx context.Context) error {
	w.mu.Lock()
	if !w.running {
		w.mu.Unlock()
		return nil
	}
	w.running = false
	w.stop()
	w.mu.Unlock()
	done := make(chan struct{})
	go func() { w.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		w.mu.Lock()
		if w.activeCancel != nil {
			w.activeCancel()
		}
		w.mu.Unlock()
		return ctx.Err()
	}
}
func (w *Worker) IsRunning() bool { w.mu.Lock(); defer w.mu.Unlock(); return w.running }
func (w *Worker) loop(stop context.Context) {
	defer w.wg.Done()
	tick := w.tickers(w.poll)
	defer tick.Stop()
	for {
		select {
		case <-stop.Done():
			return
		default:
		}
		worked, _ := w.RunOnce(context.Background())
		if worked {
			continue
		}
		select {
		case <-stop.Done():
			return
		case <-tick.Chan():
		}
	}
}
func (w *Worker) RunOnce(ctx context.Context) (bool, error) {
	if w.repository == nil || w.runner == nil || w.validator == nil {
		return false, errors.New("research worker requires repository, runner, and validator")
	}
	if _, err := w.repository.RecoverExpiredLeases(ctx, w.now()); err != nil {
		return false, err
	}
	claim, err := w.repository.Claim(ctx, w.workerID, w.now().Add(w.lease))
	if errors.Is(err, ErrNoJobAvailable) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, w.run(ctx, *claim)
}
func (w *Worker) run(ctx context.Context, claim Claim) error {
	runCtx, cancel := context.WithTimeout(ctx, w.timeout)
	w.mu.Lock()
	w.activeCancel = cancel
	w.mu.Unlock()
	defer func() {
		w.mu.Lock()
		if w.activeCancel != nil {
			w.activeCancel = nil
		}
		w.mu.Unlock()
		cancel()
	}()
	result := make(chan error, 1)
	go func() {
		result <- w.runner.Run(runCtx, RunRequest{Snapshot: claim.Snapshot, Run: claim.Run}, workerSink{w.validator, w.repository, claim})
	}()
	tick := w.tickers(w.renew)
	defer tick.Stop()
	for {
		select {
		case err := <-result:
			return w.result(ctx, claim, err)
		case <-runCtx.Done():
			if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
				_, err := w.repository.Degrade(ctx, claim, degradationFor(runCtx.Err()))
				return err
			}
			return runCtx.Err()
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.Chan():
			cancelled, err := w.repository.RenewLease(ctx, claim, w.now().Add(w.lease))
			if errors.Is(err, ErrLeaseLost) {
				cancel()
				return ErrLeaseLost
			}
			if err != nil {
				cancel()
				return err
			}
			if cancelled {
				cancel()
				_, err = w.repository.Finish(ctx, claim, JobCancelled)
				return err
			}
		}
	}
}
func (w *Worker) result(ctx context.Context, claim Claim, err error) error {
	if errors.Is(err, ErrLeaseLost) {
		return ErrLeaseLost
	}
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if err == nil {
		_, err = w.repository.Finish(ctx, claim, JobCompleted)
		return err
	}
	d := degradationFor(err)
	snapshot, opErr := w.repository.Degrade(ctx, claim, d)
	if opErr != nil {
		return opErr
	}
	if CanRetry(snapshot.Job, snapshot.LatestDegradation) {
		_, opErr = w.repository.RetryClaim(ctx, claim, w.now().Add(w.backoff(snapshot.Job.Attempts-1)))
	}
	return opErr
}
func (w *Worker) backoff(attempt int) time.Duration {
	d := w.base
	for i := 0; i < attempt && d < w.maximum; i++ {
		if d > w.maximum/2 {
			d = w.maximum
			break
		}
		d *= 2
	}
	if d > w.maximum {
		d = w.maximum
	}
	j := w.jitter(d)
	if j < 0 {
		j = 0
	}
	if j > d/4 {
		j = d / 4
	}
	if d > w.maximum-j {
		return w.maximum
	}
	return d + j
}

type workerSink struct {
	validator Validator
	repo      Repository
	claim     Claim
}

func (s workerSink) Append(ctx context.Context, input RevisionInput) error {
	if err := ValidateEnhancement(input); err != nil {
		return Validation(err)
	}
	if err := s.validator.ValidateEnhancement(ctx, s.claim.Snapshot, input); err != nil {
		var typed *RunnerError
		if errors.As(err, &typed) {
			return err
		}
		return Validation(err)
	}
	_, err := s.repo.AppendEnhancement(ctx, s.claim, input)
	return err
}
func (s workerSink) Terminal(ctx context.Context, telemetry TerminalTelemetry) error {
	if err := ValidateTerminalTelemetry(telemetry); err != nil {
		return Validation(err)
	}
	return s.repo.RecordTerminal(ctx, s.claim, telemetry)
}
func (s workerSink) Degrade(ctx context.Context, d Degradation) error {
	if err := ValidateDegradation(d); err != nil {
		return err
	}
	_, err := s.repo.Degrade(ctx, s.claim, PublicDegradation(d.Code))
	return err
}

type timeTicker struct{ *time.Ticker }

func newTimeTicker(d time.Duration) Ticker  { return timeTicker{time.NewTicker(d)} }
func (t timeTicker) Chan() <-chan time.Time { return t.C }
func defaultJitter(d time.Duration) time.Duration {
	if d <= 0 {
		return 0
	}
	return time.Duration(rand.Int64N(int64(d/4) + 1))
}
