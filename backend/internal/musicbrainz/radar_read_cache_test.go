package musicbrainz

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRadarBudgetWarmPublicCacheAndOversizedUnboundedControl(t *testing.T) {
	ctx := context.Background()
	store := fixturePublicCache(t)
	c := NewClient(store)
	var calls atomic.Int32
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return fixtureResponse(200, `{"count":1,"recordings":[{"id":"33333333-3333-4333-8333-333333333333","title":"public","first-release-date":"2026-11-12","artist-credit":[{"artist":{"id":"11111111-1111-4111-8111-111111111111","name":"Synthetic"}}]}]}`), nil
	})
	for _, readCtx := range []context.Context{WithRadarReadBudget(ctx), ctx, WithRadarReadBudget(ctx)} {
		p, err := c.SearchTracks(readCtx, "public", 100, 0, false)
		if err != nil || len(p.Results) != 1 || p.Results[0].FirstReleaseDate != "2026-11-12" {
			t.Fatalf("public cache failed %+v %v", p, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("public cache split into private/budget namespaces %d", calls.Load())
	}
	oversized, _ := json.Marshal(SearchResponse[TrackResult]{Results: []TrackResult{{MBID: "fixture", Title: strings.Repeat("x", 1048577)}}, Total: 1, Limit: 100})
	if err := store.Set(ctx, c.buildCacheKey("recording", "large", 100, 0), string(oversized), time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := c.SearchTracks(WithRadarReadBudget(ctx), "large", 100, 0, false); err == nil {
		t.Fatal("oversized cache entered bounded decode")
	}
	if p, err := c.SearchTracks(ctx, "large", 100, 0, false); err != nil || len(p.Results[0].Title) != 1048577 {
		t.Fatalf("ordinary cache default changed %v", err)
	}
	if calls.Load() != 1 {
		t.Fatal("cache control performed network")
	}
}
func TestRadarBudgetFlightIsolationBeforeLeaderRelease(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var starts atomic.Int32
	c := NewClient(nil)
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		if starts.Add(1) == 1 {
			close(entered)
			<-release
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(strings.Repeat("x", 1048577)))}, nil
	})
	ordinary := make(chan error, 1)
	go func() {
		_, err := c.doRequest(context.Background(), "https://isolated-radar.invalid/q")
		ordinary <- err
	}()
	<-entered
	bounded := make(chan error, 1)
	go func() {
		_, err := c.doRequest(WithRadarReadBudget(context.Background()), "https://isolated-radar.invalid/q")
		bounded <- err
	}()
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	isolated := false
wait:
	for {
		c.requestsMu.Lock()
		n := len(c.requests)
		c.requestsMu.Unlock()
		if n == 2 {
			isolated = true
			break
		}
		select {
		case <-deadline.C:
			break wait
		case <-ticker.C:
		}
	}
	close(release)
	a, b := <-ordinary, <-bounded
	if !isolated || starts.Load() != 2 || a != nil || b == nil {
		t.Fatalf("budget policies coalesced isolated=%v starts=%d ordinary=%v bounded=%v", isolated, starts.Load(), a, b)
	}
}
