package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const (
	ProviderStatusOK          = "ok"
	ProviderStatusTimeout     = "timeout"
	ProviderStatusFailed      = "failed"
	ProviderStatusDisabled    = "disabled"
	ProviderStatusUnsupported = "unsupported"

	ErrProviderTimeout     = "PROVIDER_TIMEOUT"
	ErrProviderDisabled    = "PROVIDER_DISABLED"
	ErrProviderUnsupported = "PROVIDER_UNSUPPORTED"
	ErrProviderUnavailable = "PROVIDER_UNAVAILABLE"
	ErrProviderBadResponse = "PROVIDER_BAD_RESPONSE"

	// CatalogProvider is the pseudo-provider name callers include to opt into
	// MusicBrainz catalog grouping. Provider-scoped, source-only searches omit
	// it so fast source results are never held behind a slow or failing catalog
	// lookup.
	CatalogProvider = "musicbrainz"
)

// Candidate is the normalized source result returned to mobile clients. It is
// deliberately not playable until the download worker stores it locally.
type Candidate struct {
	CandidateID  string                 `json:"candidateId"`
	Provider     string                 `json:"provider"`
	SourceID     string                 `json:"sourceId,omitempty"`
	SourceURL    string                 `json:"sourceUrl"`
	Title        string                 `json:"title"`
	Artist       string                 `json:"artist,omitempty"`
	Uploader     string                 `json:"uploader,omitempty"`
	DurationMs   int                    `json:"durationMs,omitempty"`
	ThumbnailURL string                 `json:"thumbnailUrl,omitempty"`
	Downloadable bool                   `json:"downloadable"`
	Playable     bool                   `json:"playable"`
	Explicit     *bool                  `json:"explicit"`
	Metadata     map[string]interface{} `json:"metadata,omitempty"`
}

type ProviderError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type ProviderSummary struct {
	Provider    string         `json:"provider"`
	Status      string         `json:"status"`
	ResultCount int            `json:"resultCount"`
	ElapsedMs   int64          `json:"elapsedMs"`
	Error       *ProviderError `json:"error,omitempty"`
}

type SearchResponse struct {
	Query                  string            `json:"query"`
	Results                []Candidate       `json:"results"`
	Sections               []SearchSection   `json:"sections"`
	Providers              []ProviderSummary `json:"providers"`
	SelectionRequired      bool              `json:"selectionRequired"`
	SelectionSessionID     string            `json:"selectionSessionId,omitempty"`
	RecommendedCandidateID string            `json:"recommendedCandidateId,omitempty"`
	SelectionExpiresAt     *time.Time        `json:"selectionExpiresAt,omitempty"`
}

type SearchSection struct {
	Kind  string       `json:"kind"`
	Title string       `json:"title"`
	Items []SearchItem `json:"items"`
}

type SearchItem struct {
	Kind        string     `json:"kind"`
	ID          string     `json:"id,omitempty"`
	Title       string     `json:"title"`
	Subtitle    string     `json:"subtitle,omitempty"`
	Artist      string     `json:"artist,omitempty"`
	ArtistMBID  string     `json:"artistMbid,omitempty"`
	Album       string     `json:"album,omitempty"`
	AlbumMBID   string     `json:"albumMbid,omitempty"`
	DurationMs  int        `json:"durationMs,omitempty"`
	ReleaseDate string     `json:"releaseDate,omitempty"`
	Score       int        `json:"score,omitempty"`
	Candidate   *Candidate `json:"candidate,omitempty"`
}

type Provider interface {
	Name() string
	Search(ctx context.Context, query string, limit int) ([]Candidate, error)
}

type MusicCatalog interface {
	SearchTracks(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error)
	SearchArtists(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.ArtistResult], error)
	SearchAlbums(ctx context.Context, query string, limit, offset int, skipCache bool) (*musicbrainz.SearchResponse[musicbrainz.AlbumResult], error)
}

type providerFailure struct {
	code   string
	status string
	err    error
}

func (e *providerFailure) Error() string { return e.err.Error() }
func (e *providerFailure) Unwrap() error { return e.err }

type Service struct {
	providers          map[string]Provider
	defaultProviders   []string
	musicCatalog       MusicCatalog
	sourceQualityJudge SourceQualityJudge
	overallTimeout     time.Duration
	perProviderTimeout time.Duration
}

