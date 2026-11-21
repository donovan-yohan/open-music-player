package musicbrainz

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

const (
	browseEdition   = "33333333-3333-4333-8333-333333333333"
	browseRecording = "44444444-4444-4444-8444-444444444444"
)

func TestDiscoverBrowseArtistSearchEachKindUsesLiteralAndExactCredit(t *testing.T) {
	const literal = `same" OR arid:*\name`
	var paths []string
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		paths = append(paths, req.URL.Path)
		var field, list, body string
		switch req.URL.Path {
		case "/ws/2/recording":
			field, list = "recording", "recordings"
			body = `{"id":"` + browseRecording + `","title":"Same song","length":123000,"first-release-date":"2026",` + discoverBrowseCredit + `}`
		case "/ws/2/release-group":
			field, list = "releasegroup", "release-groups"
			body = `{"id":"` + discoverBrowseGroup + `","title":"Same album","primary-type":"Album",` + discoverBrowseCredit + `}`
		default:
			t.Fatalf("unrelated provider request: %s", req.URL)
		}
		want := url.Values{"query": {field + `:"same\" OR arid:*\\name" AND arid:` + discoverBrowseArtist}, "fmt": {"json"}, "limit": {"20"}, "offset": {"0"}}
		if !reflect.DeepEqual(req.URL.Query(), want) {
			t.Fatalf("wrong scoped query: %v", req.URL.Query())
		}
		return fixtureResponse(200, `{"count":1,"offset":0,"`+list+`":[`+body+`]}`), nil
	}))
	id := uuid.MustParse(discoverBrowseArtist)
	songs, err := client.SearchArtistRecordings(context.Background(), id, literal, 20, 0)
	if err != nil || len(songs.Results) != 1 || songs.Results[0].RecordingMBID != browseRecording || songs.Results[0].Duration != 123000 || songs.Results[0].FirstReleaseDate != "2026" || !reflect.DeepEqual(paths, []string{"/ws/2/recording"}) {
		t.Fatalf("song kind result or dispatch: %+v %v; %v", songs, err, paths)
	}
	albums, err := client.SearchArtistReleaseGroups(context.Background(), id, literal, 20, 0)
	if err != nil || len(albums.Results) != 1 || albums.Results[0].ReleaseGroupMBID != discoverBrowseGroup || !reflect.DeepEqual(paths, []string{"/ws/2/recording", "/ws/2/release-group"}) {
		t.Fatalf("album kind result or dispatch: %+v %v; %v", albums, err, paths)
	}
}

