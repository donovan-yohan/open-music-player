package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type fakeProvider struct {
	name  string
	items []Candidate
	err   error
	delay time.Duration
}

type captureSelectionStore struct {
	session *db.SourceSelectionSession
	err     error
}

func (s *captureSelectionStore) CreateSession(_ context.Context, session *db.SourceSelectionSession) error {
	s.session = session
	if session.ID == uuid.Nil {
		session.ID = uuid.New()
	}
	return s.err
}

func (p fakeProvider) Name() string { return p.name }
func (p fakeProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	if p.delay > 0 {
		select {
		case <-time.After(p.delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if p.err != nil {
		return nil, p.err
	}
	return p.items, nil
}

func TestServiceSearchProviderFailureIsIsolated(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "one", Downloadable: true}}},
			fakeProvider{name: "soundcloud", err: errors.New("boom")},
		},
		DefaultProviders: []string{"youtube", "soundcloud"},
	})

	resp := svc.Search(context.Background(), "one", nil, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("expected one successful result, got %d", len(resp.Results))
	}
	if len(resp.Providers) != 2 {
		t.Fatalf("expected two provider summaries, got %d", len(resp.Providers))
	}
	var failed bool
	for _, provider := range resp.Providers {
		if provider.Provider == "soundcloud" && provider.Status == ProviderStatusFailed && provider.Error != nil {
			failed = true
		}
	}
	if !failed {
		t.Fatalf("expected soundcloud failure summary")
	}
}

func TestServiceSearchProviderTimeout(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers:          []Provider{fakeProvider{name: "slow", delay: 50 * time.Millisecond}},
		DefaultProviders:   []string{"slow"},
		PerProviderTimeout: 5 * time.Millisecond,
		OverallTimeout:     100 * time.Millisecond,
	})
	resp := svc.Search(context.Background(), "slow", nil, 10)
	if len(resp.Providers) != 1 {
		t.Fatalf("expected one provider summary")
	}
	if resp.Providers[0].Status != ProviderStatusTimeout {
		t.Fatalf("expected timeout, got %s", resp.Providers[0].Status)
	}
}

func TestServiceSearchUnknownProvider(t *testing.T) {
	svc := NewService(ServiceConfig{})
	resp := svc.Search(context.Background(), "x", []string{"bogus"}, 10)
	if len(resp.Providers) != 1 || resp.Providers[0].Status != ProviderStatusUnsupported {
		t.Fatalf("expected unsupported provider summary, got %#v", resp.Providers)
	}
}

type countingProvider struct {
	name  string
	calls atomic.Int32
}

type recordingProvider struct {
	name  string
	items []Candidate
	calls atomic.Int32
}

func (p *recordingProvider) Name() string { return p.name }
func (p *recordingProvider) Search(_ context.Context, _ string, _ int) ([]Candidate, error) {
	p.calls.Add(1)
	return p.items, nil
}

func (p *countingProvider) Name() string { return p.name }
func (p *countingProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	p.calls.Add(1)
	return []Candidate{{CandidateID: p.name + ":1", Provider: p.name, SourceURL: "https://example.invalid/1", Title: query, Downloadable: true}}, nil
}

func TestServiceSearchDedupesRepeatedRequestedProviders(t *testing.T) {
	youtube := &countingProvider{name: "youtube"}
	svc := NewService(ServiceConfig{Providers: []Provider{youtube}, DefaultProviders: []string{"youtube"}})

	resp := svc.Search(context.Background(), "same", []string{"youtube", " youtube ", "youtube"}, 10)

	if calls := youtube.calls.Load(); calls != 1 {
		t.Fatalf("youtube Search calls = %d, want 1", calls)
	}
	if len(resp.Providers) != 1 || resp.Providers[0].Provider != "youtube" {
		t.Fatalf("provider summaries = %#v, want exactly one youtube summary", resp.Providers)
	}
}

