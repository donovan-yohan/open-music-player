package musicbrainz

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"
)

const (
	discoverFixtureRelease = `"id":"` + browseEdition + `","release-group":{"id":"` + discoverBrowseGroup + `"}`
	discoverFixtureTrackID = "55555555-5555-4555-8555-555555555555"
)

func TestDiscoverBrowseTracklistFetchErrorsKeepOperationAndCause(t *testing.T) {
	cause := errors.New("fixture tracklist failure")
	for _, tc := range []struct {
		name, operation string
		transport       fixtureTransport
	}{
		{"request", "create MusicBrainz tracklist request", nil},
		{"transport", "execute MusicBrainz tracklist request", func(*http.Request) (*http.Response, error) { return nil, cause }},
		{"body", "read MusicBrainz tracklist response body", func(*http.Request) (*http.Response, error) {
			resp := fixtureResponse(http.StatusOK, "")
			resp.Body = discoverErrorBody{err: cause}
			return resp, nil
		}},
		{"not_found", "", func(*http.Request) (*http.Response, error) { return fixtureResponse(http.StatusNotFound, ""), nil }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
				calls.Add(1)
				if tc.transport == nil {
					return nil, errors.New("malformed URL dispatched")
				}
				return tc.transport(req)
			}))
			if tc.transport == nil {
				_, err := client.fetchDiscoverTracklist(t.Context(), ":bad-url")
				var urlErr *url.Error
				if !errors.As(err, &urlErr) || errors.Unwrap(err) != urlErr || !strings.Contains(err.Error(), tc.operation) || calls.Load() != 0 {
					t.Fatalf("request error lost operation/cause, or dispatched: %v (calls=%d)", err, calls.Load())
				}
				return
			}
			result, err := client.GetEditionTracklist(t.Context(), uuid.MustParse(browseEdition))
			if tc.name == "not_found" {
				if result != nil || !errors.Is(err, ErrNotFound) || calls.Load() != 1 {
					t.Fatalf("404 mapped to %v, %v, calls=%d", result, err, calls.Load())
				}
				return
			}
			if result != nil || !errors.Is(err, cause) || !strings.Contains(err.Error(), tc.operation) || calls.Load() != 1 {
				t.Fatalf("fetch error lost operation/cause: %v, %v, calls=%d", result, err, calls.Load())
			}
		})
	}
}

type discoverErrorBody struct{ err error }

func (b discoverErrorBody) Read([]byte) (int, error) { return 0, b.err }
func (b discoverErrorBody) Close() error             { return nil }

func TestDiscoverBrowseTracklistAcceptsSerializerOmissionAtExplicitZero(t *testing.T) {
	for _, tc := range []struct {
		name, extras string
		kinds        []string
		positions    []int
	}{
		{"empty", "", nil, nil},
		{"pregap_and_data", `,"pregap":{"id":"88888888-8888-4888-8888-888888888888","position":0,"title":"Hidden","recording":{"id":"` + browseRecording + `"}},` +
			`"data-tracks":[{"id":"` + discoverFixtureTrackID + `","position":1,"title":"Data"}]`, []string{"pregap", "data"}, []int{0, 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls, writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				if cmd == "set" {
					writes.Add(1)
				}
			})
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return fixtureResponse(http.StatusOK, `{`+discoverFixtureRelease+`,"title":"Fixture","media":[{"position":1,"track-count":0`+tc.extras+`}]}`), nil
			}))
			for _, read := range []string{"cold", "warm"} {
				got, err := client.GetEditionTracklist(t.Context(), uuid.MustParse(browseEdition))
				if err != nil || got == nil || got.DiscCount != 1 || got.TrackCount != len(tc.kinds) || got.Tracks == nil || len(got.Tracks) != len(tc.kinds) || calls.Load() != 1 || writes.Load() != 1 {
					t.Fatalf("%s serializer-shaped tracklist: %+v, %v; calls=%d writes=%d", read, got, err, calls.Load(), writes.Load())
				}
				for i, track := range got.Tracks {
					if track.DiscPosition != 1 || track.TrackPosition != tc.positions[i] || track.Kind != tc.kinds[i] {
						t.Fatalf("%s placement %d: %+v", read, i, track)
					}
				}
			}
		})
	}
}