func TestDiscoverBrowseEditionsPageAndExactTrackPlacements(t *testing.T) {
	var starts []time.Time
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		starts = append(starts, time.Now())
		if deadline, ok := req.Context().Deadline(); !ok || time.Until(deadline) > discoverBrowseTimeout {
			t.Fatalf("unbounded provider context: %s", req.URL)
		}
		summary := `"id":"` + browseEdition + `","release-group":{"id":"` + discoverBrowseGroup + `"},"title":"Box Set","date":"2025-06","country":"GB","status":"Official",` + discoverBrowseCredit
		switch req.URL.Path {
		case "/ws/2/release":
			want := url.Values{"release-group": {discoverBrowseGroup}, "inc": {"artist-credits media release-groups"}, "fmt": {"json"}, "limit": {"5"}, "offset": {"7"}}
			if !reflect.DeepEqual(req.URL.Query(), want) {
				t.Fatalf("wrong editions query: %v", req.URL.Query())
			}
			return fixtureResponse(200, `{"release-count":12,"release-offset":7,"releases":[{`+summary+`,"media":[{"position":1,"format":"Vinyl","track-count":2},{"position":2,"format":"Vinyl","track-count":1}]}]}`), nil
		case "/ws/2/release/" + browseEdition:
			want := url.Values{"inc": {"artist-credits recordings release-groups"}, "fmt": {"json"}}
			if !reflect.DeepEqual(req.URL.Query(), want) {
				t.Fatalf("wrong tracklist query: %v", req.URL.Query())
			}
			return fixtureResponse(200, `{`+summary+`,"media":[
				{"position":2,"format":"Vinyl","track-count":1,"track-offset":0,"tracks":[
					{"id":"55555555-5555-4555-8555-555555555555","position":1,"number":"C1","title":"Reprise","length":null,"recording":{"id":"`+browseRecording+`"}}]},
				{"position":1,"format":"Vinyl","track-count":2,"track-offset":0,"tracks":[
					{"id":"66666666-6666-4666-8666-666666666666","position":2,"number":"A2","title":"Main, part II","recording":{"id":"`+browseRecording+`"}},
					{"id":"77777777-7777-4777-8777-777777777777","position":1,"number":"A1","length":5000,"recording":{"id":"`+browseRecording+`","title":"Main"},`+discoverBrowseCredit+`}],
				"pregap":{"id":"88888888-8888-4888-8888-888888888888","position":0,"title":"Hidden","recording":{"id":"`+browseRecording+`"}},
				"data-tracks":[{"id":"99999999-9999-4999-8999-999999999999","position":3,"title":"Data"}]}]}`), nil
		default:
			t.Fatalf("unrelated provider request: %s", req.URL)
			return nil, nil
		}
	}))
	page, err := client.BrowseReleaseGroupEditions(context.Background(), uuid.MustParse(discoverBrowseGroup), 5, 7)
	if err != nil || len(page.Results) != 1 || len(starts) != 1 || page.NextOffset == nil || *page.NextOffset != 8 {
		t.Fatalf("wrong edition page: %+v, %v; %d calls", page, err, len(starts))
	}
	edition := page.Results[0]
	if edition.ReleaseGroupMBID != discoverBrowseGroup || edition.ReleaseMBID != browseEdition || edition.DiscCount != 2 || !reflect.DeepEqual(edition.Formats, []string{"Vinyl"}) || edition.CoverArtURL != "https://coverartarchive.org/release/"+browseEdition+"/front-250" {
		t.Fatalf("wrong edition projection: %+v", edition)
	}
	tracklist, err := client.GetEditionTracklist(context.Background(), uuid.MustParse(edition.ReleaseMBID))
	if err != nil || tracklist.TrackCount != 5 || len(tracklist.Tracks) != 5 || len(starts) != 2 || starts[1].Sub(starts[0]) < time.Second {
		t.Fatalf("wrong tracklist or pacing: %+v, %v; starts %v", tracklist, err, starts)
	}
	tracks := tracklist.Tracks
	for i, want := range [][2]int{{1, 0}, {1, 1}, {1, 2}, {1, 3}, {2, 1}} {
		x := tracks[i]
		if x.DiscPosition != want[0] || x.TrackPosition != want[1] || (i != 3 && x.RecordingMBID != browseRecording) || x.TrackMBID == x.RecordingMBID {
			t.Fatalf("wrong placement %d: %+v", i, x)
		}
	}
	if tracks[0].Kind != "pregap" || tracks[3].Kind != "data" || tracks[1].Title != "Main" || tracks[1].Number != "A1" || tracks[1].Duration == nil || *tracks[1].Duration != 5000 || tracks[4].Duration != nil || tracks[1].TrackMBID == tracks[4].TrackMBID || len(tracks[1].ArtistCredits) != 2 {
		t.Fatalf("track display metadata lost: %+v", tracks)
	}
}

