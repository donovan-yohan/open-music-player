package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
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