func TestYouTubeProviderAcquiresYouTubeMusicSongsBeforeRanking(t *testing.T) {
	video := &recordingProvider{name: "youtube-video", items: []Candidate{{
		CandidateID: "youtube:WcHW89jq1kk", Provider: "youtube", SourceID: "WcHW89jq1kk",
		SourceURL: "https://www.youtube.com/watch?v=WcHW89jq1kk", Title: "Speakerphone (Official Video)",
		Uploader: "Kylie Minogue", DurationMs: 226000, Downloadable: true,
	}}}
	music := &recordingProvider{name: "youtube-music", items: []Candidate{{
		CandidateID: "youtube:ipLo9enSiB4", Provider: "youtube", SourceID: "ipLo9enSiB4",
		SourceURL: "https://www.youtube.com/watch?v=ipLo9enSiB4", Title: "Speakerphone", Artist: "Kylie Minogue",
		Uploader: "Kylie Minogue - Topic", DurationMs: 205000, Downloadable: true,
		Metadata: map[string]interface{}{"description": "Provided to YouTube by Parlophone Records\\nAuto-generated by YouTube", "track": "Speakerphone", "artist": "Kylie Minogue", "album": "X", "label": "Parlophone Records", "discoverySurface": "youtube_music_songs"},
	}}}
	svc := NewService(ServiceConfig{Providers: []Provider{newCombinedProvider("youtube", []Provider{video, music})}, DefaultProviders: []string{"youtube"}})

	resp := svc.Search(context.Background(), "Kylie Minogue Speakerphone", []string{"youtube"}, 10)

	if video.calls.Load() != 1 || music.calls.Load() != 1 {
		t.Fatalf("source calls = video:%d music:%d, want both surfaces queried", video.calls.Load(), music.calls.Load())
	}
	if len(resp.Results) != 2 || resp.Results[0].CandidateID != "youtube:ipLo9enSiB4" {
		t.Fatalf("results = %#v, want acquired YouTube Music audio first", resp.Results)
	}
}

func TestYouTubeMusicSearchArgTargetsSongsSurface(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	if got, want := provider.searchArg("Ninajirachi iPod Touch", 10), "https://music.youtube.com/search?q=Ninajirachi+iPod+Touch#songs"; got != want {
		t.Fatalf("search arg = %q, want %q", got, want)
	}
}

func TestYouTubeMusicSearchPassesLimitToSongsPlaylist(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	if got, want := provider.commandArgs("Ninajirachi iPod Touch", 10), []string{"--flat-playlist", "--playlist-end", "10", "--dump-json", "--skip-download", "https://music.youtube.com/search?q=Ninajirachi+iPod+Touch#songs"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("yt-dlp args = %#v, want %#v", got, want)
	}
}

func TestYouTubeSearchUsesFlatPlaylistAcquisition(t *testing.T) {
	provider := NewYTDLPProvider("youtube", "ytsearch", "https://www.youtube.com/watch?v=")
	if got, want := provider.commandArgs("Ninajirachi iPod Touch", 10), []string{"--flat-playlist", "--playlist-end", "10", "--dump-json", "--skip-download", "ytsearch10:Ninajirachi iPod Touch"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("yt-dlp args = %#v, want %#v", got, want)
	}
}

func TestYouTubeMusicCandidatesNeverExceedRequestedLimit(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	output := strings.Join([]string{
		`{"id":"one","url":"https://music.youtube.com/watch?v=one","title":"One"}`,
		`{"id":"two","url":"https://music.youtube.com/watch?v=two","title":"Two"}`,
		`{"id":"three","url":"https://music.youtube.com/watch?v=three","title":"Three"}`,
	}, "\n")

	items := provider.candidatesFromOutput(output, 2)
	if got, want := len(items), 2; got != want {
		t.Fatalf("candidate count = %d, want %d", got, want)
	}
	if got, want := items[1].SourceID, "two"; got != want {
		t.Fatalf("last bounded source id = %q, want %q", got, want)
	}
}