func TestDiscoverBrowseSmallPageRefusesMalformedOverBudgetOrUnavailable(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"wrong_credit", 200, `{"count":1,"offset":0,"recordings":[{"id":"` + browseRecording + `","title":"Unrelated","artist-credit":[{"name":"Selected artist","artist":{"id":"` + discoverBrowseGroup + `"}}]}]}`},
		{"missing_rows", 200, `{"count":0,"offset":0}`},
		{"null_row", 200, `{"count":1,"offset":0,"recordings":[null]}`},
		{"wrong_offset", 200, `{"count":0,"offset":7,"recordings":[]}`},
		{"oversize_complete_stream", 200, `{"count":0,"offset":0,"recordings":[]}` + strings.Repeat(" ", discoverBrowseMaxBytes)},
		{"no_retry", 503, `{"error":"busy"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := NewClientWithTransport(nil, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls++
				return fixtureResponse(tc.status, tc.body), nil
			}))
			page, err := client.SearchArtistRecordings(context.Background(), uuid.MustParse(discoverBrowseArtist), "term", 20, 0)
			if err == nil || page != nil || calls != 1 {
				t.Fatalf("bad provider response accepted or retried: %+v %v; calls %d", page, err, calls)
			}
		})
	}
}

func TestDiscoverBrowseTracklistWireBudgetAndNoRedirect(t *testing.T) {
	valid := `{"id":"` + browseEdition + `","release-group":{"id":"` + discoverBrowseGroup + `"},"title":"Fixture","media":[]}`
	for _, tc := range []struct {
		name    string
		status  int
		body    string
		wantErr bool
	}{
		{"larger_than_small_page", 200, valid + strings.Repeat(" ", discoverBrowseMaxBytes), false},
		{"oversize", 200, valid + strings.Repeat(" ", discoverTracklistMaxBytes), true},
		{"wrong_id", 200, strings.Replace(valid, browseEdition, browseRecording, 1), true},
		{"no_redirect", 301, "", true},
		{"no_retry", 503, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := NewClientWithTransport(nil, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls++
				resp := fixtureResponse(tc.status, tc.body)
				if tc.status == 301 {
					resp.Header.Set("Location", "https://not-contacted.invalid/edition")
				}
				return resp, nil
			}))
			page, err := client.GetEditionTracklist(context.Background(), uuid.MustParse(browseEdition))
			if (err != nil) != tc.wantErr || (page == nil) != tc.wantErr || calls != 1 {
				t.Fatalf("tracklist or attempt result: %+v %v, %d calls", page, err, calls)
			}
		})
	}
}

func TestDiscoverBrowseCancellationStopsProviderAndKeepsContextError(t *testing.T) {
	entered := make(chan struct{})
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		close(entered)
		<-req.Context().Done()
		return nil, req.Context().Err()
	}))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	returned := make(chan error, 1)
	go func() {
		_, err := client.BrowseArtistDiscography(ctx, uuid.MustParse(discoverBrowseArtist), "", 20, 0)
		returned <- err
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("no provider request")
	}
	cancel()
	select {
	case err := <-returned:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("wrong cancellation error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled provider request did not return")
	}
}

func TestDiscoverBrowseTracklistRequiresExplicitCompleteMediaBeforeCache(t *testing.T) {
	const empty = `"track-count":0,"tracks":[]`
	const firstTrack = `{"id":"55555555-5555-4555-8555-555555555555","position":1,"title":"First","recording":{"id":"` + browseRecording + `"}}`
	for _, tc := range []struct{ name, medium string }{
		{"missing_count", `"tracks":[]`},
		{"null_count", `"track-count":null,"tracks":[]`},
		{"missing_array", `"track-count":0`},
		{"null_array", `"track-count":0,"tracks":null`},
		{"partial_array", `"track-count":2,"tracks":[` + firstTrack + `]`},
		{"nonzero_offset", `"track-count":0,"track-offset":1,"tracks":[]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				if cmd == "set" {
					writes.Add(1)
				}
			})
			body := func(medium string) string {
				return `{"id":"` + browseEdition + `","release-group":{"id":"` + discoverBrowseGroup + `"},"title":"Fixture","media":[{"position":1,` + empty + `},{"position":2,` + medium + `}]}`
			}
			calls := 0
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return fixtureResponse(200, body(tc.medium)), nil
				}
				return fixtureResponse(200, body(empty)), nil
			}))
			read := func() (*DiscoverEditionTracklist, error) {
				return client.GetEditionTracklist(context.Background(), uuid.MustParse(browseEdition))
			}
			if got, err := read(); got != nil || !errors.Is(err, errInvalidDiscoverResponse) || writes.Load() != 0 {
				t.Fatalf("incomplete tracklist accepted or cached: %+v, %v, writes %d", got, err, writes.Load())
			}
			for range 2 {
				got, err := read()
				if err != nil || got == nil || got.DiscCount != 2 || got.TrackCount != 0 || got.Tracks == nil || len(got.Tracks) != 0 {
					t.Fatalf("explicitly empty media not accepted: %+v, %v", got, err)
				}
			}
			if calls != 2 || writes.Load() != 1 {
				t.Fatalf("invalid or valid tracklist cache result: %d upstream calls, %d writes", calls, writes.Load())
			}
		})
	}
}

