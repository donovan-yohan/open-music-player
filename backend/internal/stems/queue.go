package stems

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	// Redis key prefixes. These are a distinct namespace from download:* and are
	// consumed by a distinct worker pool, which is what makes queue isolation
	// provable: a saturated stems queue cannot occupy a download worker.
	keyJobQueue  = "stems:queue"
	keyJobStatus = "stems:job:"
	keyProgress  = "stems:progress"

	defaultBlockTimeout = 5 * time.Second

	// DefaultMaxDepth bounds visible backlog. Separation is minutes-per-track at
	// concurrency 1, so an unbounded queue would promise hours of work the host
	// cannot honor.
	DefaultMaxDepth = 32
)

var (
	ErrJobNotFound = errors.New("stems job not found")
	ErrQueueEmpty  = errors.New("stems queue is empty")
	// ErrQueueFull is reject-when-full backpressure. Callers must surface it
	// (429) rather than blocking or dropping: a silently dropped separation
	// request looks identical to a stuck one from the client's side.
	ErrQueueFull = errors.New("stems queue is full")
)

// RedisClient is the narrow slice of *redis.Client this queue uses. It exists so
// the queue's ordering and backpressure rules can be unit-tested deterministically
// against an in-memory fake, with no Redis in the loop.
type RedisClient interface {
	LLen(ctx context.Context, key string) *redis.IntCmd
	LPos(ctx context.Context, key string, value string, args redis.LPosArgs) *redis.IntCmd
	LPush(ctx context.Context, key string, values ...interface{}) *redis.IntCmd
	BRPop(ctx context.Context, timeout time.Duration, keys ...string) *redis.StringSliceCmd
	Get(ctx context.Context, key string) *redis.StringCmd
	Set(ctx context.Context, key string, value interface{}, expiration time.Duration) *redis.StatusCmd
	Del(ctx context.Context, keys ...string) *redis.IntCmd
	Publish(ctx context.Context, channel string, message interface{}) *redis.IntCmd
	Close() error
}

// QueueConfig configures the stems queue class.
type QueueConfig struct {
	// MaxDepth is the reject-when-full threshold. Zero selects DefaultMaxDepth.
	MaxDepth int
}

// Queue manages stem separation jobs on their own Redis list.
type Queue struct {
	client   RedisClient
	maxDepth int
	owned    bool
}

// EnqueueRequest is the caller's view of a separation job.
type EnqueueRequest struct {
	TrackID          int64
	ChannelSet       string
	StemModelVersion string
	StorageKey       string
	SourceFileHash   string
}

func (r EnqueueRequest) validate() error {
	if r.TrackID <= 0 {
		return errors.New("stems job requires a positive track id")
	}
	if r.ChannelSet == "" || r.StemModelVersion == "" {
		return errors.New("stems job requires a channel set and stem model version")
	}
	return nil
}

// NewQueue connects to Redis and returns a stems queue.
func NewQueue(redisURL string, cfg QueueConfig) (*Queue, error) {
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse redis URL: %w", err)
	}
	client := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("failed to connect to redis: %w", err)
	}

	queue := NewQueueWithClient(client, cfg)
	queue.owned = true
	return queue, nil
}

// NewQueueWithClient wraps an existing client (tests, or a shared connection).
// Close is a no-op for injected clients; the owner keeps the lifecycle.
func NewQueueWithClient(client RedisClient, cfg QueueConfig) *Queue {
	maxDepth := cfg.MaxDepth
	if maxDepth <= 0 {
		maxDepth = DefaultMaxDepth
	}
	return &Queue{client: client, maxDepth: maxDepth}
}

// MaxDepth returns the configured reject-when-full threshold.
func (q *Queue) MaxDepth() int {
	return q.maxDepth
}

// Close releases the Redis connection when this queue owns it.
func (q *Queue) Close() error {
	if q == nil || q.client == nil || !q.owned {
		return nil
	}
	return q.client.Close()
}