func TestFlatYouTubeMusicCandidateRetainsSongsSurfaceEvidence(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	items := provider.candidatesFromOutput(`{"id":"xtRVa4kOBt4","title":"iPod Touch","uploader":"Ninajirachi - Topic","duration":211}`, 10)
	if len(items) != 1 {
		t.Fatalf("candidate count = %d, want 1", len(items))
	}
	candidate := items[0]
	if candidate.SourceURL != "https://www.youtube.com/watch?v=xtRVa4kOBt4" || candidate.Uploader != "Ninajirachi - Topic" || candidate.DurationMs != 211000 {
		t.Fatalf("flat candidate = %#v, want source URL, uploader, and duration", candidate)
	}
	if candidate.Metadata["discoverySurface"] != "youtube_music_songs" {
		t.Fatalf("flat candidate metadata = %#v, want YouTube Music songs surface", candidate.Metadata)
	}
}

func TestCombinedProviderReturnsSuccessfulSurfaceWhenOtherTimesOut(t *testing.T) {
	combined := newCombinedProvider("youtube", []Provider{
		fakeProvider{name: "youtube-video", delay: 50 * time.Millisecond},
		fakeProvider{name: "youtube-music", items: []Candidate{{CandidateID: "youtube:audio", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=audio", Title: "Audio", Downloadable: true}}},
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()
	items, err := combined.Search(ctx, "Audio", 10)
	if err != nil {
		t.Fatalf("combined search error = %v, want successful music surface", err)
	}
	if len(items) != 1 || items[0].CandidateID != "youtube:audio" {
		t.Fatalf("combined items = %#v, want successful music surface", items)
	}
}

func TestYTDLPCandidateMetadataRetainsMusicQualitySignals(t *testing.T) {
	metadata := ytdlpCandidateMetadata(map[string]interface{}{
		"description":  "Provided to YouTube by AWAL\\nAuto-generated by YouTube",
		"track":        "iPod Touch",
		"artist":       "Ninajirachi",
		"album":        "I Love My Computer",
		"label":        "NLV Records",
		"release_date": "2025-01-01",
	}, "youtube", true)
	for _, key := range []string{"description", "track", "artist", "album", "label", "release_date", "discoverySurface"} {
		if metadata[key] == nil || metadata[key] == "" {
			t.Fatalf("metadata[%q] = %#v, want retained music quality signal", key, metadata[key])
		}
	}
}

type fakeMusicCatalog struct {
	tracksErr  error
	artistsErr error
	albumsErr  error
}

func (c fakeMusicCatalog) SearchTracks(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	if c.tracksErr != nil {
		return nil, c.tracksErr
	}
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Results: []musicbrainz.TrackResult{
		{MBID: "track-low", Title: "Lower Score", Artist: "Artist", Album: "Album", Duration: 180000, Score: 70},
		{MBID: "track-high", Title: "Higher Score", Artist: "Artist", Album: "Album", Duration: 181000, Score: 99},
	}}, nil
}

func (c fakeMusicCatalog) SearchArtists(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.ArtistResult], error) {
	if c.artistsErr != nil {
		return nil, c.artistsErr
	}
	return &musicbrainz.SearchResponse[musicbrainz.ArtistResult]{Results: []musicbrainz.ArtistResult{{MBID: "artist-1", Name: "Artist", Type: "Person", Score: 92}}}, nil
}

func (c fakeMusicCatalog) SearchAlbums(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.AlbumResult], error) {
	if c.albumsErr != nil {
		return nil, c.albumsErr
	}
	return &musicbrainz.SearchResponse[musicbrainz.AlbumResult]{Results: []musicbrainz.AlbumResult{{MBID: "album-1", Title: "Album", Artist: "Artist", PrimaryType: "Album", Score: 88}}}, nil
}

func TestServiceSearchBuildsGroupedMusicBrainzSectionsAndKeepsFlatSources(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "Source", Artist: "Artist", Downloadable: true}}},
		},
		DefaultProviders: []string{"youtube"},
		MusicCatalog:     fakeMusicCatalog{},
	})

	resp := svc.Search(context.Background(), "artist source", nil, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("flat source results = %d, want 1", len(resp.Results))
	}
	if len(resp.Sections) != 4 {
		t.Fatalf("sections = %#v, want tracks/artists/albums/sources", resp.Sections)
	}
	if resp.Sections[0].Kind != "tracks" || resp.Sections[0].Items[0].ID != "track-high" {
		t.Fatalf("tracks section not first or not score-sorted: %#v", resp.Sections[0])
	}
	if resp.Sections[3].Kind != "sources" || resp.Sections[3].Items[0].Candidate == nil {
		t.Fatalf("sources section missing queueable candidate: %#v", resp.Sections[3])
	}
	var sawMusicBrainz bool
	for _, provider := range resp.Providers {
		if provider.Provider == "musicbrainz" && provider.Status == ProviderStatusOK && provider.ResultCount == 4 {
			sawMusicBrainz = true
		}
	}
	if !sawMusicBrainz {
		t.Fatalf("missing successful musicbrainz provider summary: %#v", resp.Providers)
	}
}

