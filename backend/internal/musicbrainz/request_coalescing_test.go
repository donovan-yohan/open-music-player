package musicbrainz

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCoalescedWaiterCancellationDoesNotCancelLeader(t *testing.T) {
	withFixtureClock(t, func(t *testing.T) {
		c := NewClient(nil)
		var calls atomic.Int32
		entered := make(chan struct{})
		release := make(chan struct{})
		var once sync.Once
		c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
			calls.Add(1)
			once.Do(func() { close(entered) })
			select {
			case <-release:
				return fixtureResponse(200, `{}`), nil
			case <-r.Context().Done():
				return nil, r.Context().Err()
			}
		})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		done := make(chan error, 1)
		go func() { _, err := c.doRequest(ctx, "https://coalesce.fixture.invalid/shared"); done <- err }()
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		waitCtx, waitCancel := context.WithCancel(ctx)
		observed := &waitObservedContext{Context: waitCtx, waiting: make(chan struct{})}
		waitDone := make(chan error, 1)
		go func() { _, err := c.doRequest(observed, "https://coalesce.fixture.invalid/shared"); waitDone <- err }()
		select {
		case <-observed.waiting:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		waitCancel()
		if err := <-waitDone; !errors.Is(err, context.Canceled) {
			t.Errorf("waiter cancellation=%v", err)
		}
		deadlineCtx, deadlineCancel := context.WithTimeout(ctx, 40*time.Millisecond)
		defer deadlineCancel()
		if _, err := c.doRequest(deadlineCtx, "https://coalesce.fixture.invalid/shared"); !errors.Is(err, context.DeadlineExceeded) {
			t.Errorf("coalesced waiter deadline=%v", err)
		}
		if calls.Load() != 1 {
			t.Errorf("waiter dispatched extra call: %d", calls.Load())
		}
		select {
		case err := <-done:
			t.Fatalf("waiter retired leader: %v", err)
		default:
		}
		close(release)
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		if _, err := c.doRequest(ctx, "https://coalesce.fixture.invalid/shared"); err != nil {
			t.Fatal(err)
		}
		if calls.Load() != 2 {
			t.Fatalf("completed request retained as hidden cache: calls=%d", calls.Load())
		}
		c.requestsMu.Lock()
		defer c.requestsMu.Unlock()
		if len(c.requests) != 0 {
			t.Fatalf("completed requests retained: %d", len(c.requests))
		}
	})
}

func TestConcurrentCachedMissesCoalesceRetriesAndDecodeIndependently(t *testing.T) {
	isolateFixtureBudgets(t)
	store := fixturePublicCache(t)
	c := NewClient(store)
	var calls atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		attempt := calls.Add(1)
		if attempt == 1 {
			close(entered)
			select {
			case <-release:
				return fixtureResponse(503, `{}`), nil
			case <-r.Context().Done():
				return nil, r.Context().Err()
			}
		}
		return fixtureResponse(200, `{"count":1,"recordings":[{"id":"r","first-release-date":"1984-05","artist-credit":[{"artist":{"id":"first","name":"First"}},{"artist":{"id":"second","name":"Second"}}]}]}`), nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	responses := make(chan *SearchResponse[TrackResult], 4)
	errs := make(chan error, 4)
	read := func(ctx context.Context) {
		resp, err := c.SearchTracks(ctx, "same", 10, 0, false)
		responses <- resp
		errs <- err
	}
	go read(ctx)
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	waiters := make([]*waitObservedContext, 3)
	for i := range waiters {
		waiters[i] = &waitObservedContext{Context: ctx, waiting: make(chan struct{})}
		go read(waiters[i])
	}
	for _, waiter := range waiters {
		select {
		case <-waiter.waiting:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	close(release)
	rows := make([]*SearchResponse[TrackResult], 0, 4)
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
		rows = append(rows, <-responses)
	}
	if calls.Load() != 2 {
		t.Fatalf("coalesced 503 retry used %d attempts, want 2", calls.Load())
	}
	for _, resp := range rows {
		if len(resp.Results) != 1 || resp.Results[0].FirstReleaseDate != "1984-05" || len(resp.Results[0].ArtistCredits) != 2 {
			t.Fatalf("lost shared metadata: %+v", resp)
		}
	}
	rows[0].Results[0].ArtistCredits[1].Name = "changed locally"
	if rows[1].Results[0].ArtistCredits[1].Name != "Second" {
		t.Fatal("coalesced callers share mutable DTO slices")
	}
	warm, err := c.SearchTracks(ctx, "same", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || warm.Results[0].ArtistCredits[1].Name != "Second" {
		t.Fatal("cached DTO mutated by another caller")
	}
}

func TestRequestCancellationOnFinalRetryRetainsContextError(t *testing.T) {
	withFixtureClock(t, func(t *testing.T) {
		c := NewClient(nil)
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		var attempts atomic.Int32
		c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
			if attempts.Add(1) == 4 {
				cancel()
				return nil, context.Canceled
			}
			return fixtureResponse(503, `{}`), nil
		})
		_, err := c.doRequest(ctx, "https://final-retry.fixture.invalid/a")
		if attempts.Load() != 4 {
			t.Fatalf("did not reach final attempt: %d, err=%v", attempts.Load(), err)
		}
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("final cancellation lost its context identity: %v", err)
		}
	})
}
