package musicbrainz

import (
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDiscoverBrowseCoalescesThroughBodyAndCacheWrite(t *testing.T) {
	for _, tc := range []struct {
		name, path, body string
		read             func(context.Context, *Client) (any, error)
	}{
		{"small_page", "/ws/2/release-group", `{"release-group-count":1,"release-group-offset":0,"release-groups":[{"id":"` + discoverBrowseGroup + `","title":"An EP","primary-type":"EP",` + discoverBrowseCredit + `}]}`, func(ctx context.Context, c *Client) (any, error) {
			return c.BrowseArtistDiscography(ctx, uuid.MustParse(discoverBrowseArtist), DiscographyEP, 5, 0)
		}},
		{"tracklist", "/ws/2/release/" + browseEdition, `{"id":"` + browseEdition + `","release-group":{"id":"` + discoverBrowseGroup + `"},"title":"Fixture","media":[{"position":1,"track-count":0,"tracks":[]}]}`, func(ctx context.Context, c *Client) (any, error) {
			return c.GetEditionTracklist(ctx, uuid.MustParse(browseEdition))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls, reads, writes atomic.Int32
			bodyEntered, releaseBody := make(chan struct{}), make(chan struct{})
			setEntered, releaseSet := make(chan struct{}), make(chan struct{})
			secondGet := make(chan struct{})
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				switch cmd {
				case "get":
					if reads.Add(1) == 2 {
						close(secondGet)
					}
				case "set":
					if writes.Add(1) == 1 {
						close(setEntered)
						<-releaseSet
					}
				}
			})
			openBody := sync.OnceFunc(func() { close(releaseBody) })
			openSet := sync.OnceFunc(func() { close(releaseSet) })
			defer openBody()
			defer openSet()
			client := NewClientWithTransport(store, fixtureTransport(func(req *http.Request) (*http.Response, error) {
				if req.Method != http.MethodGet || req.URL.Path != tc.path {
					t.Errorf("unexpected provider request: %s %s", req.Method, req.URL)
				}
				if !interactiveCatalogRead(req.Context()) {
					t.Error("browse provider request lost the interactive context")
				}
				resp := fixtureResponse(200, tc.body)
				if calls.Add(1) == 1 {
					resp.Body = &discoverHeldBody{ReadCloser: resp.Body, entered: bodyEntered, release: releaseBody}
				}
				return resp, nil
			}))
			type result struct {
				value any
				err   error
			}
			var callers sync.WaitGroup
			t.Cleanup(callers.Wait)
			start := func(ctx context.Context) <-chan result {
				out := make(chan result, 1)
				callers.Go(func() {
					v, err := tc.read(ctx, client)
					out <- result{v, err}
				})
				return out
			}
			receive := func(out <-chan result) result {
				t.Helper()
				select {
				case got := <-out:
					return got
				case <-time.After(3 * time.Second):
					t.Fatal("browse caller did not return")
					return result{}
				}
			}
			wait := func(event <-chan struct{}, name string) {
				t.Helper()
				select {
				case <-event:
				case <-secondGet:
					t.Fatalf("duplicate cold cache read instead of %s", name)
				case <-time.After(3 * time.Second):
					t.Fatalf("did not observe %s", name)
				}
			}
			leader := start(context.Background())
			wait(bodyEntered, "leader body read")
			join := func(name string) (context.CancelFunc, <-chan result) {
				t.Helper()
				ctx, cancel := context.WithCancel(context.Background())
				t.Cleanup(cancel)
				joining := &discoverJoinContext{Context: ctx, waiting: make(chan struct{})}
				out := start(joining)
				wait(joining.waiting, name)
				return cancel, out
			}
			cancel, canceled := join("follower while body held")
			cancel()
			if got := receive(canceled); !errors.Is(got.err, context.Canceled) {
				t.Fatalf("canceled follower returned %+v", got)
			}
			_, bodyFollower := join("live follower while body held")
			openBody()
			wait(setEntered, "validated cache write")
			_, writeFollower := join("live follower while cache write held")
			for _, out := range []<-chan result{leader, bodyFollower, writeFollower} {
				select {
				case got := <-out:
					t.Fatalf("read returned before the held cache fill: %+v", got)
				default:
				}
			}
			openSet()
			got := receive(leader)
			if got.err != nil || got.value == nil {
				t.Fatalf("leader returned %+v", got)
			}
			for _, out := range []<-chan result{bodyFollower, writeFollower} {
				peer := receive(out)
				if peer.err != nil || peer.value == got.value || !reflect.DeepEqual(peer.value, got.value) {
					t.Fatalf("follower must own an equal, independent result: %+v, leader %+v", peer, got)
				}
			}
			if reads.Load() != 1 || writes.Load() != 1 || calls.Load() != 1 {
				t.Fatalf("cold fill: %d cache reads, %d writes, %d provider calls", reads.Load(), writes.Load(), calls.Load())
			}
			warm, err := tc.read(context.Background(), client)
			if err != nil || !reflect.DeepEqual(warm, got.value) || reads.Load() != 2 || writes.Load() != 1 || calls.Load() != 1 {
				t.Fatalf("warm read: %+v %v, %d cache reads, %d writes, %d provider calls", warm, err, reads.Load(), writes.Load(), calls.Load())
			}
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

// Observe the caller's direct cancellable wait, excluding Done() consulted by
// context.WithTimeout during creation of a new owner's context.
type discoverJoinContext struct {
	context.Context
	waiting         chan struct{}
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
	}
	return c.Context.Done()
}
