package stems

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

const (
	// DefaultConcurrency matches STEMS_CONCURRENCY. Separation is minutes of
	// saturated CPU per track, so the default is one: a second worker does not
	// make the host finish sooner, it only makes both runs slower and starves
	// playback and analysis on the same box.
	DefaultConcurrency = 1

	// workerDequeueTimeout keeps Stop from being held behind a blocking Redis
	// pop on an idle queue.
	workerDequeueTimeout = 1 * time.Second

	// DefaultRecoveryInterval is how often durable state is reconciled against
	// the queue. A restart drops the Redis list entries but not the track_stems
	// rows, and RecoverInFlight only reclaims rows that have been untouched long
	// enough to be certain no live worker owns them, so recovery has to be a
	// repeating sweep rather than a single startup pass.
	DefaultRecoveryInterval = 5 * time.Minute
)

// Separator is the worker-facing slice of ServiceClient.
type Separator interface {
	Separate(ctx context.Context, req Request) (*Manifest, error)
}

// Store is the durable authority for separations: the track_stems repository.
// Redis carries delivery state, Postgres carries truth, and every transition
// below is guarded by the identity checks in that repository.
type Store interface {
	MarkSeparating(ctx context.Context, trackID int64, identity db.StemsIdentity, provenance json.RawMessage) error
	StoreResult(ctx context.Context, trackID int64, result db.StemsResult) error
	MarkFailed(ctx context.Context, trackID int64, identity db.StemsIdentity, errText string, provenance json.RawMessage) error
	RecoverInFlight(ctx context.Context, staleAfter time.Duration) (int64, error)
	ListPendingSeparations(ctx context.Context, limit int) ([]db.TrackStems, error)
	MarkStaleBySourceHash(ctx context.Context, trackID int64, sourceFileHash string) (int64, error)
}

// TrackSourceHashStore records the content identity of a track's stored audio.
// It is optional: without it separation still works, but a replaced audio object
// cannot be detected, so stem artifacts derived from the previous bytes would
// keep being served as current.
type TrackSourceHashStore interface {
	ReconcileSourceFileHash(ctx context.Context, trackID int64, sourceFileHash string) (string, bool, error)
}

// WorkerPoolConfig configures the stems consumer.
type WorkerPoolConfig struct {
	// Concurrency is the number of workers. Zero selects DefaultConcurrency.
	Concurrency int
	// JobTimeout bounds one separation. Zero leaves the bound to the service
	// client's own HTTP timeout, which is the configured STEMS_TIMEOUT_MS.
	JobTimeout time.Duration
	// RecoveryInterval is the durable reconciliation period. Zero selects
	// DefaultRecoveryInterval; negative disables the periodic sweep (the sweep
	// at Start still runs).
	RecoveryInterval time.Duration
	// RecoveryStaleAfter is how long a `separating` row may sit untouched before
	// it is reclaimed. Zero uses the repository default.
	RecoveryStaleAfter time.Duration
	// Tracks is the optional source-hash reconciler.
	Tracks TrackSourceHashStore
}

// WorkerPool consumes stems:queue and drives the durable track_stems lifecycle.
//
// It deliberately does not retry a failed separation in process. One attempt is
// minutes of CPU, and the repository already models retry as a user-visible
// state: a failed row is re-requestable through the normal trigger, which
// returns reason="failed_retry". An automatic retry would burn the host on a
// permanently broken source while hiding the failure from the person who asked.
type WorkerPool struct {
	queue     *Queue
	separator Separator
	store     Store
	tracks    TrackSourceHashStore

	concurrency        int
	jobTimeout         time.Duration
	recoveryInterval   time.Duration
	recoveryStaleAfter time.Duration

	wg         sync.WaitGroup
	mu         sync.RWMutex
	running    bool
	stopCancel context.CancelFunc
}

