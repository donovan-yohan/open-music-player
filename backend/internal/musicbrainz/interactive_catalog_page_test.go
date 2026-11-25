package musicbrainz

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestInteractiveCatalogRetriesWithoutCachingMalformedPage(t *testing.T) {
	const (
		query = "isolated cache"
		limit = 8
		id    = "6f12404a-c015-4b05-bc96-33594ade1227"
	)
	for _, tc := range []struct {
		entity, listField, valid, want, malformedWarm string
		search                                        func(*Client, context.Context, bool) (string, error)
	}{
		{
			entity: "artist", listField: "artists", valid: `{"count":0,"offset":0,"artists":[]}`,
			malformedWarm: `{"total":0,"limit":8,"offset":0}`,
			search: func(c *Client, ctx context.Context, interactive bool) (string, error) {
				if interactive {
					return interactivePageTestResult(c.SearchInteractiveArtists(ctx, query, limit, 0))
				}
				return interactivePageTestResult(c.SearchArtists(ctx, query, limit, 0, false))
			},
		},
		{
			entity: "release-group", listField: "release-groups", want: id,
			valid:         `{"count":1,"offset":0,"release-groups":[{"id":"` + id + `","title":"Amnesiac"}]}`,
			malformedWarm: `{"results":[{"mbid":"invalid","title":"Amnesiac"}],"total":1,"limit":8,"offset":0}`,
			search: func(c *Client, ctx context.Context, interactive bool) (string, error) {
				if interactive {
					return interactivePageTestResult(c.SearchInteractiveAlbums(ctx, query, limit, 0))
				}
				return interactivePageTestResult(c.SearchAlbums(ctx, query, limit, 0, false))
			},
		},
	} {
		t.Run(tc.entity, func(t *testing.T) {
			isolateFixtureBudgets(t)
			var writes atomic.Int32
			store := fixturePublicCacheWithCommand(t, func(command string) {
				if command == "set" {
					writes.Add(1)
				}
			})
			ctx := t.Context()
			var calls int
			client := NewClientWithTransport(store, fixtureTransport(func(req *http.Request) (*http.Response, error) {
				calls++
				if req.URL.Path != "/ws/2/"+tc.entity || req.URL.Query().Get("query") != query || req.URL.Query().Get("limit") != "8" || req.URL.Query().Get("offset") != "0" {
					t.Errorf("unexpected upstream URL: %s", req.URL)
				}
				if calls == 1 {
					// An explicit count and offset do not make a missing list empty.
					return fixtureResponse(http.StatusOK, `{"count":0,"offset":0}`), nil
				}
				return fixtureResponse(http.StatusOK, tc.valid), nil
			}))
			interactiveKey := client.buildCacheKey("interactive-catalog-v1-"+tc.entity, query, limit, 0)
			if err := store.Set(ctx, interactiveKey, tc.malformedWarm, time.Hour); err != nil {
				t.Fatal(err)
			}
			before := writes.Load()
			if got, err := tc.search(client, ctx, true); !errors.Is(err, errInteractiveCatalogPage) || calls != 1 {
				t.Fatalf("missing %s was accepted or masked by an invalid warm entry: %q, %v, calls=%d", tc.listField, got, err, calls)
			}
			if value, ok := store.Get(ctx, interactiveKey); !ok || value != tc.malformedWarm || writes.Load() != before {
				t.Fatalf("malformed cold payload wrote to cache: %q, hit=%v, added writes=%d", value, ok, writes.Load()-before)
			}
			// The ordinary endpoint must still use its existing populated namespace.
			legacyKey := legacySearchKey(tc.entity, query, limit, 0)
			const legacy = `{"results":[{"mbid":"legacy","name":"Legacy","title":"Legacy"}],"total":1}`
			if err := store.Set(ctx, legacyKey, legacy, time.Hour); err != nil {
				t.Fatal(err)
			}
			for _, pass := range []string{"corrected retry", "warm"} {
				if got, err := tc.search(client, ctx, true); err != nil || got != tc.want || calls != 2 {
					t.Fatalf("%s returned %q, %v; calls=%d", pass, got, err, calls)
				}
			}
			if got, err := tc.search(client, ctx, false); err != nil || got != "legacy" || calls != 2 {
				t.Fatalf("legacy behavior changed: %q, %v; calls=%d", got, err, calls)
			}
			if value, ok := store.Get(ctx, legacyKey); !ok || value != legacy {
				t.Fatalf("legacy cache was changed: %q, %v", value, ok)
			}
		})
	}
}

