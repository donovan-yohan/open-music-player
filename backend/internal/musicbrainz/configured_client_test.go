package musicbrainz_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type controlledTransport func(*http.Request) (*http.Response, error)

func (f controlledTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Use only exported constructors/callers. No private limiter substitution or
// production rate override can turn this into a test of an unconfigured client.
func TestConfiguredClientsShareSearchLookupAndMatcherBudget(t *testing.T) {
	var mu sync.Mutex
	var starts []time.Time
	var queries []string
	original := http.DefaultTransport
	http.DefaultTransport = controlledTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" {
			return nil, fmt.Errorf("unexpected external target %s", r.URL)
		}
		mu.Lock()
		starts = append(starts, time.Now())
		queries = append(queries, r.URL.Path+"?"+r.URL.RawQuery)
		mu.Unlock()
		body := `{"id":"entity","count":1,"recordings":[{"id":"rec","title":"Song","length":240000,"score":100,"first-release-date":"1984","artist-credit":[{"artist":{"id":"first","name":"First"}},{"artist":{"id":"second","name":"Second"}}],"releases":[{"id":"edition","title":"Reissue","date":"2026-11-01","release-group":{"id":"group"}}]}]}`
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = original })
	c := musicbrainz.NewClient(nil)
	other := musicbrainz.NewClient(nil)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	work := []func() error{
		func() error { _, err := c.SearchTracks(ctx, "search", 20, 0, false); return err },
		func() error { _, err := other.SearchArtists(ctx, "artist", 20, 0, false); return err },
		func() error { _, err := c.SearchAlbums(ctx, "album", 20, 0, false); return err },
		func() error { _, err := other.GetArtist(ctx, "artist-id"); return err },
		func() error { _, err := c.GetRelease(ctx, "edition-id"); return err },
		func() error { _, err := other.GetRecording(ctx, "rec-id"); return err },
		func() error {
			out, err := matcher.NewMatcher(c).Match(ctx, matcher.TrackMetadata{Title: "First - Song", DurationMs: 240000})
			if err != nil {
				return err
			}
			if !out.Verified || out.BestMatch == nil {
				return fmt.Errorf("matching semantics changed: %+v", out)
			}
			m := out.BestMatch
			if m.Artist != "First" || m.ArtistMBID != "first" || m.ReleaseDate != "2026-11-01" || m.ReleaseID != "edition" || m.AlbumMBID != "group" || m.MBID != "rec" {
				return fmt.Errorf("matching conversion changed: %+v", m)
			}
			return nil
		},
	}
	errs := make(chan error, len(work))
	start := make(chan struct{})
	for _, f := range work {
		go func(f func() error) { <-start; errs <- f() }(f)
	}
	close(start)
	for range work {
		if err := <-errs; err != nil {
			t.Error(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(starts) != len(work) {
		t.Fatalf("provider dispatch count=%d want=%d", len(starts), len(work))
	}
	for i := 1; i < len(starts); i++ {
		if gap := starts[i].Sub(starts[i-1]); gap < time.Second {
			t.Errorf("provider dispatches %d/%d only %s apart: %v", i-1, i, gap, queries)
		}
	}
}
