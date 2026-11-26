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

	"github.com/google/uuid"
)

const (
	discoverBrowseArtist = "11111111-1111-4111-8111-111111111111"
	discoverBrowseGroup  = "22222222-2222-4222-8222-222222222222"
	discoverBrowseCredit = `"artist-credit":[{"name":"Credited Alias","joinphrase":" & ","artist":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Collaborator"}},{"artist":{"id":"11111111-1111-4111-8111-111111111111","name":"Selected artist"}}]`
)

func TestDiscoverBrowseArtistDiscographyUsesTypedGroupPageAndCache(t *testing.T) {
	isolateFixtureBudgets(t)
	calls := 0
	client := NewClientWithTransport(fixturePublicCache(t), fixtureTransport(func(req *http.Request) (*http.Response, error) {
		calls++
		want := url.Values{"artist": {discoverBrowseArtist}, "type": {"ep"}, "inc": {"artist-credits"}, "fmt": {"json"}, "limit": {"5"}, "offset": {"3"}}
		if req.Method != http.MethodGet || req.URL.Host != "musicbrainz.org" || req.URL.Path != "/ws/2/release-group" || !reflect.DeepEqual(req.URL.Query(), want) {
			t.Errorf("unexpected provider request: %s %s", req.Method, req.URL)
		}
		return fixtureResponse(200, `{"release-group-count":12,"release-group-offset":3,"release-groups":[{"id":"`+discoverBrowseGroup+`","title":"An EP","primary-type":"EP","secondary-types":["Live"],"first-release-date":"2026-03",`+discoverBrowseCredit+`}]}`), nil
	}))
	for range 2 {
		page, err := client.BrowseArtistDiscography(context.Background(), uuid.MustParse(discoverBrowseArtist), "ep", 5, 3)
		if err != nil || page == nil || len(page.Results) != 1 || page.Total != 12 || page.Limit != 5 || page.Offset != 3 || !page.HasMore || page.NextOffset == nil || *page.NextOffset != 4 {
			t.Fatalf("wrong page: %+v, %v", page, err)
		}
		row := page.Results[0]
		if row.ReleaseGroupMBID != discoverBrowseGroup || row.PrimaryType != "EP" || !reflect.DeepEqual(row.SecondaryTypes, []string{"Live"}) || row.FirstReleaseDate != "2026-03" || row.CoverArtURL != "https://coverartarchive.org/release-group/"+discoverBrowseGroup+"/front-250" || row.Artist != "Credited Alias & Selected artist" || len(row.ArtistCredits) != 2 || row.ArtistCredits[1].MBID != discoverBrowseArtist {
			t.Fatalf("wrong group: %+v", row)
		}
	}
	if calls != 1 {
		t.Fatalf("cached page dispatched %d requests, want one", calls)
	}
}

func TestDiscoverBrowseDiscographyChecksCreditsPastDisplayCap(t *testing.T) {
	isolateFixtureBudgets(t)
	const collaborator = `{"artist":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Collaborator"}},`
	body := `{"release-group-count":1,"release-group-offset":0,"release-groups":[{"id":"` + discoverBrowseGroup + `","title":"A Group","primary-type":null,"artist-credit":[` + strings.Repeat(collaborator, maxArtistCredits) + `{"artist":{"id":"` + discoverBrowseArtist + `","name":"Selected artist"}}]}]}`
	client := NewClientWithTransport(nil, fixtureTransport(func(req *http.Request) (*http.Response, error) {
		if req.URL.Query().Has("type") {
			t.Errorf("unfiltered discography unexpectedly sent a type: %s", req.URL)
		}
		return fixtureResponse(200, body), nil
	}))
	page, err := client.BrowseArtistDiscography(context.Background(), uuid.MustParse(discoverBrowseArtist), "", 5, 0)
	if err != nil || len(page.Results) != 1 || !page.Results[0].ArtistCreditsTruncated || len(page.Results[0].ArtistCredits) != maxArtistCredits {
		t.Fatalf("full credits did not attest the unfiltered page: %+v, %v", page, err)
	}
}

func TestDiscoverBrowseDiscographyRejectsWrongCreditOrPrimaryTypeBeforeCache(t *testing.T) {
	const epTypes = `"primary-type":"EP","secondary-types":["Live"]`
	for _, tc := range []struct{ name, types, credits string }{
		{"wrong_credit", epTypes, strings.Replace(discoverBrowseCredit, discoverBrowseArtist, browseRecording, 1)},
		{"wrong_primary_despite_matching_secondary", `"primary-type":"Album","secondary-types":["EP"]`, discoverBrowseCredit},
		{"missing_primary", `"secondary-types":["Live"]`, discoverBrowseCredit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			isolateFixtureBudgets(t)
			var writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(cmd string) {
				if cmd == "set" {
					writes.Add(1)
				}
			})
			pageBody := func(types, credits string) string {
				return `{"release-group-count":1,"release-group-offset":0,"release-groups":[{"id":"` + discoverBrowseGroup + `","title":"A Group",` + types + `,` + credits + `}]}`
			}
			calls := 0
			client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return fixtureResponse(200, pageBody(tc.types, tc.credits)), nil
				}
				return fixtureResponse(200, pageBody(epTypes, discoverBrowseCredit)), nil
			}))
			read := func() (*DiscoverBrowsePage[DiscoverReleaseGroup], error) {
				return client.BrowseArtistDiscography(context.Background(), uuid.MustParse(discoverBrowseArtist), DiscographyEP, 5, 0)
			}
			if page, err := read(); page != nil || !errors.Is(err, errInvalidDiscoverResponse) || writes.Load() != 0 {
				t.Fatalf("unattested discography accepted or cached: %+v, %v, writes %d", page, err, writes.Load())
			}
			for range 2 {
				page, err := read()
				if err != nil || len(page.Results) != 1 || len(page.Results[0].ArtistCredits) != 2 || page.Results[0].PrimaryType != "EP" || page.Results[0].ArtistCredits[1].MBID != discoverBrowseArtist {
					t.Fatalf("legitimate collaboration did not recover: %+v, %v", page, err)
				}
			}
			if calls != 2 || writes.Load() != 1 {
				t.Fatalf("invalid or valid browse cache result: %d upstream calls, %d writes", calls, writes.Load())
			}
		})
	}
}
