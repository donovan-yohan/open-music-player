package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
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

func TestNewServiceAppliesTimeoutDefaults(t *testing.T) {
	svc := NewService(ServiceConfig{})
	if svc.perProviderTimeout != DefaultPerProviderTimeout {
		t.Fatalf("per-provider timeout = %s, want %s", svc.perProviderTimeout, DefaultPerProviderTimeout)
	}
	if svc.overallTimeout != DefaultOverallTimeout {
		t.Fatalf("overall timeout = %s, want %s", svc.overallTimeout, DefaultOverallTimeout)
	}
	if svc.overallTimeout < svc.perProviderTimeout {
		t.Fatalf("overall timeout %s must be at least per-provider timeout %s", svc.overallTimeout, svc.perProviderTimeout)
	}
}

func TestNewServiceKeepsOverallTimeoutAtLeastPerProviderTimeout(t *testing.T) {
	svc := NewService(ServiceConfig{
		PerProviderTimeout: 12 * time.Second,
		OverallTimeout:     5 * time.Second,
	})
	if svc.overallTimeout != svc.perProviderTimeout {
		t.Fatalf("overall timeout = %s, want it clamped to per-provider timeout %s", svc.overallTimeout, svc.perProviderTimeout)
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

func TestCombinedYouTubeProviderMergesHydratedMusicDuplicate(t *testing.T) {
	const candidateID = "youtube:same"
	ordinary := &recordingProvider{name: "youtube-video", items: []Candidate{{
		CandidateID: candidateID, Provider: "youtube", SourceID: "same",
		SourceURL: "https://www.youtube.com/watch?v=same", Title: "Artist - Song (Official Video)", Downloadable: true,
		Metadata: map[string]interface{}{"discoverySurface": "youtube_search"},
	}}}
	music := &recordingProvider{name: "youtube-music", items: []Candidate{{
		CandidateID: candidateID, Provider: "youtube", SourceID: "same",
		SourceURL: "https://music.youtube.com/watch?v=same", Title: "Song", Artist: "Artist",
		Uploader: "Artist - Topic", DurationMs: 201000, ThumbnailURL: "https://images.example/song.jpg", Downloadable: true,
		Metadata: map[string]interface{}{"discoverySurface": "youtube_music_songs", "track": "Song", "artist": "Artist", "album": "Album"},
	}}}

	items, err := newCombinedProvider("youtube", []Provider{ordinary, music}).Search(context.Background(), "Artist Song", 10)
	if err != nil {
		t.Fatalf("Search() error = %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("items = %#v, want one merged duplicate", items)
	}
	got := items[0]
	if got.CandidateID != candidateID || got.SourceURL != ordinary.items[0].SourceURL {
		t.Fatalf("merged identity = %#v, want first-seen candidate identity", got)
	}
	if got.Title != "Song" || got.Artist != "Artist" || got.Uploader != "Artist - Topic" || got.DurationMs != 201000 {
		t.Fatalf("merged details = %#v, want hydrated YouTube Music details", got)
	}
	if surface := metadataStringValue(got.Metadata, "discoverySurface"); surface != "youtube_music_songs" {
		t.Fatalf("merged discovery surface = %q, want youtube_music_songs", surface)
	}
	if alternateTitle := metadataStringValue(got.Metadata, "duplicateSurfaceTitle"); alternateTitle != ordinary.items[0].Title {
		t.Fatalf("merged alternate title = %q, want ordinary search title %q", alternateTitle, ordinary.items[0].Title)
	}
	if alternateTitle := metadataStringValue(got.Metadata, "alt_title"); alternateTitle != "" {
		t.Fatalf("merged alt_title = %q, want no ranking-visible alternate title", alternateTitle)
	}
	if quality := EvaluateSourceQuality("Artist Song", got); quality.Classification != SourceQualityTopicAudio {
		t.Fatalf("merged source quality = %#v, want topic audio unaffected by duplicate video title", quality)
	}
}

func TestSearchStripsLargeSourceQualityInputMetadata(t *testing.T) {
	provider := fakeProvider{name: "youtube", items: []Candidate{{
		CandidateID: "youtube:one", Provider: "youtube", SourceID: "one", SourceURL: "https://www.youtube.com/watch?v=one",
		Title: "Song", Artist: "Artist", DurationMs: 201000, Downloadable: true,
		Metadata: map[string]interface{}{
			"description": "long uploader-authored text", "tags": []interface{}{"one", "two"}, "categories": []interface{}{"Music"},
			"track": "Song", "artist": "Artist", "album": "Album", "discoverySurface": "youtube_music_songs",
		},
	}}}
	svc := NewService(ServiceConfig{Providers: []Provider{provider}, DefaultProviders: []string{"youtube"}})

	resp := svc.Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	if len(resp.Results) != 1 || len(resp.Sections) != 1 || len(resp.Sections[0].Items) != 1 {
		t.Fatalf("response = %#v, want one source candidate", resp)
	}
	for _, metadata := range []map[string]interface{}{resp.Results[0].Metadata, resp.Sections[0].Items[0].Candidate.Metadata} {
		for _, key := range []string{"description", "tags", "categories"} {
			if _, ok := metadata[key]; ok {
				t.Fatalf("response metadata retained transient %q: %#v", key, metadata)
			}
		}
		if metadata["track"] != "Song" || metadata[SourceQualityMetadataKey] == nil {
			t.Fatalf("response metadata lost compact identity or quality fields: %#v", metadata)
		}
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

func TestYouTubeMusicMetadataCommandTerminatesOptions(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	if got, want := provider.metadataCommandArgs("https://www.youtube.com/watch?v=one"), []string{"--no-playlist", "--dump-single-json", "--skip-download", "--", "https://www.youtube.com/watch?v=one"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("yt-dlp metadata args = %#v, want %#v", got, want)
	}
}

func TestYouTubeMusicMetadataEnrichmentRejectsUnsafeSourceURL(t *testing.T) {
	for _, sourceURL := range []string{"--config-location", "file:///tmp/yt-dlp.conf", "javascript:alert(1)", "https:relative"} {
		t.Run(sourceURL, func(t *testing.T) {
			called := false
			provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, _ []string) ([]byte, error) {
				called = true
				return nil, nil
			})
			candidate := Candidate{SourceID: "one", SourceURL: sourceURL}

			got, err := provider.enrichYouTubeMusicCandidate(context.Background(), candidate)
			if err == nil {
				t.Fatalf("enrichYouTubeMusicCandidate() error = nil, want unsafe URL rejection")
			}
			if called {
				t.Fatal("unsafe source URL reached yt-dlp command runner")
			}
			if !reflect.DeepEqual(got, candidate) {
				t.Fatalf("rejected candidate = %#v, want original %#v", got, candidate)
			}
		})
	}
}

func TestYouTubeSearchUsesFlatPlaylistAcquisition(t *testing.T) {
	provider := NewYTDLPProvider("youtube", "ytsearch", "https://www.youtube.com/watch?v=")
	if got, want := provider.commandArgs("Ninajirachi iPod Touch", 10), []string{"--flat-playlist", "--playlist-end", "10", "--dump-json", "--skip-download", "ytsearch10:Ninajirachi iPod Touch"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("yt-dlp args = %#v, want %#v", got, want)
	}
}

func TestNewYouTubeMusicProviderAppliesMetadataDefaults(t *testing.T) {
	provider := NewYouTubeMusicProvider("youtube")
	if provider.metadataEnrichmentTimeout != DefaultYouTubeMusicMetadataEnrichmentTimeout {
		t.Fatalf("metadata timeout = %s, want %s", provider.metadataEnrichmentTimeout, DefaultYouTubeMusicMetadataEnrichmentTimeout)
	}
	if got := cap(provider.metadataEnrichmentSlots); got != DefaultYouTubeMusicMetadataEnrichmentConcurrency {
		t.Fatalf("metadata process slots = %d, want %d", got, DefaultYouTubeMusicMetadataEnrichmentConcurrency)
	}
	if provider.metadataAcquireTimeout != defaultYouTubeMusicMetadataEnrichmentAcquireTimeout {
		t.Fatalf("metadata acquire timeout = %s, want %s", provider.metadataAcquireTimeout, defaultYouTubeMusicMetadataEnrichmentAcquireTimeout)
	}
}

func TestNewDefaultServiceAppliesYouTubeMusicMetadataConfig(t *testing.T) {
	svc := NewDefaultServiceWithConfig(ServiceConfig{
		YouTubeMusicMetadataEnrichmentConcurrency: 3,
		YouTubeMusicMetadataEnrichmentTimeout:     2 * time.Second,
	})
	combined, ok := svc.providers["youtube"].(*combinedProvider)
	if !ok || len(combined.providers) != 2 {
		t.Fatalf("youtube provider = %#v, want combined provider", svc.providers["youtube"])
	}
	music, ok := combined.providers[1].(*YTDLPProvider)
	if !ok {
		t.Fatalf("youtube music provider = %T, want *YTDLPProvider", combined.providers[1])
	}
	if cap(music.metadataEnrichmentSlots) != 3 || music.metadataEnrichmentTimeout != 2*time.Second {
		t.Fatalf("metadata provider config = slots:%d timeout:%s", cap(music.metadataEnrichmentSlots), music.metadataEnrichmentTimeout)
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
	if got, want := items[0].SourceURL, "https://music.youtube.com/watch?v=one"; got != want {
		t.Fatalf("source URL = %q, want raw URL fallback %q", got, want)
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

func TestYouTubeMusicMetadataEnrichmentPreservesCandidateIdentityAndOrder(t *testing.T) {
	flatOutput := strings.Join([]string{
		`{"id":"one","title":"Flat One"}`,
		`{"id":"two","title":"Flat Two"}`,
	}, "\n")
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(flatOutput), nil
		}
		switch args[len(args)-1] {
		case "https://www.youtube.com/watch?v=one":
			return []byte(`{"id":"one","artist":"Artist One","uploader":"Artist One - Topic","duration":201,"thumbnail":"https://images.example/one-full.jpg","thumbnails":[{"url":"https://images.example/one-120.jpg","height":120},{"url":"https://images.example/one-480.jpg","height":480},{"url":"https://images.example/one-full.jpg","height":720}],"track":"One","album":"Album One"}`), nil
		case "https://www.youtube.com/watch?v=two":
			return []byte(`{"id":"two","artist":"Artist Two","uploader":"Artist Two - Topic","duration":202,"thumbnail":"https://images.example/two.jpg","track":"Two","album":"Album Two"}`), nil
		default:
			return nil, errors.New("unexpected source URL")
		}
	})

	items, err := provider.Search(context.Background(), "artist", 2)
	if err != nil {
		t.Fatalf("Search() error = %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("items = %#v, want two enriched candidates", items)
	}
	for index, want := range []struct {
		id, url, title, artist, uploader, thumbnail string
		duration                                    int
	}{
		{"youtube:one", "https://www.youtube.com/watch?v=one", "Flat One", "Artist One", "Artist One - Topic", "https://images.example/one-480.jpg", 201000},
		{"youtube:two", "https://www.youtube.com/watch?v=two", "Flat Two", "Artist Two", "Artist Two - Topic", "https://images.example/two.jpg", 202000},
	} {
		got := items[index]
		if got.CandidateID != want.id || got.SourceURL != want.url || got.Title != want.title || got.Artist != want.artist || got.Uploader != want.uploader || got.DurationMs != want.duration || got.ThumbnailURL != want.thumbnail {
			t.Fatalf("candidate[%d] = %#v, want identity/order and enriched source metadata", index, got)
		}
		if !got.Downloadable || got.Playable {
			t.Fatalf("candidate[%d] queue/playback state = %#v, want original downloadable non-playable state", index, got)
		}
		if got.Metadata["discoverySurface"] != "youtube_music_songs" {
			t.Fatalf("candidate[%d] metadata = %#v, want retained surface evidence", index, got.Metadata)
		}
	}
}

func TestYouTubeMusicMetadataEnrichmentKeepsFlatCandidateOnPerSourceFailure(t *testing.T) {
	flatOutput := strings.Join([]string{
		`{"id":"one","title":"Flat One"}`,
		`{"id":"two","title":"Flat Two","uploader":"Original Uploader","duration":200}`,
	}, "\n")
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(flatOutput), nil
		}
		if args[len(args)-1] == "https://www.youtube.com/watch?v=one" {
			return []byte(`{"id":"one","artist":"Artist One","duration":201}`), nil
		}
		return nil, errors.New("metadata extraction failed")
	})
	wantFlat := provider.candidatesFromOutput(flatOutput, 2)[1]

	items, err := provider.Search(context.Background(), "artist", 2)
	if err != nil {
		t.Fatalf("Search() error = %v", err)
	}
	if items[0].Artist != "Artist One" {
		t.Fatalf("successful source was not enriched: %#v", items[0])
	}
	if !reflect.DeepEqual(items[1], wantFlat) {
		t.Fatalf("failed source changed candidate = %#v, want original flat %#v", items[1], wantFlat)
	}
}

func TestYouTubeMusicMetadataEnrichmentRejectsMismatchedSourceID(t *testing.T) {
	for _, tc := range []struct {
		name         string
		detailOutput string
	}{
		{name: "mismatched ID", detailOutput: `{"id":"other","artist":"Wrong Artist","duration":201}`},
		{name: "missing ID", detailOutput: `{"artist":"Wrong Artist","duration":201}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			flatOutput := `{"id":"one","title":"Flat One"}`
			provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
				if args[0] == "--flat-playlist" {
					return []byte(flatOutput), nil
				}
				return []byte(tc.detailOutput), nil
			})
			wantFlat := provider.candidatesFromOutput(flatOutput, 1)

			items, err := provider.Search(context.Background(), "artist", 1)
			if err != nil {
				t.Fatalf("Search() error = %v", err)
			}
			if !reflect.DeepEqual(items, wantFlat) {
				t.Fatalf("untrusted source ID changed candidate = %#v, want original flat %#v", items, wantFlat)
			}
		})
	}
}

func TestYouTubeMusicMetadataEnrichmentHonorsCallerDeadline(t *testing.T) {
	flatOutput := `{"id":"one","title":"Flat One"}`
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(ctx context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(flatOutput), nil
		}
		<-ctx.Done()
		return nil, ctx.Err()
	})
	wantFlat := provider.candidatesFromOutput(flatOutput, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	items, err := provider.Search(ctx, "artist", 1)
	if err != nil {
		t.Fatalf("Search() error = %v, want best-effort flat result", err)
	}
	if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
		t.Fatalf("metadata runner did not receive the caller deadline: %v", ctx.Err())
	}
	if !reflect.DeepEqual(items, wantFlat) {
		t.Fatalf("deadline changed candidate = %#v, want original flat %#v", items, wantFlat)
	}
}

func TestServiceSearchSourcesReturnsAfterYouTubeMusicMetadataChildBudget(t *testing.T) {
	const childBudget = 15 * time.Millisecond
	flatOutput := `{"id":"music","title":"Flat Music"}`
	music := newYouTubeMusicProviderWithCommandRunner("youtube", func(ctx context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(flatOutput), nil
		}
		<-ctx.Done()
		return nil, ctx.Err()
	})
	music.metadataEnrichmentTimeout = childBudget
	ordinary := fakeProvider{name: "youtube-video", items: []Candidate{{CandidateID: "youtube:video", Provider: "youtube", SourceID: "video", SourceURL: "https://www.youtube.com/watch?v=video", Title: "Video", Downloadable: true}}}
	soundcloud := fakeProvider{name: "soundcloud", items: []Candidate{{CandidateID: "soundcloud:track", Provider: "soundcloud", SourceID: "track", SourceURL: "https://soundcloud.com/artist/track", Title: "Track", Downloadable: true}}}
	svc := NewService(ServiceConfig{
		Providers: []Provider{newCombinedProvider("youtube", []Provider{ordinary, music}), soundcloud}, DefaultProviders: []string{"youtube", "soundcloud"},
		PerProviderTimeout: 200 * time.Millisecond, OverallTimeout: 250 * time.Millisecond,
	})

	started := time.Now()
	resp := svc.SearchSources(context.Background(), "artist", []string{"youtube", "soundcloud"}, 10)
	if elapsed := time.Since(started); elapsed >= 100*time.Millisecond {
		t.Fatalf("search waited %s, want return after %s metadata child budget instead of provider budget", elapsed, childBudget)
	}
	if len(resp.Results) != 3 {
		t.Fatalf("results = %#v, want ordinary YouTube, flat Music fallback, and SoundCloud", resp.Results)
	}
	if got := resp.Results[0].CandidateID; got != "youtube:video" {
		t.Fatalf("ordinary YouTube result = %q, want youtube:video", got)
	}
	if got := resp.Results[1].CandidateID; got != "youtube:music" || resp.Results[1].Artist != "" {
		t.Fatalf("YouTube Music fallback = %#v, want original flat candidate", resp.Results[1])
	}
	if got := resp.Results[2].CandidateID; got != "soundcloud:track" {
		t.Fatalf("SoundCloud result = %q, want soundcloud:track", got)
	}
}

func TestYouTubeMusicMetadataEnrichmentReturnsPromptlyWhenProcessSlotsAreBusy(t *testing.T) {
	const acquireTimeout = 15 * time.Millisecond
	var detailCalls atomic.Int32
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(`{"id":"one","title":"Flat One"}`), nil
		}
		detailCalls.Add(1)
		return []byte(`{"id":"one","artist":"Artist","duration":201}`), nil
	})
	provider.metadataEnrichmentSlots = make(chan struct{}, 1)
	provider.metadataEnrichmentSlots <- struct{}{}
	provider.metadataAcquireTimeout = acquireTimeout
	provider.metadataEnrichmentTimeout = 200 * time.Millisecond

	started := time.Now()
	items, err := provider.Search(context.Background(), "artist", 1)
	elapsed := time.Since(started)
	<-provider.metadataEnrichmentSlots
	if err != nil {
		t.Fatalf("Search() error = %v", err)
	}
	if elapsed >= 100*time.Millisecond {
		t.Fatalf("busy-slot fallback took %s, want near %s acquire timeout", elapsed, acquireTimeout)
	}
	if detailCalls.Load() != 0 || len(items) != 1 || items[0].Artist != "" {
		t.Fatalf("busy-slot fallback = %#v, detail calls = %d", items, detailCalls.Load())
	}
}

func TestYouTubeMusicMetadataEnrichmentLetsOneRequestUseLaterWaves(t *testing.T) {
	const acquireTimeout = 10 * time.Millisecond
	flatOutput := strings.Join([]string{
		`{"id":"one","title":"Flat One"}`,
		`{"id":"two","title":"Flat Two"}`,
	}, "\n")
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(flatOutput), nil
		}
		if args[len(args)-1] == "https://www.youtube.com/watch?v=one" {
			close(firstStarted)
			<-releaseFirst
			return []byte(`{"id":"one","artist":"Artist One","duration":201}`), nil
		}
		return []byte(`{"id":"two","artist":"Artist Two","duration":202}`), nil
	})
	provider.metadataEnrichmentSlots = make(chan struct{}, 1)
	provider.metadataAcquireTimeout = acquireTimeout
	provider.metadataEnrichmentTimeout = 200 * time.Millisecond

	done := make(chan []Candidate, 1)
	go func() {
		items, _ := provider.Search(context.Background(), "artist", 2)
		done <- items
	}()
	<-firstStarted
	time.Sleep(2 * acquireTimeout)
	close(releaseFirst)
	items := <-done
	if len(items) != 2 || items[0].Artist != "Artist One" || items[1].Artist != "Artist Two" {
		t.Fatalf("later-wave enrichment = %#v, want both candidates hydrated", items)
	}
}

func TestYouTubeMusicMetadataEnrichmentSkipsCandidateWithoutSourceID(t *testing.T) {
	var detailCalls atomic.Int32
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(`{"url":"https://www.youtube.com/watch?v=missing","title":"Flat"}`), nil
		}
		detailCalls.Add(1)
		return []byte(`{"id":"other","artist":"Wrong"}`), nil
	})

	items, err := provider.Search(context.Background(), "artist", 1)
	if err != nil {
		t.Fatalf("Search() error = %v", err)
	}
	if detailCalls.Load() != 0 || len(items) != 1 || items[0].SourceID != "" || items[0].Artist != "" {
		t.Fatalf("missing-ID fallback = %#v, detail calls = %d", items, detailCalls.Load())
	}
}

func TestYouTubeMusicMetadataEnrichmentBoundsConcurrentProcesses(t *testing.T) {
	flatItems := make([]string, 0, DefaultYouTubeMusicMetadataEnrichmentConcurrency+3)
	for index := 0; index < DefaultYouTubeMusicMetadataEnrichmentConcurrency+3; index++ {
		flatItems = append(flatItems, `{"id":"item`+strconv.Itoa(index)+`","title":"Flat"}`)
	}
	started := make(chan struct{}, len(flatItems)*2)
	release := make(chan struct{})
	var inFlight atomic.Int32
	var maxInFlight atomic.Int32
	provider := newYouTubeMusicProviderWithCommandRunner("youtube", func(_ context.Context, args []string) ([]byte, error) {
		if args[0] == "--flat-playlist" {
			return []byte(strings.Join(flatItems, "\n")), nil
		}
		current := inFlight.Add(1)
		for previous := maxInFlight.Load(); current > previous && !maxInFlight.CompareAndSwap(previous, current); previous = maxInFlight.Load() {
		}
		started <- struct{}{}
		<-release
		inFlight.Add(-1)
		return []byte(`{"artist":"Artist"}`), nil
	})
	type outcome struct {
		items []Candidate
		err   error
	}
	done := make(chan outcome, 2)
	for call := 0; call < 2; call++ {
		go func() {
			items, err := provider.Search(context.Background(), "artist", len(flatItems))
			done <- outcome{items: items, err: err}
		}()
	}
	for index := 0; index < DefaultYouTubeMusicMetadataEnrichmentConcurrency; index++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("metadata processes did not start")
		}
	}
	select {
	case <-started:
		t.Fatal("metadata process concurrency exceeded configured bound")
	default:
	}
	close(release)
	for call := 0; call < 2; call++ {
		result := <-done
		if result.err != nil || len(result.items) != len(flatItems) {
			t.Fatalf("Search() = %#v, %v", result.items, result.err)
		}
	}
	if got := maxInFlight.Load(); got != DefaultYouTubeMusicMetadataEnrichmentConcurrency {
		t.Fatalf("max concurrent metadata processes = %d, want %d", got, DefaultYouTubeMusicMetadataEnrichmentConcurrency)
	}
}

func TestSoundCloudCandidatePrefersCanonicalWebpageURL(t *testing.T) {
	provider := NewYTDLPProvider("soundcloud", "scsearch", "")
	items := provider.candidatesFromOutput(`{"id":"123456789","url":"https://api.soundcloud.com/tracks/123456789","webpage_url":"https://soundcloud.com/ninajirachi/ipod-touch","title":"iPod Touch"}`, 10)
	if len(items) != 1 {
		t.Fatalf("candidate count = %d, want 1", len(items))
	}
	if got, want := items[0].SourceURL, "https://soundcloud.com/ninajirachi/ipod-touch"; got != want {
		t.Fatalf("source URL = %q, want canonical webpage URL %q", got, want)
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

func TestCandidateThumbnailURLSelection(t *testing.T) {
	cases := []struct {
		name string
		raw  map[string]interface{}
		want string
	}{
		{
			name: "bounded array thumbnail wins over singular full resolution",
			raw: map[string]interface{}{
				"thumbnail":  "https://img/direct.jpg",
				"thumbnails": []interface{}{map[string]interface{}{"url": "https://img/array.jpg", "height": 360.0}},
			},
			want: "https://img/array.jpg",
		},
		{
			name: "largest height at most 480 preferred",
			raw: map[string]interface{}{
				"thumbnails": []interface{}{
					map[string]interface{}{"url": "https://img/144.jpg", "height": 144.0},
					map[string]interface{}{"url": "https://img/480.jpg", "height": 480.0},
					map[string]interface{}{"url": "https://img/1080.jpg", "height": 1080.0},
					map[string]interface{}{"url": "https://img/360.jpg", "height": 360.0},
				},
			},
			want: "https://img/480.jpg",
		},
		{
			name: "all above 480 falls back to smallest",
			raw: map[string]interface{}{
				"thumbnails": []interface{}{
					map[string]interface{}{"url": "https://img/720.jpg", "height": 720.0},
					map[string]interface{}{"url": "https://img/1080.jpg", "height": 1080.0},
				},
			},
			want: "https://img/720.jpg",
		},
		{
			name: "heightless entries fall back to singular thumbnail",
			raw: map[string]interface{}{
				"thumbnail": "https://img/direct.jpg",
				"thumbnails": []interface{}{
					map[string]interface{}{"url": "https://img/a.jpg"},
					map[string]interface{}{"url": "https://img/b.jpg"},
				},
			},
			want: "https://img/direct.jpg",
		},
		{
			name: "heightless entries still yield a url without singular fallback",
			raw: map[string]interface{}{
				"thumbnails": []interface{}{
					map[string]interface{}{"url": "https://img/a.jpg"},
					map[string]interface{}{"url": "https://img/b.jpg"},
				},
			},
			want: "https://img/a.jpg",
		},
		{
			name: "absent both yields empty",
			raw:  map[string]interface{}{"id": "x"},
			want: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := candidateThumbnailURL(tc.raw); got != tc.want {
				t.Fatalf("candidateThumbnailURL = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCandidatesFromOutputUsesThumbnailsArray(t *testing.T) {
	provider := NewYTDLPProvider("youtube", "ytsearch", "https://www.youtube.com/watch?v=")
	line := `{"id":"abc","title":"Track","webpage_url":"https://youtube.com/watch?v=abc","duration":200,"thumbnails":[{"url":"https://i.ytimg.com/vi/abc/hqdefault.jpg","height":360,"width":480}]}`
	items := provider.candidatesFromOutput(line, 5)
	if len(items) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(items))
	}
	if items[0].ThumbnailURL != "https://i.ytimg.com/vi/abc/hqdefault.jpg" {
		t.Fatalf("ThumbnailURL = %q", items[0].ThumbnailURL)
	}
}
