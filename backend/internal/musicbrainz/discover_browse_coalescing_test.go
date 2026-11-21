package musicbrainz

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

var discoverFixtureOrigin atomic.Uint64

func TestDiscoverBrowseCoalescesThroughBodyAndCacheWrite(t *testing.T) {
	for _, tc := range []struct {
		name, path, body string
		maxBytes         int
		fetch            func(*Client, context.Context, string) ([]byte, error)
	}{
		{"small_page", "/ws/2/release-group", discoverEmptyGroups, discoverBrowseMaxBytes, (*Client).requestWithRetry},
		{"tracklist", "/ws/2/release/" + browseEdition, `{` + discoverFixtureRelease + `,"title":"Fixture","media":[]}`, discoverTracklistMaxBytes, (*Client).fetchDiscoverTracklist},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var calls, reads, writes atomic.Int32
				var mu sync.Mutex
				cache := make(map[string]string)
				bodyEntered, releaseBody := make(chan struct{}), make(chan struct{})
				setEntered, releaseSet := make(chan struct{}), make(chan struct{})
				resumeWaiter := make(chan struct{})
				openBody := sync.OnceFunc(func() { close(releaseBody) })
				openSet := sync.OnceFunc(func() { close(releaseSet) })
				openWaiter := sync.OnceFunc(func() { close(resumeWaiter) })
				defer openBody()
				defer openSet()
				defer openWaiter()
				// Hold this test-local SET explicitly, independent of Redis's
				// socket deadline. The fake clock also removes scheduler timing.
				store := discoverFixtureCache{
					get: func(_ context.Context, key string) (string, bool) {
						reads.Add(1)
						mu.Lock()
						defer mu.Unlock()
						v, ok := cache[key]
						return v, ok
					},
					set: func(ctx context.Context, key, value string, _ time.Duration) {
						if writes.Add(1) == 1 {
							close(setEntered)
							select {
							case <-releaseSet:
							case <-ctx.Done():
								return
							}
						}
						mu.Lock()
						cache[key] = value
						mu.Unlock()
					},
				}
				client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
					if req.Method != http.MethodGet || req.URL.Path != tc.path || !interactiveCatalogRead(req.Context()) {
						t.Errorf("unexpected provider request/policy: %s %s", req.Method, req.URL)
					}
					resp := fixtureResponse(http.StatusOK, tc.body)
					if calls.Add(1) == 1 {
						resp.Body = &discoverHeldBody{ReadCloser: resp.Body, entered: bodyEntered, release: releaseBody}
					}
					return resp, nil
				}))
				// Give each fake-clock bubble its own key in the real pacer.
				url := fmt.Sprintf("https://browse-%d.fixture.invalid%s", discoverFixtureOrigin.Add(1), tc.path)
				type payload map[string]json.RawMessage
				read := func(ctx context.Context) (*payload, error) {
					return readDiscoverBrowseWithCache(ctx, client, store, url, tc.maxBytes, searchTTL, func(ctx context.Context) ([]byte, error) {
						return tc.fetch(client, ctx, url)
					}, func(body []byte) (*payload, error) {
						var out payload
						if err := json.Unmarshal(body, &out); err != nil {
							return nil, err
						}
						return &out, nil
					})
				}
				type result struct {
					value *payload
					err   error
				}
				start := func(ctx context.Context) <-chan result {
					out := make(chan result, 1)
					go func() {
						v, err := read(ctx)
						out <- result{v, err}
					}()
					return out
				}
				join := func(ctx context.Context, parked <-chan struct{}) <-chan result {
					joined := &discoverJoinContext{Context: ctx, waiting: make(chan struct{}), parked: parked}
					out := start(joined)
					awaitDiscoverEvent(t, joined.waiting)
					return out
				}
				leader := start(t.Context())
				awaitDiscoverEvent(t, bodyEntered)
				short, cancelShort := context.WithTimeout(t.Context(), time.Second)
				defer cancelShort()
				if got := awaitDiscoverEvent(t, join(short, nil)); !errors.Is(got.err, context.DeadlineExceeded) || got.value != nil {
					t.Fatalf("expired follower returned %+v", got)
				}
				bodyFollower := join(t.Context(), nil)
				openBody()
				awaitDiscoverEvent(t, setEntered)
				writeFollower := join(t.Context(), nil)
				delayedCtx, cancelDelayed := context.WithCancel(t.Context())
				defer cancelDelayed()
				delayedFollower := join(delayedCtx, resumeWaiter)
				synctest.Wait()
				for _, out := range []<-chan result{leader, bodyFollower, writeFollower} {
					select {
					case got := <-out:
						t.Fatalf("read returned before held SET: %+v", got)
					default:
					}
				}
				openSet()
				got := awaitDiscoverEvent(t, leader)
				if got.err != nil || got.value == nil {
					t.Fatalf("leader returned %+v", got)
				}
				for _, out := range []<-chan result{bodyFollower, writeFollower} {
					peer := awaitDiscoverEvent(t, out)
					if peer.err != nil || peer.value == got.value || !reflect.DeepEqual(peer.value, got.value) {
						t.Fatalf("follower must own an equal, independent result: %+v, leader %+v", peer, got)
					}
				}
				// Valid publication must not wait for all callers. Also refuse a
				// stale caller when both result-ready and cancellation are ready.
				cancelDelayed()
				openWaiter()
				if got := awaitDiscoverEvent(t, delayedFollower); !errors.Is(got.err, context.Canceled) || got.value != nil {
					t.Fatalf("canceled delayed follower returned %+v", got)
				}
				if reads.Load() != 1 || writes.Load() != 1 || calls.Load() != 1 {
					t.Fatalf("cold fill: %d cache reads, %d writes, %d provider calls", reads.Load(), writes.Load(), calls.Load())
				}
				warm, err := read(t.Context())
				if err != nil || !reflect.DeepEqual(warm, got.value) || reads.Load() != 2 || writes.Load() != 1 || calls.Load() != 1 {
					t.Fatalf("warm read: %+v %v, %d cache reads, %d writes, %d provider calls", warm, err, reads.Load(), writes.Load(), calls.Load())
				}
			})
		})
	}
}

type discoverHeldBody struct {
	io.ReadCloser
	entered chan struct{}
	release <-chan struct{}
	once    sync.Once
}

func (b *discoverHeldBody) Read(p []byte) (int, error) {
	b.once.Do(func() { close(b.entered) })
	<-b.release
	return b.ReadCloser.Read(p)
}

// Observe the caller reaching its cancellable wait. The deadline check
// distinguishes that from propagation in the synchronous predecessor.
type discoverJoinContext struct {
	context.Context
	waiting         chan struct{}
	parked          <-chan struct{}
	deadlineChecked atomic.Bool
	once            sync.Once
}

func (c *discoverJoinContext) Deadline() (time.Time, bool) {
	c.deadlineChecked.Store(true)
	return c.Context.Deadline()
}

func (c *discoverJoinContext) Done() <-chan struct{} {
	if !c.deadlineChecked.Load() {
		c.once.Do(func() { close(c.waiting) })
		if c.parked != nil {
			<-c.parked
		}
	}
	return c.Context.Done()
}