type ServiceConfig struct {
	Providers          []Provider
	DefaultProviders   []string
	MusicCatalog       MusicCatalog
	SourceQualityJudge SourceQualityJudge
	OverallTimeout     time.Duration
	PerProviderTimeout time.Duration
}

func NewService(cfg ServiceConfig) *Service {
	providers := make(map[string]Provider)
	for _, p := range cfg.Providers {
		providers[p.Name()] = p
	}
	defaults := cfg.DefaultProviders
	if len(defaults) == 0 {
		defaults = make([]string, 0, len(providers))
		for name := range providers {
			defaults = append(defaults, name)
		}
	}
	if cfg.OverallTimeout <= 0 {
		cfg.OverallTimeout = 8 * time.Second
	}
	if cfg.PerProviderTimeout <= 0 {
		cfg.PerProviderTimeout = 3 * time.Second
	}
	return &Service{
		providers:          providers,
		defaultProviders:   defaults,
		musicCatalog:       cfg.MusicCatalog,
		sourceQualityJudge: cfg.SourceQualityJudge,
		overallTimeout:     cfg.OverallTimeout,
		perProviderTimeout: cfg.PerProviderTimeout,
	}
}

func NewDefaultService() *Service {
	return NewDefaultServiceWithCatalogAndSourceQualityJudge(nil, nil)
}

func NewDefaultServiceWithCatalog(catalog MusicCatalog) *Service {
	return NewDefaultServiceWithCatalogAndSourceQualityJudge(catalog, nil)
}

// NewDefaultServiceWithCatalogAndSourceQualityJudge installs an optional judge
// on the default source providers. A nil judge preserves deterministic ranking.
func NewDefaultServiceWithCatalogAndSourceQualityJudge(catalog MusicCatalog, judge SourceQualityJudge) *Service {
	providers := []Provider{
		NewYouTubeProvider(),
		NewYTDLPProvider("soundcloud", "scsearch", ""),
	}
	return NewService(ServiceConfig{Providers: providers, DefaultProviders: []string{"youtube", "soundcloud"}, MusicCatalog: catalog, SourceQualityJudge: judge})
}

// NewYouTubeProvider searches both the ordinary YouTube video index and the
// YouTube Music songs surface. The latter is required because label-provided
// audio is not reliably present in ordinary video search results.
func NewYouTubeProvider() Provider {
	return newCombinedProvider("youtube", []Provider{
		NewYTDLPProvider("youtube", "ytsearch", "https://www.youtube.com/watch?v="),
		NewYouTubeMusicProvider("youtube"),
	})
}

func (s *Service) Search(ctx context.Context, query string, requested []string, limit int) SearchResponse {
	if limit <= 0 {
		limit = 10
	}
	if limit > 25 {
		limit = 25
	}
	sourceProviders, includeCatalog := s.resolveRequest(requested)
	ctx, cancel := context.WithTimeout(ctx, s.overallTimeout)
	defer cancel()
	raw := s.searchSourcesWithContext(ctx, query, sourceProviders, limit)
	resp := SearchResponse{Query: query, Results: rankSourceCandidatesWithJudge(ctx, query, raw.Results, s.sourceQualityJudge), Sections: []SearchSection{}, Providers: raw.Providers}
	sections, catalogSummary := s.buildSections(ctx, query, limit, resp.Results, includeCatalog)
	resp.Sections = sections
	if catalogSummary != nil {
		resp.Providers = append(resp.Providers, *catalogSummary)
	}
	return resp
}

// SourceSearchResponse is the pre-ranking source-provider fanout result. It is
// intentionally separate from Search so private research callers can inspect a
// bounded candidate pool without running the deterministic or optional model
// ranking twice.
type SourceSearchResponse struct {
	Query     string            `json:"query"`
	Results   []Candidate       `json:"results"`
	Providers []ProviderSummary `json:"providers"`
}

// SearchSources reuses the normal provider fanout but deliberately excludes
// catalog lookups and ranking. Callers must not expose Candidate.SourceURL to
// untrusted consumers.
func (s *Service) SearchSources(ctx context.Context, query string, requested []string, limit int) SourceSearchResponse {
	if limit <= 0 {
		limit = 10
	}
	if limit > 25 {
		limit = 25
	}
	sourceProviders, _ := s.resolveRequest(requested)
	ctx, cancel := context.WithTimeout(ctx, s.overallTimeout)
	defer cancel()
	return s.searchSourcesWithContext(ctx, query, sourceProviders, limit)
}

