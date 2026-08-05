package stems

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// newRedisIntegrationQueue returns a queue backed by a real Redis. It never
// flushes the database: only keys this test wrote are removed, so it is safe to
// point at a shared development instance.
func newRedisIntegrationQueue(t *testing.T, maxDepth int) (*Queue, *redis.Client, context.Context) {
	t.Helper()

	redisURL := strings.TrimSpace(os.Getenv("OMP_REDIS_TEST_URL"))
	if redisURL == "" {
		t.Skip("set OMP_REDIS_TEST_URL to run the stems queue Redis integration test")
	}
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		t.Fatalf("parse redis URL: %v", err)
	}
	client := redis.NewClient(opts)
	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Skipf("redis unavailable at %s: %v", redisURL, err)
	}
	t.Cleanup(func() { _ = client.Close() })

	cleanup := func() {
		_ = client.Del(ctx, keyJobQueue).Err()
		iter := client.Scan(ctx, 0, keyJobStatus+"*", 100).Iterator()
		var keys []string
		for iter.Next(ctx) {
			keys = append(keys, iter.Val())
		}
		if len(keys) > 0 {
			_ = client.Del(ctx, keys...).Err()
		}
	}
	cleanup()
	t.Cleanup(cleanup)

	return NewQueueWithClient(client, QueueConfig{MaxDepth: maxDepth}), client, ctx
}

func TestQueueAgainstRedisEnqueuesDedupesAndBackpressures(t *testing.T) {
	queue, client, ctx := newRedisIntegrationQueue(t, 2)

	job, created, err := queue.Enqueue(ctx, testEnqueueRequest(9001))
	if err != nil || !created {
		t.Fatalf("first enqueue: created=%v err=%v", created, err)
	}
	if _, created, err := queue.Enqueue(ctx, testEnqueueRequest(9001)); err != nil || created {
		t.Fatalf("repeat enqueue: created=%v err=%v, want idempotent no-op", created, err)
	}
	depth, err := queue.QueueLength(ctx)
	if err != nil {
		t.Fatalf("queue length: %v", err)
	}
	if depth != 1 {
		t.Fatalf("queue length = %d, want 1", depth)
	}

	if _, created, err := queue.Enqueue(ctx, testEnqueueRequest(9002)); err != nil || !created {
		t.Fatalf("second job enqueue: created=%v err=%v", created, err)
	}
	if _, _, err := queue.Enqueue(ctx, testEnqueueRequest(9003)); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("third job error = %v, want ErrQueueFull", err)
	}

	position, err := queue.QueuePosition(ctx, job.ID)
	if err != nil {
		t.Fatalf("queue position: %v", err)
	}
	if position != 0 {
		t.Fatalf("first job position = %d, want 0 (next served)", position)
	}

	dequeued, err := queue.Dequeue(ctx, time.Second)
	if err != nil {
		t.Fatalf("dequeue: %v", err)
	}
	if dequeued.ID != job.ID {
		t.Fatalf("dequeued %q, want FIFO order starting at %q", dequeued.ID, job.ID)
	}
	if err := queue.UpdateStatus(ctx, dequeued.ID, JobStatusComplete, ""); err != nil {
		t.Fatalf("update status: %v", err)
	}
	stored, err := queue.GetJob(ctx, dequeued.ID)
	if err != nil {
		t.Fatalf("get job: %v", err)
	}
	if stored.Status != JobStatusComplete {
		t.Fatalf("status = %q, want %q", stored.Status, JobStatusComplete)
	}

	// The stems queue must own an isolated namespace: nothing it wrote may land
	// on the download worker's list, which is what keeps a stems backlog from
	// starving downloads and analysis.
	for _, jobID := range []string{job.ID, JobID(9002, ChannelSetStems5Hybrid, StemModelVersionStems5)} {
		_, err := client.LPos(ctx, "download:queue", jobID, redis.LPosArgs{}).Result()
		if !errors.Is(err, redis.Nil) {
			t.Fatalf("stems job %q leaked into download:queue (err=%v)", jobID, err)
		}
		if err := client.Get(ctx, "download:job:"+jobID).Err(); !errors.Is(err, redis.Nil) {
			t.Fatalf("stems job %q leaked into the download job namespace (err=%v)", jobID, err)
		}
	}
}
