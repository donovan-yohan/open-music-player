package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
)

func TestDiscoverPermalinkRelevance(t *testing.T) {
	const query = "Constantly sora remix"
	const exact = "https://soundcloud.com/sorabecareful/constantly-sora-remix"
	const title = "constantly* [free dl] by sora"
	const decoys = `
{"_type":"url","id":"1001","webpage_url":"https://soundcloud.com/fixture/tiffany-day-slayr-constantly","title":"Tiffany Day & Slayr - Constantly"}
{"_type":"url","id":"1002","webpage_url":"https://soundcloud.com/fixture/constantly-other-remix","title":"Constantly (Other Remix)","description":"Constantly sora remix"}
{"_type":"url","id":"1003","webpage_url":"https://soundcloud.com/fixture/constantly-sora-remix-extended","title":"Constantly (Sora Remix Extended)"}
{"_type":"url","id":"1004","webpage_url":"https://soundcloud.com/fixture/sets/constantly-sora-remix","title":"Collection"}
`
	const providerOutput = decoys + `{"_type":"url","id":"1005","webpage_url":"` + exact + `","title":"` + title + `","uploader":"sora","description":"Credits: Tiffany Day & Slayr"}`
	for _, tc := range []struct {
		name, providers, output string
		want                    []string
	}{
		{"provider lane", "soundcloud", providerOutput, []string{"1005", "1001", "1002", "1003", "1004"}},
		{"peer failure", "youtube,soundcloud", providerOutput, []string{"1005", "1001", "1002", "1003", "1004"}},
		{"candidate absent", "soundcloud", decoys, []string{"1001", "1002", "1003", "1004"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cloud := NewYTDLPProvider("soundcloud", "scsearch", "")
			var calls atomic.Int32
			cloud.commandRunner = func(_ context.Context, args []string) ([]byte, error) {
				calls.Add(1)
				want := []string{"--flat-playlist", "--playlist-end", "12", "--dump-json", "--skip-download", "scsearch12:" + query}
				if !slices.Equal(args, want) {
					return nil, fmt.Errorf("unexpected search command arguments: %q", args)
				}
				return []byte(tc.output), nil
			}
			judge := &fakeSourceQualityJudge{}
			service := NewService(ServiceConfig{
				Providers:          []Provider{cloud, fakeProvider{name: "youtube", err: errors.New("fixture outage")}},
				SourceQualityJudge: judge,
			})
			// Observe the raw pool separately from the authenticated Discover result.
			raw := service.SearchSources(t.Context(), query, []string{"soundcloud"}, 12)
			hasExact := slices.ContainsFunc(raw.Results, func(row Candidate) bool { return row.SourceURL == exact })
			recalled := tc.want[0] == "1005"
			if hasExact != recalled || (recalled && raw.Results[0].SourceURL == exact) {
				t.Fatalf("fixture must distinguish a recalled but buried candidate from an absent one: ids=%v", relevanceIDs(raw.Results))
			}

			store := &captureSelectionStore{}
			h := NewHandlersWithAssistAndSelectionStore(service, nil, store)
			params := url.Values{"q": {query}, "providers": {tc.providers}, "limit": {"12"}}
			user := uuid.New()
			r := httptest.NewRequest(http.MethodGet, "/api/v1/discovery/search?"+params.Encode(), nil)
			r = r.WithContext(context.WithValue(r.Context(), auth.UserContextKey, &auth.UserContext{UserID: user}))
			w := httptest.NewRecorder()
			h.Search(w, r)
			var wire searchHTTPResponse
			if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &wire) != nil {
				t.Fatalf("search response: %d %s", w.Code, w.Body.String())
			}
			if calls.Load() != 2 || len(judge.seen) != 0 {
				t.Fatalf("expected one search command per request and no quality judge, got %d commands and %d judged rows", calls.Load(), len(judge.seen))
			}
			rows := make([]Candidate, 0, len(wire.Results))
			for _, row := range wire.Results {
				rows = append(rows, row.Candidate)
			}
			if ids := relevanceIDs(rows); !slices.Equal(ids, tc.want) {
				t.Fatalf("Discover order = %v, want %v (raw provider order = %v)", ids, tc.want, relevanceIDs(raw.Results))
			}
			if recalled {
				row := wire.Results[0]
				if row.SourceURL != exact || row.PreviewSourceURL != exact || row.Title != title || row.Uploader != "sora" || row.Provider != "soundcloud" || !row.Downloadable || row.Playable {
					t.Fatalf("matched source identity or attribution changed: %#v", row)
				}
			}
			session := store.session
			if session == nil || session.UserID != user || session.Query != query || session.Context != "discovery_search" ||
				!wire.SelectionRequired || wire.SelectionSessionID != session.ID.String() || wire.SelectionExpiresAt == nil ||
				!wire.SelectionExpiresAt.Equal(session.ExpiresAt) || wire.RecommendedCandidateID != "" || wire.Query != query {
				t.Fatalf("expected the ordinary neutral source-selection session: %#v", session)
			}
			var saved []Candidate
			if err := json.Unmarshal(session.Candidates, &saved); err != nil || !reflect.DeepEqual(saved, rows) {
				t.Fatalf("selection snapshot does not match returned rows: %v", err)
			}
			if len(wire.Sections) != 1 || wire.Sections[0].Kind != "sources" || len(wire.Sections[0].Items) != len(rows) {
				t.Fatalf("expected source-only sections, got %#v", wire.Sections)
			}
			for i, item := range wire.Sections[0].Items {
				if !reflect.DeepEqual(item.Candidate, &rows[i]) {
					t.Fatalf("source section row %d differs from the wire result", i)
				}
			}
			wantProviders := map[string]string{"soundcloud": ProviderStatusOK}
			if strings.Contains(tc.providers, "youtube") {
				wantProviders["youtube"] = ProviderStatusFailed
			}
			gotProviders := make(map[string]string)
			for _, p := range wire.Providers {
				gotProviders[p.Provider] = p.Status
				if p.Provider == "soundcloud" && p.ResultCount != len(rows) {
					t.Fatalf("SoundCloud result count changed: %+v", p)
				}
			}
			if !reflect.DeepEqual(gotProviders, wantProviders) {
				t.Fatalf("providers = %v, want %v", gotProviders, wantProviders)
			}
		})
	}
}

func relevanceIDs(rows []Candidate) []string {
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.SourceID)
	}
	return ids
}
