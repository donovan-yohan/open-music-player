package discovery

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

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
)

type sharedRadarTransport func(*http.Request) (*http.Response, error)

func (f sharedRadarTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type sharedRadarWaitContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *sharedRadarWaitContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

type sharedRadarCatalog struct {
	client  *musicbrainz.Client
	waiting chan struct{}
}

func (c sharedRadarCatalog) SearchTracks(ctx context.Context, q string, l, o int, skip bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	if c.waiting != nil {
		// With no cache, SearchTracks first observes Done when joining a flight.
		ctx = &sharedRadarWaitContext{Context: ctx, waiting: c.waiting}
	}
	return c.client.SearchTracks(ctx, q, l, o, skip)
}

// New consuming regression: ordinary metadata deliberately shared leader errors.
// Daily account admission makes another leader's cancellation consequential.
func TestRadarDailySharedLeaderCancellationKeepsLiveAccountAdmission(t *testing.T) {
	database := radartest.RadarDatabase(t)
	leaderUser := radartest.RadarAccount(t, database)
	liveUser := radartest.RadarAccount(t, database)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	leaderCtx, cancelLeader := context.WithCancel(ctx)
	defer cancelLeader()
	entered, waiting := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	old := http.DefaultTransport
	http.DefaultTransport = sharedRadarTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" {
			return nil, fmt.Errorf("forbidden synthetic destination: %s", r.URL)
		}
		if calls.Add(1) == 1 {
			close(entered)
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		raw := `{"count":1,"offset":0,"recordings":[{"id":"33333333-3333-4333-8333-333333333333","title":"Synthetic shared song","first-release-date":"2026-11-12","artist-credit":[{"artist":{"id":"11111111-1111-4111-8111-111111111111","name":"Synthetic artist"}}]}]}`
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(raw)), Request: r}, nil
	})
	defer func() { http.DefaultTransport = old }()
	client := musicbrainz.NewClient(nil)
	account := &radarMatrix{}
	leader := NewDailyRadarService(account, account, sharedRadarCatalog{client: client}, database)
	live := NewDailyRadarService(account, account, sharedRadarCatalog{client: client, waiting: waiting}, database)
	for _, service := range []*RadarService{leader, live} {
		service.daily.now = func() time.Time { return radarNow }
	}
	type result struct {
		page RadarPage
		err  error
	}
	leaderDone, liveDone := make(chan result, 1), make(chan result, 1)
	go func() { p, e := leader.Read(leaderCtx, leaderUser, radarNow); leaderDone <- result{p, e} }()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	go func() { p, e := live.Read(ctx, liveUser, radarNow); liveDone <- result{p, e} }()
	select {
	case <-waiting:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	var token uuid.UUID
	var attempted time.Time
	var phase string
	if err := database.QueryRowContext(ctx, `SELECT token,attempted_at,phase FROM release_radar_daily WHERE user_id=$1`, liveUser).Scan(&token, &attempted, &phase); err != nil || phase != "pending" {
		t.Fatalf("live account not admitted before cancellation: phase=%s error=%v", phase, err)
	}
	cancelLeader()
	if r := <-leaderDone; r.err == nil {
		t.Fatal("canceled leader succeeded")
	}
	r := <-liveDone
	var afterToken uuid.UUID
	var afterAttempt time.Time
	if err := database.QueryRowContext(ctx, `SELECT token,attempted_at,phase FROM release_radar_daily WHERE user_id=$1`, liveUser).Scan(&afterToken, &afterAttempt, &phase); err != nil {
		t.Fatal(err)
	}
	// Read again within the same day, before asserting, to expose persisted poison.
	again, againErr := live.Read(ctx, liveUser, radarNow)
	if r.err != nil || againErr != nil || phase != "ready" || len(r.page.Items) != 1 || len(again.Items) != 1 {
		t.Fatalf("live daily account poisoned by other leader: first=%v repeated=%v phase=%s items=%d/%d calls=%d", r.err, againErr, phase, len(r.page.Items), len(again.Items), calls.Load())
	}
	if token != afterToken || !attempted.Equal(afterAttempt) || calls.Load() != 2 {
		t.Fatalf("takeover renewed admission or duplicated work: token=%s/%s attempted=%s/%s calls=%d", token, afterToken, attempted, afterAttempt, calls.Load())
	}
}
