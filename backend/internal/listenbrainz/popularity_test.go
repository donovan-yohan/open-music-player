package listenbrainz

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestArtistPopularityUsesExactCreditsAndSharesTheActiveRead(t *testing.T) {
	artist := uuid.MustParse("b7ffd2af-418f-4be2-bdd1-22f8b48613da")
	var calls atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/1/popularity/top-recordings-for-artist/"+artist.String() {
			t.Errorf("path: %s", r.URL.Path)
		}
		calls.Add(1)
		close(entered)
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		io.WriteString(w, `[
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144411","recording_name":"Closer","artist_name":"Nine Inch Nails","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613da"],"total_listen_count":12,"length":373133},
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144412","recording_name":"Wrong artist","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613db"],"total_listen_count":40},
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144413","recording_name":"Hurt","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613da"],"total_listen_count":15}
		]`)
	}))
	defer server.Close()
	defer close(release)
	svc := NewPopularityService(nil)
	svc.baseURL = server.URL
	type result struct {
		tracks []PopularTrack
		err    error
	}
	owner := make(chan result, 1)
	go func() { rows, err := svc.TopTracks(t.Context(), artist); owner <- result{rows, err} }()
	<-entered
	otherID := uuid.New()
	if _, err := svc.TopTracks(t.Context(), otherID); err == nil {
		t.Fatal("concurrent miss on a different artist was admitted")
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := svc.TopTracks(ctx, artist); err == nil {
		t.Fatal("canceled caller must leave independently")
	}
	select {
	case release <- struct{}{}:
	case <-t.Context().Done():
		t.Fatal("failed to release fixture")
	}
	got := <-owner
	if got.err != nil || len(got.tracks) != 2 || got.tracks[0].Title != "Hurt" || got.tracks[1].Title != "Closer" || calls.Load() != 1 {
		t.Fatalf("result=%+v calls=%d", got, calls.Load())
	}
}

type popularityTestCache struct {
	values map[string]string
	writes int
	ttl    time.Duration
}

func (c *popularityTestCache) Get(_ context.Context, key string) (string, bool) {
	value, ok := c.values[key]
	return value, ok
}

func (c *popularityTestCache) Set(_ context.Context, key, value string, ttl time.Duration) error {
	c.values[key] = value
	c.writes++
	c.ttl = ttl
	return nil
}

func TestArtistPopularityRejectsUnevidencedRowsBeforeCache(t *testing.T) {
	const artistID = "b7ffd2af-418f-4be2-bdd1-22f8b48613da"
	const valid = `{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144411","recording_name":"Closer","artist_name":"Nine Inch Nails","artist_mbids":["` + artistID + `"],"total_listen_count":12,"length":373133}`
	const creditless = `{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144412","recording_name":"Hurt","total_listen_count":10`
	for _, tc := range []struct{ name, payload string }{
		{"missing_credits", `[` + creditless + `}]`},
		{"null_credits", `[` + creditless + `,"artist_mbids":null}]`},
		{"empty_credits", `[` + creditless + `,"artist_mbids":[]}]`},
		{"null_credit_id", `[` + creditless + `,"artist_mbids":[null]}]`},
		{"partially_evidenced_credit", `[` + creditless + `,"artist_mbids":["` + artistID + `",null]}]`},
		// uuid.Parse accepts these 38-byte strings by parsing only their middle 36 bytes.
		{"malformed_exact_credit_alias", `[` + creditless + `,"artist_mbids":["!` + artistID + `?"]}]`},
		{"malformed_recording_alias", `[{"recording_mbid":"!13dd61c7-ce73-4e97-9f0c-9f0e53144411?","recording_name":"Closer","artist_mbids":["` + artistID + `"],"total_listen_count":12}]`},
		{"null_row", `[null]`},
		{"unusable_row", `[{"artist_mbids":["` + artistID + `"]}]`},
		{"mixed_valid_and_malformed", `[` + valid + `,` + creditless + `}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if calls.Add(1) == 1 {
					_, _ = io.WriteString(w, tc.payload)
					return
				}
				_, _ = io.WriteString(w, `[`+valid+`]`)
			}))
			defer server.Close()
			store := &popularityTestCache{values: make(map[string]string)}
			svc := NewPopularityService(store)
			svc.baseURL = server.URL
			artist := uuid.MustParse(artistID)
			if rows, err := svc.TopTracks(t.Context(), artist); !errors.Is(err, ErrBadPayload) || rows != nil || store.writes != 0 || calls.Load() != 1 {
				t.Fatalf("malformed upstream: rows=%+v error=%v writes=%d calls=%d", rows, err, store.writes, calls.Load())
			}
			// Expire the fixture's completed-attempt cooldown without sleeping.
			svc.next = time.Time{}
			for _, pass := range []string{"retry", "warm"} {
				if rows, err := svc.TopTracks(t.Context(), artist); err != nil || len(rows) != 1 || rows[0].Title != "Closer" || store.writes != 1 || calls.Load() != 2 {
					t.Fatalf("%s: rows=%+v error=%v writes=%d calls=%d", pass, rows, err, store.writes, calls.Load())
				}
			}
		})
	}
}

func TestArtistPopularityCachesVerifiedEmpty(t *testing.T) {
	const artistID = "b7ffd2af-418f-4be2-bdd1-22f8b48613da"
	for _, tc := range []struct{ name, payload string }{
		{"explicit_empty", `[]`},
		{"explicit_different_artist", `[{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144412","recording_name":"Wrong artist","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613db"],"total_listen_count":40}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				_, _ = io.WriteString(w, tc.payload)
			}))
			defer server.Close()
			store := &popularityTestCache{values: make(map[string]string)}
			svc := NewPopularityService(store)
			svc.baseURL = server.URL
			for _, pass := range []string{"cold", "warm"} {
				rows, err := svc.TopTracks(t.Context(), uuid.MustParse(artistID))
				if err != nil || rows == nil || len(rows) != 0 || calls.Load() != 1 || store.writes != 1 || store.ttl != 12*time.Hour {
					t.Fatalf("%s: rows=%#v error=%v calls=%d writes=%d ttl=%v", pass, rows, err, calls.Load(), store.writes, store.ttl)
				}
			}
		})
	}
}

func TestArtistPopularityDoesNotTrustLegacyEmptyOrMalformedWarmRows(t *testing.T) {
	const artistID = "b7ffd2af-418f-4be2-bdd1-22f8b48613da"
	const legacyKey = "lb:artist-popularity:v1:" + artistID
	const verifiedKey = "lb:artist-popularity:v2:" + artistID
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		_, _ = io.WriteString(w, `[{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144411","recording_name":"Closer","artist_mbids":["`+artistID+`"],"total_listen_count":12}]`)
	}))
	defer server.Close()
	store := &popularityTestCache{values: map[string]string{legacyKey: `[]`, verifiedKey: `[null]`}}
	svc := NewPopularityService(store)
	svc.baseURL = server.URL
	for _, pass := range []string{"cold replacement", "warm"} {
		rows, err := svc.TopTracks(t.Context(), uuid.MustParse(artistID))
		if err != nil || len(rows) != 1 || rows[0].Title != "Closer" || calls.Load() != 1 || store.writes != 1 {
			t.Fatalf("%s: rows=%#v error=%v calls=%d writes=%d", pass, rows, err, calls.Load(), store.writes)
		}
	}
	if got := store.values[legacyKey]; got != `[]` {
		t.Fatalf("legacy cache was modified: %q", got)
	}
}