func TestDiscoverBrowseRejectsBlankTitlesBeforeCache(t *testing.T) {
	for _, tc := range []struct {
		name string
		body func(title string) string
		read func(*testing.T, *Client) (string, error)
	}{
		{"recording", func(title string) string {
			return fmt.Sprintf(`{"count":1,"offset":0,"recordings":[{"id":"%s","title":%q,%s}]}`, browseRecording, title, discoverBrowseCredit)
		}, func(t *testing.T, c *Client) (string, error) {
			p, err := c.SearchArtistRecordings(t.Context(), uuid.MustParse(discoverBrowseArtist), "term", 1, 0)
			if p == nil || len(p.Results) != 1 {
				return "", err
			}
			return p.Results[0].Title, err
		}},
		{"discography", func(title string) string {
			return fmt.Sprintf(`{"release-group-count":1,"release-group-offset":0,"release-groups":[{"id":"%s","title":%q,%s}]}`, discoverBrowseGroup, title, discoverBrowseCredit)
		}, func(t *testing.T, c *Client) (string, error) {
			p, err := c.BrowseArtistDiscography(t.Context(), uuid.MustParse(discoverBrowseArtist), "", 1, 0)
			if p == nil || len(p.Results) != 1 {
				return "", err
			}
			return p.Results[0].Title, err
		}},
		{"album_search", func(title string) string {
			return fmt.Sprintf(`{"count":1,"offset":0,"release-groups":[{"id":"%s","title":%q,%s}]}`, discoverBrowseGroup, title, discoverBrowseCredit)
		}, func(t *testing.T, c *Client) (string, error) {
			p, err := c.SearchArtistReleaseGroups(t.Context(), uuid.MustParse(discoverBrowseArtist), "term", 1, 0)
			if p == nil || len(p.Results) != 1 {
				return "", err
			}
			return p.Results[0].Title, err
		}},
		{"edition", func(title string) string {
			return fmt.Sprintf(`{"release-count":1,"release-offset":0,"releases":[{%s,"title":%q,"media":[]}]}`, discoverFixtureRelease, title)
		}, func(t *testing.T, c *Client) (string, error) {
			p, err := c.BrowseReleaseGroupEditions(t.Context(), uuid.MustParse(discoverBrowseGroup), 1, 0)
			if p == nil || len(p.Results) != 1 {
				return "", err
			}
			return p.Results[0].Title, err
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			const want = "  Verbatim title  "
			var calls, writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				if cmd == "set" {
					writes.Add(1)
				}
			})
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				title := want
				if calls.Add(1) == 1 {
					title = " \t \u2003 "
				}
				return fixtureResponse(http.StatusOK, tc.body(title)), nil
			}))
			if title, err := tc.read(t, client); title != "" || !errors.Is(err, errInvalidDiscoverResponse) || calls.Load() != 1 || writes.Load() != 0 {
				t.Fatalf("blank title accepted or cached: %q, %v; calls=%d writes=%d", title, err, calls.Load(), writes.Load())
			}
			for _, read := range []string{"cold recovery", "warm"} {
				if title, err := tc.read(t, client); title != want || err != nil || calls.Load() != 2 || writes.Load() != 1 {
					t.Fatalf("%s: title=%q error=%v calls=%d writes=%d", read, title, err, calls.Load(), writes.Load())
				}
			}
		})
	}
}

func TestDiscoverBrowseTracklistChoosesFirstNonblankVerbatimTitle(t *testing.T) {
	for _, tc := range []struct{ name, placement, recording, want string }{
		{"placement", "  Mix A  ", " Recording ", "  Mix A  "},
		{"recording_fallback", " \t\u2003 ", " Recording ", " Recording "},
		{"no_eligible_title", " \t ", " \u2003 ", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls, writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				if cmd == "set" {
					writes.Add(1)
				}
			})
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return fixtureResponse(http.StatusOK, fmt.Sprintf(`{%s,"title":"Fixture","media":[{"position":1,"track-count":1,"tracks":[{"id":"%s","position":1,"title":%q,"recording":{"id":"%s","title":%q}}]}]}`,
					discoverFixtureRelease, discoverFixtureTrackID, tc.placement, browseRecording, tc.recording)), nil
			}))
			read := func() (*DiscoverEditionTracklist, error) {
				return client.GetEditionTracklist(t.Context(), uuid.MustParse(browseEdition))
			}
			if tc.want == "" {
				if got, err := read(); got != nil || !errors.Is(err, errInvalidDiscoverResponse) || writes.Load() != 0 || calls.Load() != 1 {
					t.Fatalf("blank titles accepted or cached: %+v %v; calls=%d writes=%d", got, err, calls.Load(), writes.Load())
				}
				return
			}
			for _, path := range []string{"cold", "warm"} {
				got, err := read()
				if err != nil || got == nil || got.TrackCount != 1 || len(got.Tracks) != 1 || got.Tracks[0].Title != tc.want || calls.Load() != 1 || writes.Load() != 1 {
					t.Fatalf("%s title: %+v %v; calls=%d writes=%d", path, got, err, calls.Load(), writes.Load())
				}
			}
		})
	}
}