// NewWorkerPool builds the consumer. queue, separator and store are required.
func NewWorkerPool(queue *Queue, separator Separator, store Store, config WorkerPoolConfig) (*WorkerPool, error) {
	if queue == nil {
		return nil, errors.New("stems worker pool requires a queue")
	}
	if separator == nil {
		return nil, errors.New("stems worker pool requires a separator")
	}
	if store == nil {
		return nil, errors.New("stems worker pool requires a durable store")
	}
	concurrency := config.Concurrency
	if concurrency <= 0 {
		concurrency = DefaultConcurrency
	}
	recoveryInterval := config.RecoveryInterval
	if recoveryInterval == 0 {
		recoveryInterval = DefaultRecoveryInterval
	}
	return &WorkerPool{
		queue:              queue,
		separator:          separator,
		store:              store,
		tracks:             config.Tracks,
		concurrency:        concurrency,
		jobTimeout:         config.JobTimeout,
		recoveryInterval:   recoveryInterval,
		recoveryStaleAfter: config.RecoveryStaleAfter,
	}, nil
}

// Start runs one durable recovery sweep, then launches the workers and the
// periodic sweep. Recovery runs before the workers so a restart reclaims its own
// abandoned rows rather than racing them.
func (p *WorkerPool) Start(ctx context.Context) {
	p.mu.Lock()
	if p.running {
		p.mu.Unlock()
		return
	}
	p.running = true
	runCtx, cancel := context.WithCancel(context.Background())
	p.stopCancel = cancel
	p.mu.Unlock()

	if recovered, requeued, err := p.Recover(ctx); err != nil {
		log.Printf("stems worker pool: startup recovery failed: %v", err)
	} else if recovered > 0 || requeued > 0 {
		log.Printf("stems worker pool: startup recovery reclaimed %d row(s) and requeued %d job(s)", recovered, requeued)
	}

	for i := 0; i < p.concurrency; i++ {
		p.wg.Add(1)
		go p.worker(runCtx, i)
	}
	if p.recoveryInterval > 0 {
		p.wg.Add(1)
		go p.recoveryLoop(runCtx)
	}
	log.Printf("stems worker pool started with %d worker(s)", p.concurrency)
}

// Stop cancels the workers and waits for the in-flight separation to unwind.
// A separation that is canceled mid-run leaves its row in `separating`; the next
// process's recovery sweep reclaims it, which is why the row is the authority.
func (p *WorkerPool) Stop(ctx context.Context) error {
	p.mu.Lock()
	if !p.running {
		p.mu.Unlock()
		return nil
	}
	p.running = false
	if p.stopCancel != nil {
		p.stopCancel()
	}
	p.mu.Unlock()

	done := make(chan struct{})
	go func() {
		p.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		log.Println("stems worker pool stopped gracefully")
		return nil
	case <-ctx.Done():
		log.Println("stems worker pool shutdown timed out")
		return ctx.Err()
	}
}

// IsRunning reports whether the pool is consuming.
func (p *WorkerPool) IsRunning() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.running
}

// Recover reconciles durable state with the queue: abandoned `separating` rows
// return to pending, and every pending row is (re-)published. Both halves are
// idempotent, so a sweep that overlaps a healthy queue is a no-op.
func (p *WorkerPool) Recover(ctx context.Context) (int64, int, error) {
	recovered, err := p.store.RecoverInFlight(ctx, p.recoveryStaleAfter)
	if err != nil {
		return 0, 0, fmt.Errorf("recover in-flight stem separations: %w", err)
	}
	pending, err := p.store.ListPendingSeparations(ctx, p.queue.MaxDepth())
	if err != nil {
		return recovered, 0, fmt.Errorf("list pending stem separations: %w", err)
	}
	requeued := 0
	for _, row := range pending {
		_, created, enqueueErr := p.queue.Enqueue(ctx, EnqueueRequest{
			TrackID:          row.TrackID,
			ChannelSet:       row.ChannelSet,
			StemModelVersion: row.StemModelVersion,
			StorageKey:       row.SourceStorageKey,
			SourceFileHash:   row.SourceFileHash,
		})
		if errors.Is(enqueueErr, ErrQueueFull) {
			// The queue is already carrying a full backlog. The remaining rows
			// stay pending and are picked up by a later sweep.
			break
		}
		if enqueueErr != nil {
			log.Printf("stems worker pool: failed to requeue track %d (%s): %v", row.TrackID, row.ChannelSet, enqueueErr)
			continue
		}
		if created {
			requeued++
		}
	}
	return recovered, requeued, nil
}

