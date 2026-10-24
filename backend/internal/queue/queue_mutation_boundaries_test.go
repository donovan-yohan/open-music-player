package queue

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// Invalidate WATCH after each real GET without inventing Redis responses.
type queueConflictHook struct {
	other *Service
	user  string
	reads atomic.Int32
	err   error
}

func (h *queueConflictHook) DialHook(next redis.DialHook) redis.DialHook { return next }
func (h *queueConflictHook) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (h *queueConflictHook) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		err := next(ctx, cmd)
		if cmd.Name() == "get" {
			h.reads.Add(1)
			h.err = h.other.client.Expire(ctx, h.other.queueKey(h.user), queueTTL).Err()
		}
		return err
	}
}

func TestRedisQueueMutationBoundaries(t *testing.T) {
	url := isolatedQueueRedis(t)
	ctx := context.Background()
	t.Run("bounded conflicts leave committed value untouched", func(t *testing.T) {
		s, other := queueTestService(t, url), queueTestService(t, url)
		user := uuid.NewString()
		if _, err := other.AddToQueue(ctx, user, 1, "last"); err != nil {
			t.Fatal(err)
		}
		hook := &queueConflictHook{other: other, user: user}
		s.client.AddHook(hook)
		state, err := s.AddToQueue(ctx, user, 2, "last")
		if hook.err != nil {
			t.Fatal(hook.err)
		}
		if !errors.Is(err, redis.TxFailedErr) || state != nil || hook.reads.Load() != maxQueueMutationAttempts {
			t.Fatalf("conflict limit: state=%+v err=%v reads=%d want=%d", state, err, hook.reads.Load(), maxQueueMutationAttempts)
		}
		if got := queueTrackIDs(t, other, user); got != "1" {
			t.Fatalf("failed mutation committed: %q", got)
		}
	})
	t.Run("canceled mutation does not write", func(t *testing.T) {
		s := queueTestService(t, url)
		user := uuid.NewString()
		canceled, cancel := context.WithCancel(ctx)
		cancel()
		state, err := s.AddToQueue(canceled, user, 1, "last")
		if state != nil || !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled mutation: %+v %v", state, err)
		}
		if exists := s.client.Exists(ctx, s.queueKey(user)).Val(); exists != 0 {
			t.Fatal("canceled mutation created queue")
		}
	})
	t.Run("no ops and validation preserve value and TTL", func(t *testing.T) {
		s := queueTestService(t, url)
		user := uuid.NewString()
		state, err := s.EnsureSourceCandidateWithID(ctx, user, "source", SourceCandidate{}, "job", "last")
		if err != nil {
			t.Fatal(err)
		}
		if err := s.client.Expire(ctx, s.queueKey(user), time.Hour).Err(); err != nil {
			t.Fatal(err)
		}
		before := s.client.Get(ctx, s.queueKey(user)).Val()
		if _, err := s.EnsureSourceCandidateWithID(ctx, user, "source", SourceCandidate{}, "job", "invalid"); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ReorderQueueItem(ctx, user, state.Items[0].ID, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := s.AddToQueue(ctx, user, 9, "999"); !errors.Is(err, ErrInvalidPosition) {
			t.Fatalf("invalid insert: %v", err)
		}
		if _, err := s.RemoveQueueItem(ctx, user, "missing"); !errors.Is(err, ErrTrackNotFound) {
			t.Fatalf("missing ID: %v", err)
		}
		if after := s.client.Get(ctx, s.queueKey(user)).Val(); after != before {
			t.Fatalf("no-op/validation wrote queue: %s", after)
		}
		ttl, err := s.client.TTL(ctx, s.queueKey(user)).Result()
		if err != nil || ttl > time.Hour || ttl < 59*time.Minute {
			t.Fatalf("no-op TTL: %v %v", ttl, err)
		}
		if _, err := s.AddToQueue(ctx, user, 9, "last"); err != nil {
			t.Fatal(err)
		}
		ttl, err = s.client.TTL(ctx, s.queueKey(user)).Result()
		if err != nil || ttl > queueTTL || ttl < queueTTL-time.Minute {
			t.Fatalf("write TTL: %v %v", ttl, err)
		}
		if err := s.ClearQueue(ctx, user); err != nil {
			t.Fatal(err)
		}
		if exists := s.client.Exists(ctx, s.queueKey(user)).Val(); exists != 0 {
			t.Fatal("clear did not delete queue key")
		}
	})
	t.Run("same ID fan in produces one entry", func(t *testing.T) {
		const writers = 12
		user := uuid.NewString()
		services := make([]*Service, writers)
		for i := range services {
			services[i] = queueTestService(t, url)
		}
		start := make(chan struct{})
		errs := make(chan error, writers)
		var group sync.WaitGroup
		for i, s := range services {
			group.Add(1)
			go func(i int, s *Service) {
				defer group.Done()
				<-start
				_, err := s.EnsureSourceCandidateWithID(ctx, user, "stable", SourceCandidate{}, uuid.NewString(), "last")
				errs <- err
			}(i, s)
		}
		close(start)
		group.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				t.Fatal(err)
			}
		}
		if got := queueTrackIDs(t, services[0], user); got != "stable" {
			t.Fatalf("ensure duplicated stable ID: %q", got)
		}
	})
	t.Run("concurrent removed ID is not a neighbor", func(t *testing.T) {
		for _, reorder := range []bool{false, true} {
			s, other := queueTestService(t, url), queueTestService(t, url)
			user := uuid.NewString()
			seed, err := other.AddMultipleToQueue(ctx, user, []int64{1, 2, 3}, "last")
			if err != nil {
				t.Fatal(err)
			}
			target := seed.Items[1].ID
			err = whileQueueReadPaused(t, s, func() error {
				var err error
				if reorder {
					_, err = s.ReorderQueueItem(ctx, user, target, 0)
				} else {
					_, err = s.RemoveQueueItem(ctx, user, target)
				}
				return err
			}, func() {
				if _, err := other.RemoveQueueItem(ctx, user, target); err != nil {
					t.Fatal(err)
				}
			})
			if !errors.Is(err, ErrTrackNotFound) {
				t.Fatalf("removed ID mutation err = %v", err)
			}
			if got := queueTrackIDs(t, other, user); got != "1,3" {
				t.Fatalf("mutation affected neighbor: %q", got)
			}
		}
	})
	t.Run("clear retries over a concurrent add", func(t *testing.T) {
		s, other := queueTestService(t, url), queueTestService(t, url)
		user := uuid.NewString()
		if _, err := other.AddToQueue(ctx, user, 1, "last"); err != nil {
			t.Fatal(err)
		}
		err := whileQueueReadPaused(t, s, func() error { return s.ClearQueue(ctx, user) }, func() {
			if _, err := other.AddToQueue(ctx, user, 2, "last"); err != nil {
				t.Fatal(err)
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		if got := queueTrackIDs(t, other, user); got != "" {
			t.Fatalf("clear did not delete latest queue: %q", got)
		}
	})
	t.Run("retry resets failed fields on stable item", func(t *testing.T) {
		s := queueTestService(t, url)
		user := uuid.NewString()
		state, err := s.EnsureSourceCandidateWithID(ctx, user, "source", SourceCandidate{}, "job", "last")
		if err != nil {
			t.Fatal(err)
		}
		state.Items[0].PlaybackState = "failed"
		state.Items[0].Progress = 45
		state.Items[0].Error = "download failed"
		state.Items[0].CanRetry = true
		data, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		if err := s.client.Set(ctx, s.queueKey(user), data, queueTTL).Err(); err != nil {
			t.Fatal(err)
		}
		result, jobID, err := s.RetryQueueItem(ctx, user, "source")
		if err != nil {
			t.Fatal(err)
		}
		item := result.Items[0]
		if item.ID != "source" || jobID != "job" || item.PlaybackState != "queued" || item.Progress != 0 || item.Error != "" || item.CanPlay || item.CanRetry || !item.CanRemove {
			t.Fatalf("retry compatibility: item=%+v job=%s", item, jobID)
		}
		persisted, err := s.GetQueue(ctx, user)
		if err != nil {
			t.Fatal(err)
		}
		if persisted.Items[0].PlaybackState != "queued" || persisted.Items[0].Error != "" {
			t.Fatalf("retry did not persist: %+v", persisted)
		}
	})
}
