package musicbrainz

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestRadarCoalescedWaitersShareCanceledLeaderTakeover(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			withFixtureClock(t, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
				defer cancel()
				ownerCtx, ownerCancel := context.WithCancel(ctx)
				if mode == "deadline" {
					ownerCancel()
					ownerCtx, ownerCancel = context.WithTimeout(ctx, 250*time.Millisecond)
				}
				defer ownerCancel()
				client := NewClient(nil)
				entered, takeover, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
				var calls atomic.Int32
				client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
					if calls.Add(1) == 1 {
						close(entered)
						<-r.Context().Done()
						return nil, r.Context().Err()
					}
					close(takeover)
					select {
					case <-release:
						return fixtureResponse(200, `{"shared":true}`), nil
					case <-r.Context().Done():
						return nil, r.Context().Err()
					}
				})
				url := "https://takeover-" + mode + ".fixture.invalid/shared"
				ownerDone := make(chan error, 1)
				go func() { _, e := client.doRequest(WithRadarReadBudget(ownerCtx), url); ownerDone <- e }()
				select {
				case <-entered:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				type result struct {
					body string
					err  error
				}
				liveDone := make(chan result, 3)
				for i := 0; i < 3; i++ {
					waiter := &waitObservedContext{Context: WithRadarReadBudget(ctx), waiting: make(chan struct{})}
					go func() { b, e := client.doRequest(waiter, url); liveDone <- result{string(b), e} }()
					select {
					case <-waiter.waiting:
					case <-ctx.Done():
						t.Fatal(ctx.Err())
					}
				}
				canceled, cancelWaiter := context.WithCancel(ctx)
				waiter := &waitObservedContext{Context: WithRadarReadBudget(canceled), waiting: make(chan struct{})}
				canceledDone := make(chan error, 1)
				go func() { _, e := client.doRequest(waiter, url); canceledDone <- e }()
				select {
				case <-waiter.waiting:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				cancelWaiter()
				if e := <-canceledDone; !errors.Is(e, context.Canceled) {
					t.Fatalf("canceled waiter=%v", e)
				}
				if mode == "cancel" {
					ownerCancel()
				}
				if e := <-ownerDone; !errors.Is(e, ownerCtx.Err()) {
					t.Fatalf("owner error=%v want=%v", e, ownerCtx.Err())
				}
				select {
				case <-takeover:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				close(release)
				for i := 0; i < 3; i++ {
					r := <-liveDone
					if r.err != nil || r.body != `{"shared":true}` {
						t.Fatalf("live waiter result=%+v", r)
					}
				}
				if calls.Load() != 2 {
					t.Fatalf("takeover not coalesced: %d dispatches", calls.Load())
				}
				client.requestsMu.Lock()
				defer client.requestsMu.Unlock()
				if len(client.requests) != 0 {
					t.Fatal("completed takeover retained in active registry")
				}
			})
		})
	}
}

func TestRadarTakeoverRetainsLiveWaiterDeadline(t *testing.T) {
	withFixtureClock(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		owner, cancelOwner := context.WithCancel(ctx)
		defer cancelOwner()
		entered := make(chan struct{})
		var calls atomic.Int32
		client := NewClient(nil)
		client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
			if calls.Add(1) == 1 {
				close(entered)
			} else {
				got, ok := r.Context().Deadline()
				want, _ := ctx.Deadline()
				if !ok || !got.Equal(want) {
					t.Error("takeover renewed/removed original waiter deadline")
				}
			}
			<-r.Context().Done()
			return nil, r.Context().Err()
		})
		url := "https://takeover-deadline-retained.fixture.invalid/shared"
		ownerDone, waiterDone := make(chan error, 1), make(chan error, 1)
		go func() { _, e := client.doRequest(WithRadarReadBudget(owner), url); ownerDone <- e }()
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		waiter := &waitObservedContext{Context: WithRadarReadBudget(ctx), waiting: make(chan struct{})}
		go func() { _, e := client.doRequest(waiter, url); waiterDone <- e }()
		select {
		case <-waiter.waiting:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		cancelOwner()
		if e := <-ownerDone; !errors.Is(e, context.Canceled) {
			t.Fatal(e)
		}
		if e := <-waiterDone; !errors.Is(e, context.DeadlineExceeded) || calls.Load() != 2 {
			t.Fatalf("waiter deadline not retained: error=%v calls=%d", e, calls.Load())
		}
	})
}

func TestRadarTakeoverDoesNotRetryUnrelatedErrorsOrChangeOrdinaryMetadata(t *testing.T) {
	for _, mode := range []string{"provider", "transport-context-error", "ordinary-cancel"} {
		t.Run(mode, func(t *testing.T) {
			withFixtureClock(t, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
				defer cancel()
				ownerCtx, cancelOwner := context.WithCancel(ctx)
				defer cancelOwner()
				client := NewClient(nil)
				entered, release := make(chan struct{}), make(chan struct{})
				var calls atomic.Int32
				client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
					if calls.Add(1) == 1 {
						close(entered)
						select {
						case <-release:
						case <-r.Context().Done():
							return nil, r.Context().Err()
						}
					}
					if mode == "transport-context-error" {
						return nil, context.Canceled // The request owner's context is live.
					}
					return fixtureResponse(503, `{}`), nil
				})
				wrap := func(c context.Context) context.Context {
					if mode != "ordinary-cancel" {
						return WithRadarReadBudget(c)
					}
					return c
				}
				url := "https://no-takeover-" + mode + ".fixture.invalid/shared"
				ownerDone, waiterDone := make(chan error, 1), make(chan error, 1)
				go func() { _, e := client.doRequest(wrap(ownerCtx), url); ownerDone <- e }()
				select {
				case <-entered:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				waiter := &waitObservedContext{Context: wrap(ctx), waiting: make(chan struct{})}
				go func() { _, e := client.doRequest(waiter, url); waiterDone <- e }()
				select {
				case <-waiter.waiting:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				if mode == "ordinary-cancel" {
					cancelOwner()
				}
				close(release)
				a, b := <-ownerDone, <-waiterDone
				wantCalls := int32(2) // unchanged bounded one-retry ceiling
				if mode == "ordinary-cancel" {
					wantCalls = 1
				}
				if a == nil || b == nil || a.Error() != b.Error() || calls.Load() != wantCalls {
					t.Fatalf("unrelated error retried/changed: owner=%v waiter=%v calls=%d", a, b, calls.Load())
				}
			})
		})
	}
}