func (p *WorkerPool) recoveryLoop(runCtx context.Context) {
	defer p.wg.Done()
	ticker := time.NewTicker(p.recoveryInterval)
	defer ticker.Stop()
	for {
		select {
		case <-runCtx.Done():
			return
		case <-ticker.C:
			recovered, requeued, err := p.Recover(runCtx)
			if err != nil {
				if runCtx.Err() == nil {
					log.Printf("stems worker pool: recovery sweep failed: %v", err)
				}
				continue
			}
			if recovered > 0 || requeued > 0 {
				log.Printf("stems worker pool: recovery sweep reclaimed %d row(s) and requeued %d job(s)", recovered, requeued)
			}
		}
	}
}

func (p *WorkerPool) worker(runCtx context.Context, id int) {
	defer p.wg.Done()
	for {
		select {
		case <-runCtx.Done():
			return
		default:
		}
		p.processNext(runCtx, id)
	}
}

func (p *WorkerPool) processNext(runCtx context.Context, workerID int) {
	job, err := p.queue.Dequeue(runCtx, workerDequeueTimeout)
	if err != nil {
		if errors.Is(err, ErrQueueEmpty) || errors.Is(err, context.Canceled) || runCtx.Err() != nil {
			return
		}
		if errors.Is(err, ErrJobNotFound) {
			// The list entry outlived its status key. The durable row is
			// unaffected and a recovery sweep republishes it.
			return
		}
		log.Printf("stems worker %d: failed to dequeue: %v", workerID, err)
		return
	}
	if job == nil {
		return
	}
	p.process(runCtx, workerID, job)
}

func (p *WorkerPool) process(runCtx context.Context, workerID int, job *Job) {
	identity := db.StemsIdentity{ChannelSet: job.ChannelSet, StemModelVersion: job.StemModelVersion}
	provenance := workerProvenance(job)

	// Claim the durable row first. A refusal here means this job no longer owns
	// the request (superseded, already ready under another worker version, or
	// the row was removed), so the separation must not run at all.
	if err := p.store.MarkSeparating(runCtx, job.TrackID, identity, provenance); err != nil {
		if errors.Is(err, db.ErrStemsResultSuperseded) {
			log.Printf("stems worker %d: skipping superseded job %s", workerID, job.ID)
			p.updateJob(runCtx, job.ID, JobStatusFailed, "superseded by another separation request")
			return
		}
		// A transient store failure is not the request's fault. The durable row
		// stays pending, so only the delivery record is failed; a recovery sweep
		// republishes it rather than spending the user's retry.
		log.Printf("stems worker %d: failed to claim job %s: %v", workerID, job.ID, err)
		p.updateJob(runCtx, job.ID, JobStatusFailed, err.Error())
		return
	}
	p.updateJob(runCtx, job.ID, JobStatusSeparating, "")

	sepCtx := runCtx
	if p.jobTimeout > 0 {
		var cancel context.CancelFunc
		sepCtx, cancel = context.WithTimeout(runCtx, p.jobTimeout)
		defer cancel()
	}

	manifest, err := p.separator.Separate(sepCtx, Request{
		SchemaVersion:         SchemaVersion,
		TrackID:               job.TrackID,
		StorageKey:            job.StorageKey,
		ChannelSet:            job.ChannelSet,
		ExpectedWorker:        WorkerName,
		ExpectedWorkerVersion: WorkerVersion,
	})
	if err != nil {
		p.failJob(runCtx, workerID, job, identity, provenance, err)
		return
	}

	result := db.StemsResult{
		SchemaVersion:    manifest.SchemaVersion,
		ChannelSet:       manifest.ChannelSet,
		StemModelVersion: manifest.StemModelVersion,
		SourceFileHash:   manifest.SourceFileHash,
		ArtifactsJSON:    manifest.Artifacts,
		ProvenanceJSON:   manifest.Provenance,
	}
	if err := p.store.StoreResult(runCtx, job.TrackID, result); err != nil {
		if errors.Is(err, db.ErrStemsResultSuperseded) {
			// A duplicate delivery, or a request that moved on while this run
			// was in flight. Neither is a failure of the durable row.
			log.Printf("stems worker %d: result for job %s was superseded; leaving durable row untouched", workerID, job.ID)
			p.updateJob(runCtx, job.ID, JobStatusComplete, "")
			return
		}
		log.Printf("stems worker %d: failed to store result for job %s: %v", workerID, job.ID, err)
		p.failJob(runCtx, workerID, job, identity, provenance, fmt.Errorf("store separation result: %w", err))
		return
	}

	p.reconcileSourceHash(runCtx, workerID, job.TrackID, manifest.SourceFileHash)
	p.updateJob(runCtx, job.ID, JobStatusComplete, "")
	log.Printf("stems worker %d: job %s completed", workerID, job.ID)
}