func (s *Service) searchSourcesWithContext(ctx context.Context, query string, sourceProviders []string, limit int) SourceSearchResponse {

	type result struct {
		provider string
		items    []Candidate
		err      error
		elapsed  time.Duration
	}
	ch := make(chan result, len(sourceProviders))
	var wg sync.WaitGroup
	for _, providerName := range sourceProviders {
		name := strings.TrimSpace(providerName)
		if name == "" {
			continue
		}
		p := s.providers[name]
		if p == nil {
			ch <- result{provider: name, err: &providerFailure{code: ErrProviderUnsupported, status: ProviderStatusUnsupported, err: fmt.Errorf("provider %s is not supported", name)}}
			continue
		}
		wg.Add(1)
		go func(p Provider) {
			defer wg.Done()
			start := time.Now()
			providerCtx, providerCancel := context.WithTimeout(ctx, s.perProviderTimeout)
			defer providerCancel()
			items, err := p.Search(providerCtx, query, limit)
			ch <- result{provider: p.Name(), items: items, err: err, elapsed: time.Since(start)}
		}(p)
	}
	go func() {
		wg.Wait()
		close(ch)
	}()

	resp := SourceSearchResponse{Query: query, Results: []Candidate{}, Providers: []ProviderSummary{}}
	providerItems := make(map[string][]Candidate, len(sourceProviders))
	for res := range ch {
		summary := ProviderSummary{Provider: res.provider, ResultCount: len(res.items), ElapsedMs: res.elapsed.Milliseconds()}
		if res.err != nil {
			summary.Status = ProviderStatusFailed
			code := ErrProviderUnavailable
			if errors.Is(res.err, context.DeadlineExceeded) || errors.Is(res.err, context.Canceled) {
				code = ErrProviderTimeout
				summary.Status = ProviderStatusTimeout
			}
			var pf *providerFailure
			if errors.As(res.err, &pf) {
				code = pf.code
				summary.Status = pf.status
			}
			summary.Error = &ProviderError{Code: code, Message: res.err.Error()}
		} else {
			summary.Status = ProviderStatusOK
			providerItems[res.provider] = res.items
		}
		resp.Providers = append(resp.Providers, summary)
	}
	for _, providerName := range sourceProviders {
		resp.Results = append(resp.Results, providerItems[providerName]...)
	}
	return resp
}

// SearchCatalog reuses the existing MusicBrainz client for one explicitly
// requested catalog kind. It has no source-provider or ranking side effects.
func (s *Service) SearchCatalog(ctx context.Context, query, kind string, limit int) ([]SearchItem, error) {
	if s.musicCatalog == nil {
		return nil, errors.New("music catalog is unavailable")
	}
	if limit <= 0 {
		limit = 10
	}
	if limit > 25 {
		limit = 25
	}
	if limit > 8 {
		limit = 8
	}
	switch kind {
	case "track":
		resp, err := s.musicCatalog.SearchTracks(ctx, query, limit, 0, false)
		return trackItems(resp), err
	case "artist":
		resp, err := s.musicCatalog.SearchArtists(ctx, query, limit, 0, false)
		return artistItems(resp), err
	case "album":
		resp, err := s.musicCatalog.SearchAlbums(ctx, query, limit, 0, false)
		return albumItems(resp), err
	default:
		return nil, fmt.Errorf("unsupported catalog kind %q", kind)
	}
}