func TestServiceSearchMusicBrainzFailureDoesNotHideSourceResults(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "Source", Downloadable: true}}},
		},
		DefaultProviders: []string{"youtube"},
		MusicCatalog:     fakeMusicCatalog{tracksErr: errors.New("mb down"), artistsErr: errors.New("mb down"), albumsErr: errors.New("mb down")},
	})

	resp := svc.Search(context.Background(), "source", nil, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("flat source results = %d, want 1", len(resp.Results))
	}
	if len(resp.Sections) != 1 || resp.Sections[0].Kind != "sources" {
		t.Fatalf("expected only sources section after catalog failure, got %#v", resp.Sections)
	}
	var sawFailedMusicBrainz bool
	for _, provider := range resp.Providers {
		if provider.Provider == "musicbrainz" && provider.Status == ProviderStatusFailed && provider.Error != nil {
			sawFailedMusicBrainz = true
		}
	}
	if !sawFailedMusicBrainz {
		t.Fatalf("missing failed musicbrainz provider summary: %#v", resp.Providers)
	}
}

// slowMusicCatalog records how many times it is consulted and blocks on each
// call so a regression can prove that a source-only search never touches the
// catalog (call count stays at zero) instead of merely returning before the
// catalog finishes.
type slowMusicCatalog struct {
	calls atomic.Int32
	delay time.Duration
}

func (c *slowMusicCatalog) block(ctx context.Context) error {
	c.calls.Add(1)
	select {
	case <-time.After(c.delay):
	case <-ctx.Done():
	}
	return errors.New("musicbrainz unavailable")
}

func (c *slowMusicCatalog) SearchTracks(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	return nil, c.block(ctx)
}

func (c *slowMusicCatalog) SearchArtists(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.ArtistResult], error) {
	return nil, c.block(ctx)
}

func (c *slowMusicCatalog) SearchAlbums(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.AlbumResult], error) {
	return nil, c.block(ctx)
}

func TestServiceSearchSourceOnlySkipsMusicBrainzCatalog(t *testing.T) {
	catalog := &slowMusicCatalog{delay: 2 * time.Second}
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "Source", Downloadable: true}}},
		},
		DefaultProviders: []string{"youtube", "soundcloud"},
		MusicCatalog:     catalog,
		OverallTimeout:   3 * time.Second,
	})

	start := time.Now()
	resp := svc.Search(context.Background(), "source", []string{"youtube"}, 10)
	elapsed := time.Since(start)

	if calls := catalog.calls.Load(); calls != 0 {
		t.Fatalf("source-only search consulted the catalog %d time(s); it must not wait on MusicBrainz", calls)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("source-only search took %s; it should return promptly without the %s catalog delay", elapsed, catalog.delay)
	}
	if len(resp.Results) != 1 {
		t.Fatalf("flat source results = %d, want 1", len(resp.Results))
	}
	if len(resp.Sections) != 1 || resp.Sections[0].Kind != "sources" {
		t.Fatalf("expected only a sources section for source-only search, got %#v", resp.Sections)
	}
	for _, provider := range resp.Providers {
		if provider.Provider == CatalogProvider {
			t.Fatalf("source-only search must not emit a %s provider summary: %#v", CatalogProvider, resp.Providers)
		}
	}
}

