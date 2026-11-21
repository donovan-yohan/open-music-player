package listenbrainz

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

const popularityFixtureToken = "fixture-listenbrainz-popularity-token"

func TestArtistPopularityUsesExactCreditsAndSharesTheActiveRead(t *testing.T) {
	artist := uuid.MustParse("b7ffd2af-418f-4be2-bdd1-22f8b48613da")
	var calls atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{}, 1)
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
		if !slices.Equal(r.Header.Values("Authorization"), []string{"Token " + popularityFixtureToken}) {
			t.Error("missing or invalid ListenBrainz authorization")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet || r.URL.RawQuery != "" {
			t.Error("popularity must use a GET with no query parameters")
		}
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, `[
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144411","recording_name":"Closer","artist_name":"Nine Inch Nails","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613da"],"total_listen_count":12,"length":373133},
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144412","recording_name":"Wrong artist","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613db"],"total_listen_count":40},
			{"recording_mbid":"13dd61c7-ce73-4e97-9f0c-9f0e53144413","recording_name":"Hurt","artist_mbids":["b7ffd2af-418f-4be2-bdd1-22f8b48613da"],"total_listen_count":15}
		]`)
	}))
	defer server.Close()
	defer close(release)
	svc := NewPopularityService(nil, popularityFixtureToken)
	svc.baseURL = server.URL
	type result struct {
		tracks []PopularTrack
		err    error
	}
	owner := make(chan result, 1)
	go func() { rows, err := svc.TopTracks(t.Context(), artist); owner <- result{rows, err} }()
	select {
	case <-entered:
	case <-owner:
		t.Fatal("popularity request ended before reaching the upstream fixture")
	}
	otherID := uuid.New()
	if _, err := svc.TopTracks(t.Context(), otherID); err == nil {
		t.Fatal("concurrent miss on a different artist was admitted")
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := svc.TopTracks(ctx, artist); err == nil {
		t.Fatal("canceled caller must leave independently")
	}
	release <- struct{}{}
	got := <-owner
	if got.err != nil || len(got.tracks) != 2 || got.tracks[0].Title != "Hurt" || got.tracks[1].Title != "Closer" || calls.Load() != 1 {
		t.Fatalf("result=%+v calls=%d", got, calls.Load())
	}
}

func TestArtistPopularityWithoutTokenDoesNotReadUpstream(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		_, _ = io.WriteString(w, `[]`)
	}))
	defer server.Close()
	artist := uuid.New()
	for _, pass := range []string{"cold", "warm"} {
		t.Run(pass, func(t *testing.T) {
			store := &popularityTestCache{values: make(map[string]string)}
			if pass == "warm" {
				store.values[popularityCachePrefix+artist.String()] = `[]`
			}
			svc := NewPopularityService(store, "")
			svc.baseURL = server.URL
			before := calls.Load()
			rows, err := svc.TopTracks(t.Context(), artist)
			if rows != nil || !errors.Is(err, errPopularityUnconfigured) || calls.Load() != before || store.reads != 0 || store.writes != 0 {
				t.Fatalf("unconfigured shelf: rows=%v errored=%t requests=%d cache reads=%d writes=%d", rows, err != nil, calls.Load()-before, store.reads, store.writes)
			}
		})
	}
}

func TestArtistPopularityMalformedRedirectDoesNotExposeToken(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.Header().Set("Location", "/%zz/"+popularityFixtureToken)
		w.WriteHeader(http.StatusFound)
	}))
	defer server.Close()
	svc := NewPopularityService(nil, popularityFixtureToken)
	svc.baseURL = server.URL
	rows, err := svc.TopTracks(t.Context(), uuid.New())
	if rows != nil || !errors.Is(err, ErrUnreachable) || !strings.HasPrefix(err.Error(), "send ListenBrainz popularity request:") || strings.Contains(err.Error(), popularityFixtureToken) || calls.Load() != 1 {
		t.Fatal("malformed redirect must fail without exposing the credential or making a second request")
	}
}

func TestArtistPopularityWrapsIncompleteBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "10")
		_, _ = io.WriteString(w, `[]`)
	}))
	defer server.Close()
	svc := NewPopularityService(nil, popularityFixtureToken)
	svc.baseURL = server.URL
	rows, err := svc.TopTracks(t.Context(), uuid.New())
	if rows != nil || !errors.Is(err, io.ErrUnexpectedEOF) || !strings.HasPrefix(err.Error(), "read ListenBrainz popularity response:") {
		t.Fatal("body failure did not retain operation and cause")
	}
}

func TestArtistPopularityUpstreamFailureDoesNotRetryOrCache(t *testing.T) {
	for _, tc := range []struct {
		code int
		want error
	}{
		{http.StatusFound, ErrUpstreamStatus},
		{http.StatusUnauthorized, ErrUpstreamStatus},
		{http.StatusTooManyRequests, ErrRateLimited},
		{http.StatusServiceUnavailable, ErrUpstreamStatus},
	} {
		t.Run(strconv.Itoa(tc.code), func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if !strings.HasPrefix(r.URL.Path, "/1/popularity/top-recordings-for-artist/") || !slices.Equal(r.Header.Values("Authorization"), []string{"Token " + popularityFixtureToken}) {
					t.Error("unexpected popularity path or credential")
				}
				if tc.code == http.StatusFound {
					w.Header().Set("Location", "/unexpected-target")
				}
				w.WriteHeader(tc.code)
				_, _ = io.WriteString(w, `{"error":"`+r.Header.Get("Authorization")+`"}`)
			}))
			defer server.Close()
			store := &popularityTestCache{values: make(map[string]string)}
			svc := NewPopularityService(store, popularityFixtureToken)
			svc.baseURL = server.URL
			rows, err := svc.TopTracks(t.Context(), uuid.New())
			if rows != nil || !errors.Is(err, tc.want) || calls.Load() != 1 || store.writes != 0 {
				t.Fatal("upstream failure returned the wrong result or error class, retried, or warmed the cache")
			}
			if strings.Contains(err.Error(), popularityFixtureToken) || (tc.want == ErrUpstreamStatus && !strings.HasSuffix(err.Error(), ": "+strconv.Itoa(tc.code))) {
				t.Fatal("upstream error exposed the credential or omitted the status code")
			}
		})
	}
}

func TestArtistPopularityCredentialDoesNotChangeLabsClient(t *testing.T) {
	artist := uuid.New()
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		switch r.URL.Path {
		case "/1/popularity/top-recordings-for-artist/" + artist.String():
			if !slices.Equal(r.Header.Values("Authorization"), []string{"Token " + popularityFixtureToken}) {
				t.Error("popularity did not send its dedicated credential")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
		case "/similar-artists/json":
			if len(r.Header.Values("Authorization")) != 0 || r.URL.Query().Get("algorithm") != PinnedAlgorithm || r.URL.Query().Get("artist_mbids") != artist.String() {
				t.Error("labs must keep its independent unauthenticated request contract")
				w.WriteHeader(http.StatusBadRequest)
				return
			}
		default:
			t.Error("unexpected upstream path")
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = io.WriteString(w, `[]`)
	}))
	defer server.Close()
	svc := NewPopularityService(nil, popularityFixtureToken)
	svc.baseURL = server.URL
	if rows, err := svc.TopTracks(t.Context(), artist); err != nil || rows == nil {
		t.Fatal("authenticated popularity control failed")
	}
	if reply, err := NewClientWithBaseURL(server.URL).SimilarArtists(t.Context(), artist); err != nil || reply == nil || calls.Load() != 2 {
		t.Fatal("unauthenticated labs control failed")
	}
}

type popularityTestCache struct {
	values map[string]string
	reads  int
	writes int
	ttl    time.Duration
}

func (c *popularityTestCache) Get(_ context.Context, key string) (string, bool) {
	c.reads++
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
			svc := NewPopularityService(store, popularityFixtureToken)
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
			svc := NewPopularityService(store, popularityFixtureToken)
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
	svc := NewPopularityService(store, popularityFixtureToken)
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