func (s *Service) buildSections(ctx context.Context, query string, limit int, sourceCandidates []Candidate, includeCatalog bool) ([]SearchSection, *ProviderSummary) {
	sections := []SearchSection{}
	var catalogSummary *ProviderSummary
	if includeCatalog && s.musicCatalog != nil {
		tracks, artists, albums, summary := s.searchMusicCatalog(ctx, query, limit)
		catalogSummary = &summary
		if len(tracks) > 0 {
			sections = append(sections, SearchSection{Kind: "tracks", Title: "Songs", Items: tracks})
		}
		if len(artists) > 0 {
			sections = append(sections, SearchSection{Kind: "artists", Title: "Artists", Items: artists})
		}
		if len(albums) > 0 {
			sections = append(sections, SearchSection{Kind: "albums", Title: "Albums", Items: albums})
		}
	}
	if len(sourceCandidates) > 0 {
		items := make([]SearchItem, 0, len(sourceCandidates))
		for _, candidate := range sourceCandidates {
			candidateCopy := candidate
			items = append(items, SearchItem{
				Kind:       "source",
				ID:         candidate.CandidateID,
				Title:      candidate.Title,
				Subtitle:   candidateSubtitle(candidate),
				Artist:     candidate.Artist,
				DurationMs: candidate.DurationMs,
				Candidate:  &candidateCopy,
			})
		}
		sections = append(sections, SearchSection{Kind: "sources", Title: "Sources", Items: items})
	}
	return sections, catalogSummary
}

func (s *Service) searchMusicCatalog(ctx context.Context, query string, limit int) ([]SearchItem, []SearchItem, []SearchItem, ProviderSummary) {
	entityLimit := limit
	if entityLimit > 8 {
		entityLimit = 8
	}
	if entityLimit <= 0 {
		entityLimit = 8
	}
	summary := ProviderSummary{Provider: CatalogProvider, Status: ProviderStatusOK}
	start := time.Now()
	var errMessages []string
	var errs []error

	tracksResp, err := s.musicCatalog.SearchTracks(ctx, query, entityLimit, 0, false)
	if err != nil {
		errMessages = append(errMessages, "tracks: "+err.Error())
		errs = append(errs, err)
	}
	artistsResp, err := s.musicCatalog.SearchArtists(ctx, query, entityLimit, 0, false)
	if err != nil {
		errMessages = append(errMessages, "artists: "+err.Error())
		errs = append(errs, err)
	}
	albumsResp, err := s.musicCatalog.SearchAlbums(ctx, query, entityLimit, 0, false)
	if err != nil {
		errMessages = append(errMessages, "albums: "+err.Error())
		errs = append(errs, err)
	}

	tracks := trackItems(tracksResp)
	artists := artistItems(artistsResp)
	albums := albumItems(albumsResp)
	summary.ResultCount = len(tracks) + len(artists) + len(albums)
	summary.ElapsedMs = time.Since(start).Milliseconds()
	if len(errMessages) > 0 {
		summary.Status = ProviderStatusFailed
		code := ErrProviderUnavailable
		for _, err := range errs {
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				code = ErrProviderTimeout
				summary.Status = ProviderStatusTimeout
				break
			}
		}
		summary.Error = &ProviderError{Code: code, Message: strings.Join(errMessages, "; ")}
	}
	return tracks, artists, albums, summary
}

func trackItems(resp *musicbrainz.SearchResponse[musicbrainz.TrackResult]) []SearchItem {
	if resp == nil {
		return nil
	}
	items := make([]SearchItem, 0, len(resp.Results))
	for _, track := range resp.Results {
		items = append(items, SearchItem{Kind: "track", ID: track.MBID, Title: track.Title, Subtitle: joinParts(track.Artist, track.Album), Artist: track.Artist, ArtistMBID: track.ArtistMBID, Album: track.Album, AlbumMBID: track.AlbumMBID, DurationMs: track.Duration, ReleaseDate: track.ReleaseDate, Score: track.Score})
	}
	sortItems(items)
	return items
}

func artistItems(resp *musicbrainz.SearchResponse[musicbrainz.ArtistResult]) []SearchItem {
	if resp == nil {
		return nil
	}
	items := make([]SearchItem, 0, len(resp.Results))
	for _, artist := range resp.Results {
		items = append(items, SearchItem{Kind: "artist", ID: artist.MBID, Title: artist.Name, Subtitle: joinParts(artist.Type, artist.Country, artist.Disambiguation), Score: artist.Score})
	}
	sortItems(items)
	return items
}

func albumItems(resp *musicbrainz.SearchResponse[musicbrainz.AlbumResult]) []SearchItem {
	if resp == nil {
		return nil
	}
	items := make([]SearchItem, 0, len(resp.Results))
	for _, album := range resp.Results {
		items = append(items, SearchItem{Kind: "album", ID: album.MBID, Title: album.Title, Subtitle: joinParts(album.Artist, album.PrimaryType, album.ReleaseDate), Artist: album.Artist, ArtistMBID: album.ArtistMBID, ReleaseDate: album.ReleaseDate, Score: album.Score})
	}
	sortItems(items)
	return items
}

