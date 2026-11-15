package musicbrainz_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type observingContext struct {
	context.Context
	doneRead chan struct{}
	once     sync.Once
}

func (c *observingContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.doneRead) })
	return c.Context.Done()
}

func TestConfiguredSearchAndMatcherCoalesceOverlappingMiss(t *testing.T) {
	original := http.DefaultTransport
	var calls atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	http.DefaultTransport = controlledTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "musicbrainz.org" {
			return nil, fmt.Errorf("unexpected provider %s", r.URL)
		}
		calls.Add(1)
		once.Do(func() { close(entered) })
		select {
		case <-release:
		case <-r.Context().Done():
			return nil, r.Context().Err()
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"count":1,"recordings":[{"id":"rec","title":"Song","length":240000,"score":100,"artist-credit":[{"artist":{"id":"first","name":"First"}}]}]}`))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = original })
	c := musicbrainz.NewClient(nil)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	errs := make(chan error, 5)
	go func() {
		out, err := matcher.NewMatcher(c).Match(ctx, matcher.TrackMetadata{Title: "First - Song", DurationMs: 240000})
		if err == nil && (!out.Verified || out.BestMatch.MBID != "rec") {
			err = fmt.Errorf("bad match: %+v", out)
		}
		errs <- err
	}()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	waiters := make([]*observingContext, 4)
	for i := 0; i < 4; i++ {
		waiters[i] = &observingContext{Context: ctx, doneRead: make(chan struct{})}
		go func(waiter context.Context) {
			resp, err := c.SearchTracks(waiter, `recording:"Song" AND artist:"First"`, 10, 0, false)
			if err == nil && (len(resp.Results) != 1 || resp.Results[0].MBID != "rec") {
				err = fmt.Errorf("bad search: %+v", resp)
			}
			errs <- err
		}(waiters[i])
	}
	// Positively observe every follower at its cancellable wait before releasing
	// the transport. No scheduling sleep or persistent cache can fake sharing.
	for _, waiter := range waiters {
		select {
		case <-waiter.doneRead:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	close(release)
	for i := 0; i < 5; i++ {
		if err := <-errs; err != nil {
			t.Error(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("simultaneous search/matcher miss dispatched %d requests, want 1", calls.Load())
	}
}