func TestDiscoverBrowseTracklistRequiresCompleteOrdinalsBeforeCache(t *testing.T) {
	const (
		first      = `{"id":"55555555-5555-4555-8555-555555555555","position":1,"number":"A1","title":"First","recording":{"id":"` + browseRecording + `"}}`
		second     = `{"id":"66666666-6666-4666-8666-666666666666","position":2,"number":"B1","title":"Second","recording":{"id":"` + browseRecording + `"}}`
		data       = `{"id":"99999999-9999-4999-8999-999999999999","position":2,"title":"Data"}`
		emptyDisc  = `{"position":1,"track-count":0,"tracks":[]}`
		secondDisc = `{"position":2,"track-count":2,"track-offset":0,"tracks":[` + first + `,` + second + `]}`
		valid      = secondDisc + `,` + emptyDisc
	)
	trackHole := strings.Replace(secondDisc, `"position":2,"number":"B1"`, `"position":3,"number":"B1"`, 1)
	for _, tc := range []struct {
		name, invalid, valid string
		kinds                []string
	}{
		{"medium_hole", strings.Replace(valid, `"position":2`, `"position":3`, 1), valid, []string{"track", "track"}},
		{"track_hole", trackHole + `,` + emptyDisc, valid, []string{"track", "track"}},
		{"data_occupies_ordinal", "", strings.TrimSuffix(trackHole, "}") + `,"data-tracks":[` + data + `]},` + emptyDisc, []string{"track", "data", "track"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(command string) {
				if command == "set" {
					writes.Add(1)
				}
			})
			calls := 0
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls++
				media := tc.valid
				if calls == 1 && tc.invalid != "" {
					media = tc.invalid
				}
				return fixtureResponse(http.StatusOK, `{"id":"`+browseEdition+`","release-group":{"id":"`+discoverBrowseGroup+`"},"title":"Fixture","media":[`+media+`]}`), nil
			}))
			read := func() (*DiscoverEditionTracklist, error) {
				return client.GetEditionTracklist(t.Context(), uuid.MustParse(browseEdition))
			}
			expectedCalls := 1
			if tc.invalid != "" {
				if got, err := read(); got != nil || !errors.Is(err, errInvalidDiscoverResponse) || calls != 1 || writes.Load() != 0 {
					t.Fatalf("ordinal hole accepted or cached: %+v, %v; calls=%d writes=%d", got, err, calls, writes.Load())
				}
				expectedCalls++
			}
			for _, pass := range []string{"provider response", "warm response"} {
				got, err := read()
				if err != nil || got == nil || got.DiscCount != 2 || got.TrackCount != len(tc.kinds) || len(got.Tracks) != len(tc.kinds) || calls != expectedCalls || writes.Load() != 1 {
					t.Fatalf("%s: %+v, %v; calls=%d writes=%d", pass, got, err, calls, writes.Load())
				}
				for i, track := range got.Tracks {
					if track.DiscPosition != 2 || track.TrackPosition != i+1 || track.Kind != tc.kinds[i] {
						t.Fatalf("%s placement %d: %+v", pass, i, track)
					}
				}
			}
		})
	}
}