func sortItems(items []SearchItem) {
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].Score != items[j].Score {
			return items[i].Score > items[j].Score
		}
		return strings.ToLower(items[i].Title) < strings.ToLower(items[j].Title)
	})
}

func candidateSubtitle(candidate Candidate) string {
	return joinParts(firstNonEmpty(candidate.Artist, candidate.Uploader), candidate.Provider)
}

func joinParts(parts ...string) string {
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return strings.Join(out, " • ")
}

// resolveRequest splits the requested entries into concrete source providers
// and a flag for whether the MusicBrainz catalog grouping should run. Callers
// opt into the catalog explicitly via CatalogProvider, so a provider-scoped,
// source-only request (e.g. providers=youtube) returns promptly without waiting
// on catalog lookups. An empty request falls back to the default providers and
// includes the catalog so the full grouped discovery experience is preserved.
func (s *Service) resolveRequest(requested []string) ([]string, bool) {
	trimmed := make([]string, 0, len(requested))
	for _, providerName := range requested {
		if name := strings.TrimSpace(providerName); name != "" {
			trimmed = append(trimmed, name)
		}
	}
	if len(trimmed) == 0 {
		return s.normalizeRequestedProviders(nil), true
	}

	includeCatalog := false
	seen := make(map[string]struct{}, len(trimmed))
	sources := make([]string, 0, len(trimmed))
	for _, name := range trimmed {
		if strings.EqualFold(name, CatalogProvider) {
			includeCatalog = true
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		sources = append(sources, name)
	}
	return sources, includeCatalog
}

func (s *Service) normalizeRequestedProviders(requested []string) []string {
	if len(requested) == 0 {
		requested = s.defaultProviders
	}
	seen := make(map[string]struct{}, len(requested))
	normalized := make([]string, 0, len(requested))
	for _, providerName := range requested {
		name := strings.TrimSpace(providerName)
		if name == "" {
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		normalized = append(normalized, name)
	}
	return normalized
}

type Handlers struct {
	service        *Service
	resolver       *URLResolver
	assist         *AssistService
	selectionStore sourceSelectionStore
}

type sourceSelectionStore interface {
	CreateSession(context.Context, *db.SourceSelectionSession) error
}

// NewHandlers builds discovery handlers with a disabled-but-functional assist
// service: the direct-URL assist path still resolves user-pasted links without a
// model, and non-URL prompts return a disabled envelope. Use NewHandlersWithAssist
// to enable the model-driven assist path.
func NewHandlers(service *Service) *Handlers {
	return NewHandlersWithAssist(service, nil)
}

// NewHandlersWithAssist builds discovery handlers wired to the given assist
// service (typically model-enabled). A nil assist falls back to a
// disabled-but-functional service that still resolves direct URLs without a
// model. One resolver is shared between the resolve-url endpoint and the assist
// service so both validate pasted URLs identically; a future custom validator
// registry then applies to both at once.
func NewHandlersWithAssist(service *Service, assist *AssistService) *Handlers {
	return NewHandlersWithAssistAndSelectionStore(service, assist, nil)
}

// NewHandlersWithAssistAndSelectionStore wires the server-owned source
// selection session store. A nil store intentionally leaves discovery disabled
// for legacy embeddings rather than returning un-gated candidates.
func NewHandlersWithAssistAndSelectionStore(service *Service, assist *AssistService, selectionStore sourceSelectionStore) *Handlers {
	resolver := NewURLResolver(nil)
	if assist == nil {
		assist = NewAssistService(AssistConfig{Search: service})
	}
	assist.resolver = resolver
	return &Handlers{
		service:        service,
		resolver:       resolver,
		assist:         assist,
		selectionStore: selectionStore,
	}
}

func (h *Handlers) Search(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeError(w, http.StatusBadRequest, "INVALID_QUERY", "q is required")
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	providers := splitCSV(r.URL.Query().Get("providers"))
	resp := h.service.Search(r.Context(), query, providers, limit)
	if len(resp.Providers) == 0 {
		writeError(w, http.StatusBadRequest, "NO_PROVIDERS", "no discovery providers can be attempted")
		return
	}
	if userCtx != nil && !h.persistSelection(w, r, userCtx.UserID, &resp, "discovery_search") {
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

const sourceSelectionSessionTTL = 15 * time.Minute

func (h *Handlers) persistSelection(w http.ResponseWriter, r *http.Request, userID uuid.UUID, response *SearchResponse, selectionContext string) bool {
	if len(response.Results) == 0 {
		response.SelectionRequired = false
		return true
	}
	if h.selectionStore == nil {
		writeError(w, http.StatusServiceUnavailable, "SOURCE_SELECTION_UNAVAILABLE", "source selection persistence is unavailable")
		return false
	}
	snapshot, err := json.Marshal(response.Results)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to persist source selection")
		return false
	}
	recommended := response.Results[0].CandidateID
	if strings.TrimSpace(recommended) == "" {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to persist source selection")
		return false
	}
	expiresAt := time.Now().Add(sourceSelectionSessionTTL)
	session := &db.SourceSelectionSession{UserID: userID, Query: response.Query, Context: selectionContext, Candidates: snapshot, RecommendedCandidateID: recommended, ExpiresAt: expiresAt}
	if err := h.selectionStore.CreateSession(r.Context(), session); err != nil {
		writeError(w, http.StatusInternalServerError, "SOURCE_SELECTION_PERSISTENCE_FAILED", "failed to persist source selection")
		return false
	}
	response.SelectionRequired = true
	response.SelectionSessionID = session.ID.String()
	response.RecommendedCandidateID = recommended
	response.SelectionExpiresAt = &session.ExpiresAt
	return true
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]interface{}{"code": code, "message": message})
}

// YTDLPProvider shells out to yt-dlp for local dogfood discovery. If yt-dlp is
// not installed, the provider fails in isolation instead of breaking the API.
type YTDLPProvider struct {
	name      string
	prefix    string
	urlPrefix string
	music     bool
}

func NewYTDLPProvider(name, prefix, urlPrefix string) *YTDLPProvider {
	return &YTDLPProvider{name: name, prefix: prefix, urlPrefix: urlPrefix}
}

// NewYouTubeMusicProvider queries yt-dlp's YouTube Music songs surface. It
// intentionally keeps the canonical youtube provider name so resolver, queue,
// and downloader handling remain identical to ordinary YouTube candidates.
func NewYouTubeMusicProvider(name string) *YTDLPProvider {
	return &YTDLPProvider{name: name, music: true, urlPrefix: "https://www.youtube.com/watch?v="}
}

func (p *YTDLPProvider) Name() string { return p.name }

func (p *YTDLPProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	if _, err := exec.LookPath("yt-dlp"); err != nil {
		return nil, &providerFailure{code: ErrProviderDisabled, status: ProviderStatusDisabled, err: fmt.Errorf("yt-dlp is not installed for provider %s: %w", p.name, err)}
	}
	cmd := exec.CommandContext(ctx, "yt-dlp", p.commandArgs(query, limit)...)
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &providerFailure{code: ErrProviderBadResponse, status: ProviderStatusFailed, err: fmt.Errorf("yt-dlp search failed for %s: %w", p.name, err)}
	}
	return p.candidatesFromOutput(string(out), limit), nil
}