// Enqueue publishes a separation job, returning the job and whether it was newly
// created. It is idempotent on the deterministic job ID: a request whose job is
// already queued or otherwise non-terminal returns that job with created=false
// (restoring a lost list entry if Redis dropped it), so repeated triggers from
// the client cannot multiply work.
//
// When the queue is at MaxDepth it returns ErrQueueFull instead of blocking or
// silently dropping.
func (q *Queue) Enqueue(ctx context.Context, req EnqueueRequest) (*Job, bool, error) {
	if err := req.validate(); err != nil {
		return nil, false, err
	}
	jobID := JobID(req.TrackID, req.ChannelSet, req.StemModelVersion)

	existing, err := q.GetJob(ctx, jobID)
	if err != nil && !errors.Is(err, ErrJobNotFound) {
		return nil, false, err
	}
	if err == nil && !existing.IsTerminal() {
		_, positionErr := q.client.LPos(ctx, keyJobQueue, jobID, redis.LPosArgs{}).Result()
		switch {
		case positionErr == nil:
			return existing, false, nil
		case errors.Is(positionErr, redis.Nil):
			// The durable request exists but the list entry was lost (restart,
			// eviction). Restore it rather than creating a second job.
			if err := q.client.LPush(ctx, keyJobQueue, jobID).Err(); err != nil {
				return nil, false, fmt.Errorf("restore queued stems job: %w", err)
			}
			return existing, false, nil
		default:
			return nil, false, fmt.Errorf("check queued stems job: %w", positionErr)
		}
	}

	// Depth check then push is intentionally not atomic. The race is benign and
	// bounded: N concurrent enqueues can overshoot MaxDepth by at most N-1
	// entries, and the invariant we need is bounded, visible backpressure rather
	// than an exact cap. A Lua script would buy exactness at the cost of a second
	// code path for a single-writer API route.
	depth, err := q.client.LLen(ctx, keyJobQueue).Result()
	if err != nil {
		return nil, false, fmt.Errorf("measure stems queue depth: %w", err)
	}
	if depth >= int64(q.maxDepth) {
		return nil, false, ErrQueueFull
	}

	now := time.Now().UTC()
	job := &Job{
		ID:               jobID,
		TrackID:          req.TrackID,
		ChannelSet:       req.ChannelSet,
		StemModelVersion: req.StemModelVersion,
		StorageKey:       req.StorageKey,
		SourceFileHash:   req.SourceFileHash,
		Status:           JobStatusQueued,
		RetryCount:       0,
		CreatedAt:        now,
		UpdatedAt:        now,
	}
	if err := q.saveJob(ctx, job); err != nil {
		return nil, false, err
	}
	if err := q.client.LPush(ctx, keyJobQueue, job.ID).Err(); err != nil {
		_ = q.client.Del(ctx, keyJobStatus+job.ID).Err()
		return nil, false, fmt.Errorf("failed to enqueue stems job: %w", err)
	}
	return job, true, nil
}

// Dequeue blocks for the next job. Redis delivery is at-most-once here; the
// track_stems row is what makes a lost delivery recoverable.
func (q *Queue) Dequeue(ctx context.Context, timeout time.Duration) (*Job, error) {
	if timeout == 0 {
		timeout = defaultBlockTimeout
	}
	result, err := q.client.BRPop(ctx, timeout, keyJobQueue).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrQueueEmpty
		}
		return nil, fmt.Errorf("failed to dequeue stems job: %w", err)
	}
	if len(result) < 2 {
		return nil, ErrQueueEmpty
	}
	return q.GetJob(ctx, result[1])
}

// GetJob loads a job by its deterministic ID.
func (q *Queue) GetJob(ctx context.Context, jobID string) (*Job, error) {
	data, err := q.client.Get(ctx, keyJobStatus+jobID).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrJobNotFound
		}
		return nil, fmt.Errorf("failed to get stems job: %w", err)
	}
	var job Job
	if err := json.Unmarshal([]byte(data), &job); err != nil {
		return nil, fmt.Errorf("failed to unmarshal stems job: %w", err)
	}
	return &job, nil
}

// UpdateStatus records delivery state and publishes a progress event.
func (q *Queue) UpdateStatus(ctx context.Context, jobID, status, errMsg string) error {
	job, err := q.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	job.Status = status
	job.Error = errMsg
	job.UpdatedAt = time.Now().UTC()
	if err := q.saveJob(ctx, job); err != nil {
		return err
	}
	return q.publishProgress(ctx, job)
}

// QueueLength returns the number of jobs waiting.
func (q *Queue) QueueLength(ctx context.Context) (int64, error) {
	return q.client.LLen(ctx, keyJobQueue).Result()
}

// QueuePosition returns how many jobs are ahead of jobID (0 means next served),
// or -1 when the job is not waiting in the list. Jobs are LPUSHed and BRPOPed,
// so list index counts from the newest end and must be inverted.
func (q *Queue) QueuePosition(ctx context.Context, jobID string) (int64, error) {
	index, err := q.client.LPos(ctx, keyJobQueue, jobID, redis.LPosArgs{}).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return -1, nil
		}
		return -1, fmt.Errorf("read stems queue position: %w", err)
	}
	depth, err := q.client.LLen(ctx, keyJobQueue).Result()
	if err != nil {
		return -1, fmt.Errorf("measure stems queue depth: %w", err)
	}
	// Depth and index are read separately, so a concurrent pop can make the
	// arithmetic negative. Clamp instead of reporting an impossible position.
	position := depth - 1 - index
	if position < 0 {
		position = 0
	}
	return position, nil
}

func (q *Queue) saveJob(ctx context.Context, job *Job) error {
	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("failed to marshal stems job: %w", err)
	}
	return q.client.Set(ctx, keyJobStatus+job.ID, data, 0).Err()
}

func (q *Queue) publishProgress(ctx context.Context, job *Job) error {
	data, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("failed to marshal stems progress event: %w", err)
	}
	return q.client.Publish(ctx, fmt.Sprintf("%s:%d", keyProgress, job.TrackID), data).Err()
}
