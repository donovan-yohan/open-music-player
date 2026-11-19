package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
)

type previewSearchProvider struct {
	name string
	rows []discovery.Candidate
}

func (p previewSearchProvider) Name() string { return p.name }
func (p previewSearchProvider) Search(context.Context, string, int) ([]discovery.Candidate, error) {
	return p.rows, nil
}

type previewSearchSessions chan db.SourceSelectionSession

func (s previewSearchSessions) CreateSession(_ context.Context, session *db.SourceSelectionSession) error {
	session.ID = uuid.New()
	s <- *session
	return nil
}

func TestDiscoveryPreviewSearchSourceKey(t *testing.T) {
	const (
		short = "https://youtu.be/SQPreview01"
		music = "https://music.youtube.com/watch?v=SQPreview01"
		api   = "https://api.soundcloud.com/tracks/123"
	)
	cases := []struct{ name, provider, source, key string }{
		{"short with share tracking", "youtube", short + "?si=fixture", previewSource},
		{"decorated watch", "youtube", "https://www.youtube.com/watch?utm_source=fixture&v=SQPreview01", previewSource},
		{"exact music host", "youtube", music, music},
		{"decorated music host", "youtube", music + "&si=fixture", music},
		{"conflicting video IDs", "youtube", previewSource + "&v=SQPreview02", ""},
		{"conflicting short query", "youtube", short + "?v=SQPreview02", ""},
		{"non-watch path", "youtube", "https://www.youtube.com/watch-extra?v=SQPreview01", ""},
		{"YouTube playlist", "youtube", "https://www.youtube.com/playlist?list=fixture", ""},
		{"playlist context", "youtube", previewSource + "&list=fixture", ""},
		{"malformed tracking query", "youtube", short + "?si=%ZZ", ""},
		{"escaped video path", "youtube", "https://youtu.be/%53QPreview01", ""},
		{"malformed video ID", "youtube", "https://youtu.be/short", ""},
		{"foreign host", "youtube", "https://www.youtube.com.invalid/watch?v=SQPreview01", ""},
		{"credentials", "youtube", "https://user@youtu.be/SQPreview01", ""},
		{"empty fragment", "youtube", short + "#", ""},
		{"size bound", "youtube", short + "?si=" + strings.Repeat("x", 4096), ""},
		{"SoundCloud URL in YouTube row", "youtube", previewSoundCloud, ""},
		{"decorated permalink", "soundcloud", previewSoundCloud + "?si=fixture&utm_medium=text", previewSoundCloud},
		{"exact numeric API key", "soundcloud", api, api},
		{"SoundCloud redirect", "soundcloud", "https://on.soundcloud.com/abcde", ""},
		{"SoundCloud playlist", "soundcloud", "https://soundcloud.com/sq-fixture/sets/fixture", ""},
		{"SoundCloud profile page", "soundcloud", "https://soundcloud.com/sq-fixture/popular-tracks", ""},
		{"SoundCloud extra segment", "soundcloud", previewSoundCloud + "/extra", ""},
		{"SoundCloud secret token", "soundcloud", previewSoundCloud + "?secret_token=fixture", ""},
		{"decorated API key", "soundcloud", api + "?si=fixture", ""},
		{"nonnumeric API key", "soundcloud", "https://api.soundcloud.com/tracks/abc", ""},
		{"YouTube URL in SoundCloud row", "soundcloud", short, ""},
	}
	youtube, soundcloud := previewSearchProvider{name: "youtube"}, previewSearchProvider{name: "soundcloud"}
	wantRows := make([]discovery.Candidate, 0, len(cases))
	for i, tc := range cases {
		candidate := discovery.Candidate{
			CandidateID: "fixture-option-" + strconv.Itoa(i), Provider: tc.provider,
			SourceURL: tc.source, Title: tc.name, Downloadable: true,
		}
		wantRows = append(wantRows, candidate)
		if tc.provider == "youtube" {
			youtube.rows = append(youtube.rows, candidate)
		} else {
			soundcloud.rows = append(soundcloud.rows, candidate)
		}
	}
	wantSnapshot, err := json.Marshal(wantRows)
	if err != nil {
		t.Fatal(err)
	}
	store := make(previewSearchSessions, 2)
	service := discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{youtube, soundcloud}})
	cfg, token := mountPreview(t)
	cfg.DiscoveryHandlers = discovery.NewHandlersWithAssistAndSelectionStore(service, nil, store)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	client := server.Client()
	client.Timeout = 5 * time.Second
	url := server.URL + "/api/v1/discovery/search?q=fixture&providers=youtube,soundcloud&limit=25"
	get := func(bearer string) *http.Response {
		t.Helper()
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
		if err != nil {
			t.Fatal(err)
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	unauth := get("")
	unauth.Body.Close()
	if unauth.StatusCode != http.StatusUnauthorized || len(store) != 0 {
		t.Fatalf("unauthenticated GET: status=%d, sessions=%d", unauth.StatusCode, len(store))
	}
	res := get(token)
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("authenticated GET: status=%d", res.StatusCode)
	}
	var wire struct {
		discovery.SearchResponse
		Results []json.RawMessage `json:"results"`
	}
	if err := json.NewDecoder(res.Body).Decode(&wire); err != nil {
		t.Fatal(err)
	}
	if len(store) != 1 {
		t.Fatalf("persisted %d sessions, want one", len(store))
	}
	session := <-store
	if !bytes.Equal(wantSnapshot, session.Candidates) {
		t.Fatalf("selection snapshot bytes changed: got %d bytes, want %d", len(session.Candidates), len(wantSnapshot))
	}
	if !wire.SelectionRequired || wire.SelectionSessionID != session.ID.String() || session.UserID == uuid.Nil ||
		session.Query != "fixture" || session.Context != "discovery_search" || wire.Query != session.Query ||
		wire.SelectionExpiresAt == nil || !wire.SelectionExpiresAt.Equal(session.ExpiresAt) ||
		wire.RecommendedCandidateID != "" || session.RecommendedCandidateID != "" {
		t.Fatal("neutral selection session envelope changed")
	}
	if len(wire.Results) != len(cases) {
		t.Fatalf("received %d rows, want %d", len(wire.Results), len(cases))
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var row struct {
				discovery.Candidate
				PreviewSourceURL string `json:"previewSourceUrl"`
			}
			if err := json.Unmarshal(wire.Results[i], &row); err != nil {
				t.Fatal(err)
			}
			legacy, err := json.Marshal(row.Candidate)
			want, wantErr := json.Marshal(wantRows[i])
			if err != nil || wantErr != nil || !bytes.Equal(legacy, want) {
				t.Fatal("original result fields or order changed")
			}
			if tc.key == "" && bytes.Contains(wire.Results[i], []byte(`"previewSourceUrl"`)) {
				t.Fatal("unsafe preview key was not omitted")
			}
			if row.PreviewSourceURL != tc.key {
				t.Fatalf("previewSourceUrl = %q, want %q", row.PreviewSourceURL, tc.key)
			}
			switch tc.key {
			case previewSource, previewSoundCloud:
				data, rate, frames := previewStereo, 48000, 36000
				if tc.key == previewSoundCloud {
					data, rate, frames = previewMono, 44100, 11025
				}
				clip := doPreview(t, client, server.URL, token, previewBody(row.PreviewSourceURL))
				defer clip.Body.Close()
				assertPreviewHeaders(t, clip, len(data), rate, frames)
				if got, err := io.ReadAll(clip.Body); err != nil || !bytes.Equal(got, data) {
					t.Fatalf("returned key did not stream verified fixture bytes: %v", err)
				}
			case music, api: // Valid keys do not imply that these clips are mounted.
				assertPreviewError(t, doPreview(t, client, server.URL, token, previewBody(row.PreviewSourceURL)), http.StatusNotFound)
			}
			if tc.key != "" && tc.source != tc.key {
				assertPreviewError(t, doPreview(t, client, server.URL, token, previewBody(row.SourceURL)), http.StatusNotFound)
			}
		})
	}
	if len(store) != 0 || !bytes.Equal(wantSnapshot, session.Candidates) {
		t.Fatal("preview changed selection state")
	}
}
