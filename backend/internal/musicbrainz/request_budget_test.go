package musicbrainz

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type waitObservedContext struct {
	context.Context
	once    sync.Once
	waiting chan struct{}
}

func (c *waitObservedContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

func requireStartSpacing(t *testing.T, starts []time.Time) {
	t.Helper()
	for i := 1; i < len(starts); i++ {
		if gap := starts[i].Sub(starts[i-1]); gap < time.Second {
			t.Errorf("starts %d/%d only %s apart, want >= 1s", i-1, i, gap)
		}
	}
}

func TestRequestBudgetIncludesRedirectDispatch(t *testing.T) {
	var mu sync.Mutex
	var starts []time.Time
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		starts = append(starts, time.Now())
		mu.Unlock()
		if r.URL.Path == "/original" {
			http.Redirect(w, r, "/canonical", http.StatusMovedPermanently)
			return
		}
		fmt.Fprint(w, `{"id":"canonical"}`)
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	body, err := NewClient(nil).doRequest(ctx, srv.URL+"/original")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "canonical") {
		t.Fatalf("redirect conversion changed: %s", body)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(starts) != 2 {
		t.Fatalf("redirect dispatches=%d", len(starts))
	}
	requireStartSpacing(t, starts)
}

func TestRequestBudgetIncludesRetriesAndCompetingClient(t *testing.T) {
	var mu sync.Mutex
	var starts []time.Time
	var retryCalls int
	first := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		starts = append(starts, time.Now())
		status := 200
		if r.URL.Path == "/retry" {
			retryCalls++
			switch retryCalls {
			case 1:
				status = 503
				close(first)
			case 2:
				status = 429
			}
		}
		mu.Unlock()
		w.WriteHeader(status)
		fmt.Fprint(w, `{}`)
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	errs := make(chan error, 2)
	go func() { _, err := NewClient(nil).doRequest(ctx, srv.URL+"/retry"); errs <- err }()
	select {
	case <-first:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	go func() { _, err := NewClient(nil).doRequest(ctx, srv.URL+"/compete"); errs <- err }()
	for i := 0; i < 2; i++ {
		if err := <-errs; err != nil {
			t.Error(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(starts) != 4 || retryCalls != 3 {
		t.Fatalf("retry semantics changed: starts=%d retry attempts=%d", len(starts), retryCalls)
	}
	requireStartSpacing(t, starts)
}

func TestRequestBudgetWaitHonorsCancellationAndDeadline(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			entered := make(chan struct{})
			release := make(chan struct{})
			defer close(release)
			var calls atomic.Int32
			c := NewClient(nil)
			c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
				calls.Add(1)
				close(entered)
				select {
				case <-release:
					return fixtureResponse(200, `{}`), nil
				case <-r.Context().Done():
					return nil, r.Context().Err()
				}
			})
			// Each subtest has a fresh origin, so no prior budget state is assumed.
			srv := httptest.NewServer(http.NotFoundHandler())
			defer srv.Close()
			ownerCtx, ownerCancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer ownerCancel()
			ownerDone := make(chan error, 1)
			go func() { _, err := c.doRequest(ownerCtx, srv.URL+"/owner"); ownerDone <- err }()
			select {
			case <-entered:
			case <-ownerCtx.Done():
				t.Fatal(ownerCtx.Err())
			}
			ctx, cancel := context.WithCancel(context.Background())
			want := context.Canceled
			if mode == "deadline" {
				cancel()
				ctx, cancel = context.WithTimeout(context.Background(), 40*time.Millisecond)
				want = context.DeadlineExceeded
			}
			waitDone := make(chan error, 1)
			observed := &waitObservedContext{Context: ctx, waiting: make(chan struct{})}
			go func() { _, err := c.doRequest(observed, srv.URL+"/waiter"); waitDone <- err }()
			select {
			case <-observed.waiting:
			case <-ownerCtx.Done():
				t.Fatal("waiter never reached cancellation boundary")
			}
			if mode == "cancel" {
				cancel()
			}
			defer cancel()
			select {
			case err := <-waitDone:
				if !errors.Is(err, want) {
					t.Errorf("error=%v, want %v", err, want)
				}
			case <-ownerCtx.Done():
				t.Fatal("waiting cancellation blocked")
			}
			if calls.Load() != 1 {
				t.Errorf("canceled waiter dispatched: calls=%d", calls.Load())
			}
			ownerCancel()
			if err := <-ownerDone; !errors.Is(err, context.Canceled) {
				t.Errorf("owner cancel=%v", err)
			}
		})
	}
}

func TestCacheHitDoesNotWaitForProviderBudget(t *testing.T) {
	store := fixturePublicCache(t)
	c := NewClient(store)
	ctx := context.Background()
	if err := store.Set(ctx, c.buildCacheKey("recording", "warm", 20, 0), `{"results":[{"mbid":"warm","firstReleaseDate":"1984"}],"total":1}`, time.Hour); err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{})
	release := make(chan struct{})
	defer close(release)
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		close(entered)
		select {
		case <-release:
			return fixtureResponse(200, `{}`), nil
		case <-r.Context().Done():
			return nil, r.Context().Err()
		}
	})
	ownerCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := c.SearchArtists(ownerCtx, "cold", 1, 0, false); done <- err }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("cold provider request never dispatched")
	}
	warmCtx, warmCancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer warmCancel()
	resp, err := c.SearchTracks(warmCtx, "warm", 20, 0, false)
	if err != nil || len(resp.Results) != 1 || resp.Results[0].MBID != "warm" {
		t.Errorf("cache hit waited behind provider: resp=%+v err=%v", resp, err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("cold owner cancellation=%v", err)
	}
}

func TestRequestBudgetIndependentOrigins(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	defer close(release)
	c := NewClient(nil)
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "first.fixture.invalid" {
			close(entered)
			select {
			case <-release:
			case <-r.Context().Done():
				return nil, r.Context().Err()
			}
		}
		return fixtureResponse(200, `{}`), nil
	})
	ownerCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := c.doRequest(ownerCtx, "https://first.fixture.invalid/a"); done <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("first origin never entered")
	}
	ctx, stop := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer stop()
	if _, err := c.doRequest(ctx, "https://second.fixture.invalid/b"); err != nil {
		t.Errorf("independent origin waited: %v", err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("first cancel=%v", err)
	}
}