// reconcileSourceHash records the hash of the bytes the worker actually
// separated. This is the hash-on-first-separation backfill for tracks that
// predate source-hash recording, and the detector for audio replaced under an
// existing track: when a DIFFERENT hash was already known, every other stem set
// for that track was derived from bytes that no longer exist and is marked
// stale. The row just stored is excluded because it already carries the new
// hash.
func (p *WorkerPool) reconcileSourceHash(ctx context.Context, workerID int, trackID int64, sourceFileHash string) {
	if p.tracks == nil || strings.TrimSpace(sourceFileHash) == "" {
		return
	}
	previous, changed, err := p.tracks.ReconcileSourceFileHash(ctx, trackID, sourceFileHash)
	if err != nil {
		log.Printf("stems worker %d: failed to record source file hash for track %d: %v", workerID, trackID, err)
		return
	}
	if !changed {
		return
	}
	marked, err := p.store.MarkStaleBySourceHash(ctx, trackID, sourceFileHash)
	if err != nil {
		log.Printf("stems worker %d: failed to invalidate stems for replaced audio on track %d: %v", workerID, trackID, err)
		return
	}
	if marked > 0 {
		log.Printf("stems worker %d: track %d audio changed (%s -> %s); marked %d stem set(s) stale",
			workerID, trackID, previous, sourceFileHash, marked)
	}
}

func (p *WorkerPool) failJob(ctx context.Context, workerID int, job *Job, identity db.StemsIdentity, provenance json.RawMessage, cause error) {
	// A canceled run is shutdown, not a failed separation: leave the row in
	// `separating` so the next process's recovery sweep reclaims it instead of
	// burning the user's retry on our own restart.
	if ctx.Err() != nil || errors.Is(cause, context.Canceled) {
		log.Printf("stems worker %d: job %s canceled during shutdown; leaving row for recovery", workerID, job.ID)
		return
	}
	log.Printf("stems worker %d: job %s failed: %v", workerID, job.ID, cause)
	if err := p.store.MarkFailed(ctx, job.TrackID, identity, cause.Error(), provenance); err != nil {
		if errors.Is(err, db.ErrStemsResultSuperseded) {
			log.Printf("stems worker %d: failure for job %s was superseded; durable row untouched", workerID, job.ID)
		} else {
			log.Printf("stems worker %d: failed to record failure for job %s: %v", workerID, job.ID, err)
		}
	}
	p.updateJob(ctx, job.ID, JobStatusFailed, cause.Error())
}

func (p *WorkerPool) updateJob(ctx context.Context, jobID, status, errMsg string) {
	if err := p.queue.UpdateStatus(ctx, jobID, status, errMsg); err != nil {
		if errors.Is(err, ErrJobNotFound) || ctx.Err() != nil {
			return
		}
		log.Printf("stems worker pool: failed to publish %s for job %s: %v", status, jobID, err)
	}
}

// workerProvenance stamps the identity this build expects. It must match what
// the trigger recorded, otherwise the repository's expected_worker guards refuse
// the claim — which is exactly the protection that stops an overlapping deploy
// from writing another version's artifacts.
func workerProvenance(job *Job) json.RawMessage {
	provenance, err := json.Marshal(map[string]any{
		"expected_worker":         WorkerName,
		"expected_worker_version": WorkerVersion,
		"channel_set":             job.ChannelSet,
		"stem_model_version":      job.StemModelVersion,
		"trigger":                 "worker_pool",
	})
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return provenance
}
