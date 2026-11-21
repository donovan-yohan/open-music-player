package musicbrainz

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/google/uuid"
)

const discoverEmptyGroups = `{"release-group-count":0,"release-group-offset":0,"release-groups":[]}`

func awaitDiscoverEvent[T any](t *testing.T, event <-chan T) T {
	t.Helper()
	select {
	case result := <-event:
		return result
	case <-time.After(4 * time.Second):
		t.Fatal("timed out waiting for fixture event")
		var zero T
		return zero
	}
}

func TestDiscoverBrowseOwnerCancellationKeepsJoinedFollower(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	open := sync.OnceFunc(func() { close(release) })
	defer open()
	var calls atomic.Int32
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(entered)
		}
		select {
		case <-req.Context().Done():
			return nil, req.Context().Err()
		case <-release:
			return fixtureResponse(http.StatusOK, discoverEmptyGroups), nil
		}
	}))
	type result struct {
		page *DiscoverBrowsePage[DiscoverReleaseGroup]
		err  error
	}
	start := func(ctx context.Context) <-chan result {
		out := make(chan result, 1)
		go func() {
			page, err := client.BrowseArtistDiscography(ctx, uuid.MustParse(discoverBrowseArtist), "", 20, 0)
			out <- result{page, err}
		}()
		return out
	}
	ownerCtx, cancelOwner := context.WithCancel(t.Context())
	defer cancelOwner()
	owner := start(ownerCtx)
	awaitDiscoverEvent(t, entered)
	followerCtx := &discoverJoinContext{Context: t.Context(), waiting: make(chan struct{})}
	follower := start(followerCtx)
	awaitDiscoverEvent(t, followerCtx.waiting)
	// A still-live follower must not need the first caller to stay, and the
	// canceled caller must not wait for the fixture to release the provider.
	cancelOwner()
	if got := awaitDiscoverEvent(t, owner); !errors.Is(got.err, context.Canceled) || got.page != nil {
		t.Fatalf("canceled owner: %+v", got)
	}
	select {
	case got := <-follower:
		t.Fatalf("joined follower returned before provider release: page=%+v err=%v", got.page, got.err)
	default:
	}
	open()
	if got := awaitDiscoverEvent(t, follower); got.err != nil || got.page == nil || got.page.Results == nil || calls.Load() != 1 {
		t.Fatalf("joined follower: page=%+v err=%v; dispatches=%d", got.page, got.err, calls.Load())
	}
}

func TestDiscoverBrowseDoesNotInheritStandardRequestFlightButSharesPacing(t *testing.T) {
	first, second := make(chan time.Time, 1), make(chan time.Time, 1)
	bodyEntered, releaseBody := make(chan struct{}), make(chan struct{})
	openBody := sync.OnceFunc(func() { close(releaseBody) })
	defer openBody()
	params := url.Values{"artist": {discoverBrowseArtist}, "inc": {"artist-credits"}, "fmt": {"json"}, "limit": {"20"}, "offset": {"0"}}
	endpoint := baseURL + "/release-group?" + params.Encode()
	var calls atomic.Int32
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		if req.URL.String() != endpoint || !interactiveCatalogRead(req.Context()) {
			t.Errorf("unexpected request/policy: %s", req.URL)
		}
		resp := fixtureResponse(http.StatusOK, discoverEmptyGroups)
		switch calls.Add(1) {
		case 1:
			first <- time.Now()
			resp.Body = &discoverHeldBody{ReadCloser: resp.Body, entered: bodyEntered, release: releaseBody}
		case 2:
			second <- time.Now()
		default:
			t.Error("duplicate dispatch")
		}
		return resp, nil
	}))
	standard := make(chan error, 1)
	go func() {
		_, err := client.doRequest(WithInteractiveCatalogRead(t.Context()), endpoint)
		standard <- err
	}()
	awaitDiscoverEvent(t, bodyEntered)
	browse := make(chan error, 1)
	go func() {
		_, err := client.BrowseArtistDiscography(t.Context(), uuid.MustParse(discoverBrowseArtist), "", 20, 0)
		browse <- err
	}()
	if err := awaitDiscoverEvent(t, browse); err != nil || calls.Load() != 2 {
		t.Fatalf("browse did not finish independently of the held doRequest: %v calls=%d", err, calls.Load())
	}
	if gap := awaitDiscoverEvent(t, second).Sub(awaitDiscoverEvent(t, first)); gap < time.Second {
		t.Fatalf("browse bypassed standard request pacing: %s", gap)
	}
	openBody()
	if err := awaitDiscoverEvent(t, standard); err != nil {
		t.Fatalf("standard request: %v", err)
	}
}

type discoverFixtureCache struct {
	get func(context.Context, string) (string, bool)
	set func(context.Context, string, string, time.Duration)
}

func (c discoverFixtureCache) cacheGet(ctx context.Context, key string) (string, bool) {
	return c.get(ctx, key)
}

func (c discoverFixtureCache) cacheSet(ctx context.Context, key, value string, ttl time.Duration) {
	c.set(ctx, key, value, ttl)
}

func TestDiscoverBrowseValidatedResultSurvivesCacheWriteDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client := NewClient(nil)
		ctx := t.Context()
		started := time.Now()
		var writes int
		store := discoverFixtureCache{
			get: func(context.Context, string) (string, bool) { return "", false },
			set: func(fillCtx context.Context, _ string, value string, _ time.Duration) {
				writes++
				if value != "validated bytes" || ctx.Err() != nil {
					t.Errorf("SET reached without a valid active fill: %q %v", value, ctx.Err())
				}
				<-fillCtx.Done()
				if !errors.Is(fillCtx.Err(), context.DeadlineExceeded) || time.Since(started) != discoverBrowseTimeout {
					t.Errorf("SET did not consume the bounded fill budget: %v %s", fillCtx.Err(), time.Since(started))
				}
			},
		}
		fetch := func(context.Context) ([]byte, error) { return []byte("validated bytes"), nil }
		decode := func(b []byte) (*string, error) {
			value := string(b)
			if value != "validated bytes" {
				return nil, errInvalidDiscoverResponse
			}
			return &value, nil
		}
		result, err := readDiscoverBrowseWithCache(ctx, client, store, "https://fixture.invalid/browse", 256, searchTTL, fetch, decode)
		if err != nil || result == nil || *result != "validated bytes" || writes != 1 || ctx.Err() != nil {
			t.Fatalf("active caller lost validated result: %v, %v; writes=%d caller=%v", result, err, writes, ctx.Err())
		}
	})
}