func (p *YTDLPProvider) candidatesFromOutput(output string, limit int) []Candidate {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	items := make([]Candidate, 0, len(lines))
	for _, line := range lines {
		if len(items) >= limit {
			break
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		var raw map[string]interface{}
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			continue
		}
		id := stringValue(raw, "id")
		sourceURL := stringValue(raw, "webpage_url")
		if sourceURL == "" {
			sourceURL = stringValue(raw, "url")
		}
		if !strings.HasPrefix(sourceURL, "http") && p.urlPrefix != "" && id != "" {
			sourceURL = p.urlPrefix + id
		}
		title := stringValue(raw, "title")
		metadata := ytdlpCandidateMetadata(raw, p.name, p.music)
		items = append(items, Candidate{
			CandidateID:  buildCandidateID(p.name, id, sourceURL),
			Provider:     p.name,
			SourceID:     id,
			SourceURL:    sourceURL,
			Title:        title,
			Artist:       firstNonEmpty(stringValue(raw, "artist"), stringValue(raw, "creator")),
			Uploader:     stringValue(raw, "uploader"),
			DurationMs:   int(floatValue(raw, "duration") * 1000),
			ThumbnailURL: stringValue(raw, "thumbnail"),
			Downloadable: sourceURL != "",
			Playable:     false,
			Metadata:     metadata,
		})
	}
	return items
}