func TestServiceSearchCatalogOptInRunsMusicBrainz(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "Source", Artist: "Artist", Downloadable: true}}},
		},
		DefaultProviders: []string{"youtube"},
		MusicCatalog:     fakeMusicCatalog{},
	})

	resp := svc.Search(context.Background(), "artist source", []string{"youtube", CatalogProvider}, 10)

	if len(resp.Results) != 1 {
		t.Fatalf("flat source results = %d, want 1", len(resp.Results))
	}
	if len(resp.Sections) != 4 {
		t.Fatalf("sections = %#v, want tracks/artists/albums/sources when catalog is opted in", resp.Sections)
	}
	var sawCatalog bool
	for _, provider := range resp.Providers {
		if provider.Provider == CatalogProvider {
			if provider.Status != ProviderStatusOK {
				t.Fatalf("catalog summary status = %s, want ok", provider.Status)
			}
			sawCatalog = true
		}
		if provider.Status == ProviderStatusUnsupported {
			t.Fatalf("%q must be treated as a catalog opt-in, not an unsupported provider: %#v", CatalogProvider, resp.Providers)
		}
	}
	if !sawCatalog {
		t.Fatalf("missing musicbrainz provider summary after catalog opt-in: %#v", resp.Providers)
	}
}

func TestServiceSearchMusicBrainzTimeoutUsesTimeoutSummary(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers:        []Provider{},
		DefaultProviders: []string{},
		MusicCatalog:     fakeMusicCatalog{tracksErr: context.DeadlineExceeded, artistsErr: context.DeadlineExceeded, albumsErr: context.DeadlineExceeded},
	})

	resp := svc.Search(context.Background(), "source", nil, 10)
	var sawTimedOutMusicBrainz bool
	for _, provider := range resp.Providers {
		if provider.Provider == "musicbrainz" && provider.Status == ProviderStatusTimeout && provider.Error != nil && provider.Error.Code == ErrProviderTimeout {
			sawTimedOutMusicBrainz = true
		}
	}
	if !sawTimedOutMusicBrainz {
		t.Fatalf("missing timed out musicbrainz provider summary: %#v", resp.Providers)
	}
}

func TestSearchHandlerPersistsRankedSelectionSession(t *testing.T) {
	store := &captureSelectionStore{}
	h := NewHandlersWithAssistAndSelectionStore(NewService(ServiceConfig{Providers: []Provider{fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "first", Provider: "youtube", SourceURL: "https://example.test/1", Title: "First", Downloadable: true, Metadata: map[string]interface{}{"sourceQuality": map[string]interface{}{"score": 99}}}, {CandidateID: "second", Provider: "youtube", SourceURL: "https://example.test/2", Title: "Second", Downloadable: true}}}}, DefaultProviders: []string{"youtube"}}), nil, store)
	request := httptest.NewRequest(http.MethodGet, "/api/v1/discovery/search?q=first", nil)
	request = request.WithContext(context.WithValue(request.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
	recorder := httptest.NewRecorder()
	h.Search(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", recorder.Code, recorder.Body.String())
	}
	if store.session == nil || store.session.RecommendedCandidateID != "first" || len(store.session.Candidates) == 0 {
		t.Fatalf("persisted session = %#v", store.session)
	}
	var body SearchResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.SelectionRequired || body.SelectionSessionID == "" || body.RecommendedCandidateID != "first" || body.SelectionExpiresAt == nil {
		t.Fatalf("selection envelope = %#v", body)
	}
}

func TestSearchHandlerFailsWhenSelectionPersistenceFails(t *testing.T) {
	h := NewHandlersWithAssistAndSelectionStore(NewService(ServiceConfig{Providers: []Provider{fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "first", Provider: "youtube", SourceURL: "https://example.test/1", Title: "First", Downloadable: true}}}}, DefaultProviders: []string{"youtube"}}), nil, &captureSelectionStore{err: errors.New("db unavailable")})
	request := httptest.NewRequest(http.MethodGet, "/api/v1/discovery/search?q=first", nil)
	request = request.WithContext(context.WithValue(request.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
	recorder := httptest.NewRecorder()
	h.Search(recorder, request)
	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, body=%s", recorder.Code, recorder.Body.String())
	}
}
