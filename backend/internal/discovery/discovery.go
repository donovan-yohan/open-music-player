package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
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
	Query     string            `json:"query"`
	Results   []Candidate       `json:"results"`
	Providers []ProviderSummary `json:"providers"`
}

type Provider interface {
	Name() string
	Search(ctx context.Context, query string, limit int) ([]Candidate, error)
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
	overallTimeout     time.Duration
	perProviderTimeout time.Duration
}

type ServiceConfig struct {
	Providers          []Provider
	DefaultProviders   []string
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
	return &Service{providers: providers, defaultProviders: defaults, overallTimeout: cfg.OverallTimeout, perProviderTimeout: cfg.PerProviderTimeout}
}

func NewDefaultService() *Service {
	providers := []Provider{
		NewYTDLPProvider("youtube", "ytsearch", "https://www.youtube.com/watch?v="),
		NewYTDLPProvider("soundcloud", "scsearch", ""),
	}
	return NewService(ServiceConfig{Providers: providers, DefaultProviders: []string{"youtube", "soundcloud"}})
}

func (s *Service) Search(ctx context.Context, query string, requested []string, limit int) SearchResponse {
	if limit <= 0 {
		limit = 10
	}
	if limit > 25 {
		limit = 25
	}
	if len(requested) == 0 {
		requested = s.defaultProviders
	}

	ctx, cancel := context.WithTimeout(ctx, s.overallTimeout)
	defer cancel()

	type result struct {
		provider string
		items    []Candidate
		err      error
		elapsed  time.Duration
	}
	ch := make(chan result, len(requested))
	var wg sync.WaitGroup
	for _, providerName := range requested {
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

	resp := SearchResponse{Query: query, Results: []Candidate{}, Providers: []ProviderSummary{}}
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
			resp.Results = append(resp.Results, res.items...)
		}
		resp.Providers = append(resp.Providers, summary)
	}
	return resp
}

type Handlers struct{ service *Service }

func NewHandlers(service *Service) *Handlers { return &Handlers{service: service} }

func (h *Handlers) Search(w http.ResponseWriter, r *http.Request) {
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
	writeJSON(w, http.StatusOK, resp)
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
}

func NewYTDLPProvider(name, prefix, urlPrefix string) *YTDLPProvider {
	return &YTDLPProvider{name: name, prefix: prefix, urlPrefix: urlPrefix}
}

func (p *YTDLPProvider) Name() string { return p.name }

func (p *YTDLPProvider) Search(ctx context.Context, query string, limit int) ([]Candidate, error) {
	if _, err := exec.LookPath("yt-dlp"); err != nil {
		return nil, &providerFailure{code: ErrProviderDisabled, status: ProviderStatusDisabled, err: fmt.Errorf("yt-dlp is not installed for provider %s", p.name)}
	}
	searchArg := fmt.Sprintf("%s%d:%s", p.prefix, limit, query)
	cmd := exec.CommandContext(ctx, "yt-dlp", "--dump-json", "--skip-download", "--flat-playlist", searchArg)
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &providerFailure{code: ErrProviderBadResponse, status: ProviderStatusFailed, err: fmt.Errorf("yt-dlp search failed for %s: %w", p.name, err)}
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	items := make([]Candidate, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var raw map[string]interface{}
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			continue
		}
		id := stringValue(raw, "id")
		sourceURL := stringValue(raw, "url")
		if !strings.HasPrefix(sourceURL, "http") && p.urlPrefix != "" && id != "" {
			sourceURL = p.urlPrefix + id
		}
		if sourceURL == "" {
			sourceURL = stringValue(raw, "webpage_url")
		}
		title := stringValue(raw, "title")
		candidateID := p.name + ":" + id
		if id == "" {
			candidateID = p.name + ":" + sourceURL
		}
		items = append(items, Candidate{
			CandidateID:  candidateID,
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
			Metadata:     map[string]interface{}{"providerRawType": stringValue(raw, "_type")},
		})
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