func (p *YTDLPProvider) searchArg(query string, limit int) string {
	if p.music {
		musicURL := &url.URL{Scheme: "https", Host: "music.youtube.com", Path: "/search"}
		values := musicURL.Query()
		values.Set("q", query)
		musicURL.RawQuery = values.Encode()
		musicURL.Fragment = "songs"
		return musicURL.String()
	}
	return fmt.Sprintf("%s%d:%s", p.prefix, limit, query)
}

func (p *YTDLPProvider) commandArgs(query string, limit int) []string {
	// Search surfaces expose a playlist-like result set. Flattening it prevents
	// yt-dlp from resolving every result's full watch metadata before discovery
	// can rank candidates under the provider deadline.
	return []string{"--flat-playlist", "--playlist-end", strconv.Itoa(limit), "--dump-json", "--skip-download", p.searchArg(query, limit)}
}

func ytdlpCandidateMetadata(raw map[string]interface{}, provider string, music bool) map[string]interface{} {
	metadata := map[string]interface{}{"providerRawType": stringValue(raw, "_type")}
	if music {
		metadata["discoverySurface"] = "youtube_music_songs"
	} else if provider == "youtube" {
		metadata["discoverySurface"] = "youtube_search"
	} else {
		metadata["discoverySurface"] = provider + "_search"
	}
	for _, key := range []string{"description", "track", "album", "artist", "label", "release_date", "release_year", "channel", "channel_id", "uploader_id", "categories", "tags"} {
		if value, ok := raw[key]; ok && value != nil {
			metadata[key] = value
		}
	}
	return metadata
}

// combinedProvider keeps one public provider identity while acquiring multiple
// independent surfaces. It returns successes even when one surface fails.
type combinedProvider struct {
	name      string
	providers []Provider
}

func newCombinedProvider(name string, providers []Provider) *combinedProvider {
	return &combinedProvider{name: name, providers: providers}
}

func (p *combinedProvider) Name() string { return p.name }

func (p *combinedProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	type result struct {
		items []Candidate
		err   error
	}
	results := make([]result, len(p.providers))
	var wg sync.WaitGroup
	for index, provider := range p.providers {
		wg.Add(1)
		go func(index int, provider Provider) {
			defer wg.Done()
			items, err := provider.Search(ctx, query, limit)
			results[index] = result{items: items, err: err}
		}(index, provider)
	}
	wg.Wait()

	items := make([]Candidate, 0, limit*len(p.providers))
	seen := make(map[string]struct{})
	var errs []string
	for _, result := range results {
		if result.err != nil {
			errs = append(errs, result.err.Error())
			continue
		}
		for _, candidate := range result.items {
			key := candidate.CandidateID
			if key == "" {
				key = candidate.SourceURL
			}
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			items = append(items, candidate)
		}
	}
	if len(items) > 0 {
		return items, nil
	}
	if len(errs) > 0 {
		return nil, &providerFailure{code: ErrProviderBadResponse, status: ProviderStatusFailed, err: fmt.Errorf("all %s search surfaces failed: %s", p.name, strings.Join(errs, "; "))}
	}
	return items, nil
}

func stringValue(raw map[string]interface{}, key string) string {
	if v, ok := raw[key].(string); ok {
		return v
	}
	return ""
}

func floatValue(raw map[string]interface{}, key string) float64 {
	switch v := raw[key].(type) {
	case float64:
		return v
	case int:
		return float64(v)
	default:
		return 0
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

// buildCandidateID derives the stable candidate identifier shared by source
// search results and the direct-URL resolver. Keeping one format means both
// paths dedupe consistently in the queue and library. It prefers the source ID
// and falls back to the source URL when the provider yields no ID.
func buildCandidateID(provider, sourceID, sourceURL string) string {
	if sourceID != "" {
		return provider + ":" + sourceID
	}
	return provider + ":" + sourceURL
}