func TestInteractiveCatalogRequiresBrowseableIDsBeforeCache(t *testing.T) {
	const (
		query  = "browseable catalog ids"
		limit  = 8
		id     = "6f12404a-c015-4b05-bc96-33594ade1227"
		credit = "0aa95acf-6655-45f3-a249-b411040709cf"
	)
	for _, tc := range []struct{ name, entity, primary, artist string }{
		{"uppercase_artist", "artist", strings.ToUpper(id), ""},
		{"uppercase_release_group", "release-group", strings.ToUpper(id), credit},
		{"invalid_first_credit", "release-group", id, "not-a-MBID"},
		{"uppercase_first_credit", "release-group", id, strings.ToUpper(credit)},
		{"zero_first_credit", "release-group", id, "00000000-0000-0000-0000-000000000000"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			wirePage := func(primary, artist string) string {
				if tc.entity == "artist" {
					return fmt.Sprintf(`{"count":1,"offset":0,"artists":[{"id":%q,"name":"Artist"}]}`, primary)
				}
				return fmt.Sprintf(`{"count":1,"offset":0,"release-groups":[{"id":%q,"title":"Album","artist-credit":[{"artist":{"id":%q,"name":"Artist"}}]}]}`, primary, artist)
			}
			for _, warm := range []bool{false, true} {
				name := "cold"
				if warm {
					name = "warm"
				}
				t.Run(name, func(t *testing.T) {
					isolateFixtureBudgets(t)
					var writes atomic.Int32
					store := fixturePublicCacheWithCommand(t, func(command string) {
						if command == "set" {
							writes.Add(1)
						}
					})
					calls := 0
					client := NewClientWithTransport(store, fixtureTransport(func(*http.Request) (*http.Response, error) {
						calls++
						if !warm && calls == 1 {
							return fixtureResponse(http.StatusOK, wirePage(tc.primary, tc.artist)), nil
						}
						return fixtureResponse(http.StatusOK, wirePage(id, credit)), nil
					}))
					ctx := t.Context()
					key := client.buildCacheKey("interactive-catalog-v1-"+tc.entity, query, limit, 0)
					if warm {
						stored := fmt.Sprintf(`{"results":[{"mbid":%q,"name":"Artist","title":"Album","artistMbid":%q}],"total":1,"limit":8,"offset":0}`, tc.primary, tc.artist)
						if err := store.Set(ctx, key, stored, time.Hour); err != nil {
							t.Fatal(err)
						}
					}
					read := func() (string, error) {
						if tc.entity == "artist" {
							return interactivePageTestResult(client.SearchInteractiveArtists(ctx, query, limit, 0))
						}
						page, err := client.SearchInteractiveAlbums(ctx, query, limit, 0)
						primary, err := interactivePageTestResult(page, err)
						if err != nil || primary == "" {
							return primary, err
						}
						return primary + "/" + page.Results[0].ArtistMBID, nil
					}
					want, expectedCalls := id, 1
					if tc.entity == "release-group" {
						want += "/" + credit
					}
					before := writes.Load()
					if !warm {
						if got, err := read(); got != "" || !errors.Is(err, errInteractiveCatalogPage) || calls != 1 || writes.Load() != before {
							t.Fatalf("invalid provider identity accepted or cached: %q, %v; calls=%d writes=%d", got, err, calls, writes.Load()-before)
						}
						expectedCalls++
					}
					for _, pass := range []string{"canonical provider page", "canonical warm page"} {
						if got, err := read(); got != want || err != nil || calls != expectedCalls || writes.Load() != before+1 {
							t.Fatalf("%s: %q, %v; calls=%d writes=%d", pass, got, err, calls, writes.Load()-before)
						}
					}
				})
			}
		})
	}
}

func TestInteractiveCatalogPageRejectsMalformedProviderEnvelopeAndRows(t *testing.T) {
	const id = "6f12404a-c015-4b05-bc96-33594ade1227"
	for _, family := range []struct {
		list, label string
		decode      func([]byte, int, int) (string, error)
	}{
		{"artists", "name", func(body []byte, limit, offset int) (string, error) {
			return interactivePageTestResult(decodeInteractiveArtistPage(body, limit, offset))
		}},
		{"release-groups", "title", func(body []byte, limit, offset int) (string, error) {
			return interactivePageTestResult(decodeInteractiveAlbumPage(body, limit, offset))
		}},
	} {
		t.Run(family.list, func(t *testing.T) {
			validRow := `{"id":"` + id + `","` + family.label + `":"Catalog title"}`
			list := `"` + family.list + `":`
			for _, tc := range []struct{ name, body string }{
				{"null_envelope", `null`},
				{"missing_list", `{"count":0,"offset":0}`},
				{"null_list", `{"count":0,"offset":0,` + list + `null}`},
				{"missing_count", `{"offset":0,` + list + `[]}`},
				{"null_count", `{"count":null,"offset":0,` + list + `[]}`},
				{"negative_count", `{"count":-1,"offset":0,` + list + `[]}`},
				{"missing_offset", `{"count":0,` + list + `[]}`},
				{"null_offset", `{"count":0,"offset":null,` + list + `[]}`},
				{"wrong_offset", `{"count":2,"offset":1,` + list + `[` + validRow + `]}`},
				{"less_count_than_rows", `{"count":0,"offset":0,` + list + `[` + validRow + `]}`},
				{"empty_before_end", `{"count":2,"offset":0,` + list + `[]}`},
				{"exceeds_limit", `{"count":3,"offset":0,` + list + `[` + validRow + `,` + validRow + `,` + validRow + `]}`},
				{"null_row", `{"count":1,"offset":0,` + list + `[null]}`},
				{"invalid_id", `{"count":1,"offset":0,` + list + `[` + strings.Replace(validRow, id, "not-a-MBID", 1) + `]}`},
				{"nil_id", `{"count":1,"offset":0,` + list + `[` + strings.Replace(validRow, id, "00000000-0000-0000-0000-000000000000", 1) + `]}`},
				{"blank_label", `{"count":1,"offset":0,` + list + `[` + strings.Replace(validRow, "Catalog title", ` \t `, 1) + `]}`},
				{"missing_label", `{"count":1,"offset":0,` + list + `[{"id":"` + id + `"}]}`},
				{"partially_malformed", `{"count":2,"offset":0,` + list + `[` + validRow + `,{}]}`},
			} {
				t.Run(tc.name, func(t *testing.T) {
					if _, err := family.decode([]byte(tc.body), 2, 0); !errors.Is(err, errInteractiveCatalogPage) {
						t.Fatalf("malformed provider page not rejected: %v", err)
					}
				})
			}
			for _, tc := range []struct{ name, body, want string }{
				{"exhausted", `{"count":3,"offset":8,` + list + `[]}`, ""},
				{"short_page", `{"count":17,"offset":8,` + list + `[` + validRow + `]}`, id},
			} {
				t.Run(tc.name, func(t *testing.T) {
					if got, err := family.decode([]byte(tc.body), 8, 8); err != nil || got != tc.want {
						t.Fatalf("valid provider page not retained: %q, %v", got, err)
					}
				})
			}
		})
	}
}

func interactivePageTestResult[T ArtistResult | AlbumResult](page *SearchResponse[T], err error) (string, error) {
	if err != nil {
		return "", err
	}
	if page == nil || page.Results == nil || len(page.Results) > 1 {
		return "", fmt.Errorf("unexpected page: %+v", page)
	}
	if len(page.Results) == 0 {
		return "", nil
	}
	if artist, ok := any(page.Results[0]).(ArtistResult); ok {
		return artist.MBID, nil
	}
	return any(page.Results[0]).(AlbumResult).MBID, nil
}
