package discovery

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	agentToolsPrefix            = "/internal/agent-tools/v1"
	agentToolsMaxRequestBytes   = 16 * 1024
	agentToolsMaxResponseBytes  = 64 * 1024
	agentToolsMaxQueryBytes     = 512
	agentToolsMaxEvidenceBytes  = 4 * 1024
	defaultCapabilityTTL        = 10 * time.Minute
	defaultCapabilityCalls      = 24
	defaultFirecrawlTimeout     = 5 * time.Second
	defaultFirecrawlURL         = "https://api.firecrawl.dev/v2/scrape"
	defaultMaxCapabilities      = 128
	defaultCandidateLimit       = 64
	defaultEvidenceLimit        = 64
	defaultRetainedByteLimit    = 256 * 1024
	defaultIssuanceWindow       = time.Minute
	defaultIssuanceLimit        = 32
	defaultProviderConcurrency  = 4
	defaultFirecrawlConcurrency = 2
	defaultCleanupInterval      = time.Minute
	hardMaxCapabilities         = 1024
	hardMaxCandidates           = 256
	hardMaxEvidenceRefs         = 256
	hardMaxRetainedBytes        = 4 * 1024 * 1024
	hardMaxIssuanceLimit        = 1000
	hardMaxProviderConcurrency  = 32
	hardMaxFirecrawlConcurrency = 16
)

var (
	agentToolURLPattern      = regexp.MustCompile(`(?i)https?://\S+`)
	youtubeVideoIDPattern    = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)
	soundCloudSlugPattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$`)
	providerErrorCodePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
	opaqueReferencePattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	unsafeSecretTextPattern  = regexp.MustCompile(`(?i)(?:\b(?:authorization|bearer|api[_-]?key|secret|token|password)\b|\bsk-[A-Za-z0-9_-]+)`)
	unsafeURLTextPattern     = regexp.MustCompile(`(?i)(?:https?://|www\.|mailto:|ftp://)`)
)

// AgentToolsConfig intentionally has no public URL-input setting. The only
// external URL is the fixed Firecrawl endpoint; FirecrawlURL exists solely to
// make the HTTP client boundary deterministic in package tests.
type AgentToolsConfig struct {
	ServiceToken         string
	FirecrawlAPIKey      string
	Search               *Service
	Clock                func() time.Time
	Random               io.Reader
	HTTPClient           *http.Client
	FirecrawlURL         string
	CapabilityTTL        time.Duration
	CapabilityCalls      int
	FirecrawlTimeout     time.Duration
	MaxCapabilities      int
	CandidateLimit       int
	EvidenceLimit        int
	RetainedByteLimit    int
	IssuanceWindow       time.Duration
	IssuanceLimit        int
	ProviderConcurrency  int
	FirecrawlConcurrency int
	CleanupInterval      time.Duration
	CleanupTickerFactory func(time.Duration) (<-chan time.Time, func())
}

type AgentToolsHandler struct {
	serviceToken         string
	firecrawlAPIKey      string
	search               *Service
	now                  func() time.Time
	random               io.Reader
	httpClient           *http.Client
	firecrawlURL         string
	capabilityTTL        time.Duration
	capabilityCalls      int
	firecrawlTimeout     time.Duration
	maxCapabilities      int
	candidateLimit       int
	evidenceLimit        int
	retainedByteLimit    int
	issuanceWindow       time.Duration
	issuanceLimit        int
	providerSlots        chan struct{}
	firecrawlSlots       chan struct{}
	cleanupInterval      time.Duration
	cleanupTickerFactory func(time.Duration) (<-chan time.Time, func())
	done                 chan struct{}
	closeOnce            sync.Once

	mu                    sync.Mutex
	capabilities          map[string]*agentCapability
	issuanceWindowStarted time.Time
	issuanceCount         int
	cleanupRunning        bool
}

type agentCapability struct {
	expiresAt     time.Time
	calls         int
	candidates    map[string]*storedAgentCandidate
	evidence      map[string]string
	retainedBytes int
}

type storedAgentCandidate struct {
	candidate agentSourceCandidate
}

// NewAgentToolsHandler returns nil when the service token is empty. This is the
// only enable switch: partial Firecrawl configuration never changes route
// registration or ordinary deterministic discovery.
func NewAgentToolsHandler(cfg AgentToolsConfig) *AgentToolsHandler {
	if strings.TrimSpace(cfg.ServiceToken) == "" || cfg.Search == nil {
		return nil
	}
	if cfg.Clock == nil {
		cfg.Clock = time.Now
	}
	if cfg.Random == nil {
		cfg.Random = rand.Reader
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: defaultFirecrawlTimeout}
	}
	clientCopy := *cfg.HTTPClient
	clientCopy.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	cfg.HTTPClient = &clientCopy
	if cfg.FirecrawlURL == "" {
		cfg.FirecrawlURL = defaultFirecrawlURL
	}
	if cfg.CapabilityTTL <= 0 {
		cfg.CapabilityTTL = defaultCapabilityTTL
	}
	if cfg.CapabilityCalls <= 0 {
		cfg.CapabilityCalls = defaultCapabilityCalls
	}
	if cfg.CapabilityCalls > 1000 {
		cfg.CapabilityCalls = 1000
	}
	if cfg.FirecrawlTimeout <= 0 {
		cfg.FirecrawlTimeout = defaultFirecrawlTimeout
	}
	if cfg.MaxCapabilities <= 0 {
		cfg.MaxCapabilities = defaultMaxCapabilities
	}
	if cfg.MaxCapabilities > hardMaxCapabilities {
		cfg.MaxCapabilities = hardMaxCapabilities
	}
	if cfg.CandidateLimit <= 0 {
		cfg.CandidateLimit = defaultCandidateLimit
	}
	if cfg.CandidateLimit > hardMaxCandidates {
		cfg.CandidateLimit = hardMaxCandidates
	}
	if cfg.EvidenceLimit <= 0 {
		cfg.EvidenceLimit = defaultEvidenceLimit
	}
	if cfg.EvidenceLimit > hardMaxEvidenceRefs {
		cfg.EvidenceLimit = hardMaxEvidenceRefs
	}
	if cfg.RetainedByteLimit <= 0 {
		cfg.RetainedByteLimit = defaultRetainedByteLimit
	}
	if cfg.RetainedByteLimit > hardMaxRetainedBytes {
		cfg.RetainedByteLimit = hardMaxRetainedBytes
	}
	if cfg.IssuanceWindow <= 0 {
		cfg.IssuanceWindow = defaultIssuanceWindow
	}
	if cfg.IssuanceLimit <= 0 {
		cfg.IssuanceLimit = defaultIssuanceLimit
	}
	if cfg.IssuanceLimit > hardMaxIssuanceLimit {
		cfg.IssuanceLimit = hardMaxIssuanceLimit
	}
	if cfg.ProviderConcurrency <= 0 {
		cfg.ProviderConcurrency = defaultProviderConcurrency
	}
	if cfg.ProviderConcurrency > hardMaxProviderConcurrency {
		cfg.ProviderConcurrency = hardMaxProviderConcurrency
	}
	if cfg.FirecrawlConcurrency <= 0 {
		cfg.FirecrawlConcurrency = defaultFirecrawlConcurrency
	}
	if cfg.FirecrawlConcurrency > hardMaxFirecrawlConcurrency {
		cfg.FirecrawlConcurrency = hardMaxFirecrawlConcurrency
	}
	if cfg.CleanupInterval <= 0 {
		cfg.CleanupInterval = defaultCleanupInterval
	}
	if cfg.CleanupTickerFactory == nil {
		cfg.CleanupTickerFactory = newAgentToolsTicker
	}
	return &AgentToolsHandler{
		serviceToken: strings.TrimSpace(cfg.ServiceToken), firecrawlAPIKey: strings.TrimSpace(cfg.FirecrawlAPIKey), search: cfg.Search,
		now: cfg.Clock, random: cfg.Random, httpClient: cfg.HTTPClient, firecrawlURL: cfg.FirecrawlURL,
		capabilityTTL: cfg.CapabilityTTL, capabilityCalls: cfg.CapabilityCalls, firecrawlTimeout: cfg.FirecrawlTimeout,
		maxCapabilities: cfg.MaxCapabilities, candidateLimit: cfg.CandidateLimit, evidenceLimit: cfg.EvidenceLimit, retainedByteLimit: cfg.RetainedByteLimit,
		issuanceWindow: cfg.IssuanceWindow, issuanceLimit: cfg.IssuanceLimit,
		providerSlots: make(chan struct{}, cfg.ProviderConcurrency), firecrawlSlots: make(chan struct{}, cfg.FirecrawlConcurrency),
		cleanupInterval: cfg.CleanupInterval, cleanupTickerFactory: cfg.CleanupTickerFactory, done: make(chan struct{}),
		capabilities: make(map[string]*agentCapability),
	}
}

func newAgentToolsTicker(interval time.Duration) (<-chan time.Time, func()) {
	ticker := time.NewTicker(interval)
	return ticker.C, ticker.Stop
}

func (h *AgentToolsHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	switch r.URL.Path {
	case agentToolsPrefix + "/capabilities":
		h.capabilitiesHandler(w, r)
	case agentToolsPrefix + "/search-sources":
		h.withCapability(w, r, h.searchSources)
	case agentToolsPrefix + "/search-catalog":
		h.withCapability(w, r, h.searchCatalog)
	case agentToolsPrefix + "/inspect-source-metadata":
		h.withCapability(w, r, h.inspectSourceMetadata)
	case agentToolsPrefix + "/extract-web":
		h.withCapability(w, r, h.extractWeb)
	default:
		http.NotFound(w, r)
	}
}

func (h *AgentToolsHandler) capabilitiesHandler(w http.ResponseWriter, r *http.Request) {
	if !constantTimeEqual(r.Header.Get("X-OMP-Agent-Service-Token"), h.serviceToken) {
		writeAgentToolError(w, http.StatusUnauthorized, "SERVICE_UNAUTHORIZED", "service authentication failed")
		return
	}
	var request struct{}
	if err := decodeAgentToolJSON(w, r, &request); err != nil {
		writeAgentToolError(w, http.StatusBadRequest, "INVALID_JSON", "request body must be strict JSON")
		return
	}
	now := h.now()
	h.mu.Lock()
	h.cleanupLocked(now)
	if h.issuanceWindowStarted.IsZero() || !now.Before(h.issuanceWindowStarted.Add(h.issuanceWindow)) {
		h.issuanceWindowStarted = now
		h.issuanceCount = 0
	}
	if h.issuanceCount >= h.issuanceLimit {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_RATE_LIMIT", "capability issuance rate limit reached")
		return
	}
	if len(h.capabilities) >= h.maxCapabilities {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusServiceUnavailable, "CAPABILITY_BUSY", "capability capacity is full")
		return
	}
	capability, err := h.randomTokenLocked("cap_")
	if err != nil {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusServiceUnavailable, "CAPABILITY_UNAVAILABLE", "capability issuance is unavailable")
		return
	}
	expiresAt := now.Add(h.capabilityTTL).UTC()
	h.issuanceCount++
	h.capabilities[capability] = &agentCapability{expiresAt: expiresAt, candidates: map[string]*storedAgentCandidate{}, evidence: map[string]string{}}
	h.ensureCleanupLocked()
	h.mu.Unlock()
	writeAgentToolJSON(w, http.StatusOK, map[string]interface{}{"capability": capability, "expiresAt": expiresAt, "maxCalls": h.capabilityCalls})
}

func (h *AgentToolsHandler) withCapability(w http.ResponseWriter, r *http.Request, next func(http.ResponseWriter, *http.Request, *agentCapability)) {
	capability, ok := bearerCapability(r.Header.Get("Authorization"))
	if !ok {
		writeAgentToolError(w, http.StatusUnauthorized, "CAPABILITY_UNAUTHORIZED", "capability authentication failed")
		return
	}
	h.mu.Lock()
	state := h.capabilities[capability]
	now := h.now()
	if state != nil && !now.Before(state.expiresAt) {
		delete(h.capabilities, capability)
		h.cleanupLocked(now)
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusUnauthorized, "CAPABILITY_EXPIRED", "capability has expired")
		return
	}
	h.cleanupLocked(now)
	if state == nil {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusUnauthorized, "CAPABILITY_UNKNOWN", "capability is invalid")
		return
	}
	if state.calls >= h.capabilityCalls {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_CALL_LIMIT", "capability call limit reached")
		return
	}
	state.calls++
	h.mu.Unlock()
	next(w, r, state)
}

func (h *AgentToolsHandler) searchSources(w http.ResponseWriter, r *http.Request, state *agentCapability) {
	var req struct {
		Query     string   `json:"query"`
		Providers []string `json:"providers,omitempty"`
		Limit     int      `json:"limit,omitempty"`
	}
	if err := decodeAgentToolJSON(w, r, &req); err != nil || !validAgentQuery(req.Query) || !validSourceProviders(req.Providers) {
		writeAgentToolError(w, http.StatusBadRequest, "INVALID_REQUEST", "query or providers are invalid")
		return
	}
	if req.Limit <= 0 {
		req.Limit = 10
	}
	if req.Limit > 12 {
		req.Limit = 12
	}
	h.mu.Lock()
	remaining := h.candidateLimit - len(state.candidates)
	h.mu.Unlock()
	if remaining <= 0 {
		writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_RESOURCE_LIMIT", "candidate capacity reached")
		return
	}
	if req.Limit > remaining {
		req.Limit = remaining
	}
	if !acquireAgentToolSlot(r.Context(), h.providerSlots) {
		writeAgentToolError(w, http.StatusServiceUnavailable, "PROVIDER_BUSY", "provider capacity is busy")
		return
	}
	result := func() SourceSearchResponse {
		defer releaseAgentToolSlot(h.providerSlots)
		return h.search.SearchSources(r.Context(), strings.TrimSpace(req.Query), req.Providers, req.Limit)
	}()
	type pendingCandidate struct {
		id          string
		stored      *storedAgentCandidate
		evidenceRef string
		evidenceURL string
		bytes       int
	}
	pending := make([]pendingCandidate, 0, len(result.Results))
	pendingEvidence := 0
	pendingBytes := 0
	h.mu.Lock()
	for _, candidate := range result.Results {
		if candidate.Provider != "youtube" && candidate.Provider != "soundcloud" {
			continue
		}
		if len(state.candidates)+len(pending) >= h.candidateLimit {
			h.mu.Unlock()
			writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_RESOURCE_LIMIT", "candidate capacity reached")
			return
		}
		candidateID, err := h.randomTokenLocked("candidate_")
		if err != nil {
			h.mu.Unlock()
			writeAgentToolError(w, http.StatusServiceUnavailable, "CAPABILITY_UNAVAILABLE", "candidate issuance is unavailable")
			return
		}
		model := sanitizeCandidateForStorage(candidateID, candidate)
		entry := pendingCandidate{id: candidateID}
		if canonicalURL, ok := canonicalEvidenceURL(candidate.SourceURL); ok {
			if len(state.evidence)+pendingEvidence >= h.evidenceLimit {
				h.mu.Unlock()
				writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_RESOURCE_LIMIT", "evidence capacity reached")
				return
			}
			evidenceRef, randomErr := h.randomTokenLocked("evidence_")
			if randomErr != nil {
				h.mu.Unlock()
				writeAgentToolError(w, http.StatusServiceUnavailable, "CAPABILITY_UNAVAILABLE", "evidence issuance is unavailable")
				return
			}
			model.EvidenceRefs = []string{evidenceRef}
			entry.evidenceRef = evidenceRef
			entry.evidenceURL = canonicalURL
			pendingEvidence++
		}
		// Never retain the provider Candidate. It may hold unbounded provider
		// fields, whereas model is the bounded, deep-copied capability payload.
		entry.stored = &storedAgentCandidate{candidate: cloneAgentSourceCandidate(model)}
		entry.bytes = retainedCandidateBytes(model, entry.evidenceURL)
		if entry.bytes > h.retainedByteLimit-state.retainedBytes-pendingBytes {
			h.mu.Unlock()
			writeAgentToolError(w, http.StatusTooManyRequests, "CAPABILITY_RESOURCE_LIMIT", "retained byte capacity reached")
			return
		}
		pendingBytes += entry.bytes
		pending = append(pending, entry)
	}
	candidates := make([]agentSourceCandidate, 0, len(pending))
	for _, entry := range pending {
		state.candidates[entry.id] = entry.stored
		if entry.evidenceRef != "" {
			state.evidence[entry.evidenceRef] = entry.evidenceURL
		}
		state.retainedBytes += entry.bytes
		candidates = append(candidates, cloneAgentSourceCandidate(entry.stored.candidate))
	}
	h.mu.Unlock()
	writeAgentToolJSON(w, http.StatusOK, map[string]interface{}{"query": strings.TrimSpace(req.Query), "candidates": candidates, "providers": sanitizeProviderSummaries(result.Providers)})
}

func (h *AgentToolsHandler) searchCatalog(w http.ResponseWriter, r *http.Request, _ *agentCapability) {
	var req struct {
		Query string `json:"query"`
		Kind  string `json:"kind"`
		Limit int    `json:"limit,omitempty"`
	}
	if err := decodeAgentToolJSON(w, r, &req); err != nil || !validAgentQuery(req.Query) || (req.Kind != "track" && req.Kind != "artist" && req.Kind != "album") {
		writeAgentToolError(w, http.StatusBadRequest, "INVALID_REQUEST", "query or catalog kind is invalid")
		return
	}
	if req.Limit <= 0 {
		req.Limit = 8
	}
	if req.Limit > 8 {
		req.Limit = 8
	}
	if !acquireAgentToolSlot(r.Context(), h.providerSlots) {
		writeAgentToolError(w, http.StatusServiceUnavailable, "PROVIDER_BUSY", "provider capacity is busy")
		return
	}
	items, err := func() ([]SearchItem, error) {
		defer releaseAgentToolSlot(h.providerSlots)
		return h.search.SearchCatalog(r.Context(), strings.TrimSpace(req.Query), req.Kind, req.Limit)
	}()
	if err != nil {
		writeAgentToolError(w, http.StatusBadGateway, "CATALOG_UNAVAILABLE", "catalog lookup failed")
		return
	}
	writeAgentToolJSON(w, http.StatusOK, map[string]interface{}{"query": strings.TrimSpace(req.Query), "kind": req.Kind, "items": sanitizeCatalogItems(items, req.Kind)})
}

func (h *AgentToolsHandler) inspectSourceMetadata(w http.ResponseWriter, r *http.Request, state *agentCapability) {
	var req struct {
		CandidateID string `json:"candidateId"`
	}
	if err := decodeAgentToolJSON(w, r, &req); err != nil || strings.TrimSpace(req.CandidateID) == "" {
		writeAgentToolError(w, http.StatusBadRequest, "INVALID_REQUEST", "candidateId is required")
		return
	}
	h.mu.Lock()
	stored, ok := state.candidates[req.CandidateID]
	if !ok {
		h.mu.Unlock()
		writeAgentToolError(w, http.StatusNotFound, "CANDIDATE_UNKNOWN", "candidateId was not issued for this capability")
		return
	}
	response := cloneAgentSourceCandidate(stored.candidate)
	h.mu.Unlock()
	writeAgentToolJSON(w, http.StatusOK, response)
}

func (h *AgentToolsHandler) extractWeb(w http.ResponseWriter, r *http.Request, state *agentCapability) {
	var req struct {
		EvidenceRef string `json:"evidenceRef"`
	}
	if err := decodeAgentToolJSON(w, r, &req); err != nil || strings.TrimSpace(req.EvidenceRef) == "" {
		writeAgentToolError(w, http.StatusBadRequest, "INVALID_REQUEST", "evidenceRef is required")
		return
	}
	if h.firecrawlAPIKey == "" {
		writeAgentToolError(w, http.StatusServiceUnavailable, "FIRECRAWL_DISABLED", "web extraction is not configured")
		return
	}
	h.mu.Lock()
	storedURL, ok := state.evidence[req.EvidenceRef]
	h.mu.Unlock()
	if !ok {
		writeAgentToolError(w, http.StatusNotFound, "EVIDENCE_UNKNOWN", "evidenceRef was not issued for this capability")
		return
	}
	canonicalURL, safe := canonicalEvidenceURL(storedURL)
	if !safe || canonicalURL != storedURL {
		writeAgentToolError(w, http.StatusBadRequest, "EVIDENCE_UNSAFE", "evidence reference is not allowlisted")
		return
	}
	if !acquireAgentToolSlot(r.Context(), h.firecrawlSlots) {
		writeAgentToolError(w, http.StatusServiceUnavailable, "FIRECRAWL_BUSY", "web extraction capacity is busy")
		return
	}
	markdown, code := func() (string, string) {
		defer releaseAgentToolSlot(h.firecrawlSlots)
		return h.firecrawl(r.Context(), canonicalURL)
	}()
	if code != "" {
		status := http.StatusBadGateway
		if code == "FIRECRAWL_RATE_LIMIT" {
			status = http.StatusTooManyRequests
		}
		if code == "FIRECRAWL_DISABLED" {
			status = http.StatusServiceUnavailable
		}
		writeAgentToolError(w, status, code, "web extraction failed")
		return
	}
	markdown = sanitizeEvidence(markdown)
	if markdown == "" {
		writeAgentToolError(w, http.StatusBadGateway, "EVIDENCE_UNSAFE", "web evidence contained no safe text")
		return
	}
	writeAgentToolJSON(w, http.StatusOK, map[string]interface{}{"evidenceRef": req.EvidenceRef, "markdown": markdown})
}

type agentSourceCandidate struct {
	CandidateID  string            `json:"candidateId"`
	Provider     string            `json:"provider"`
	Title        string            `json:"title"`
	Artist       string            `json:"artist,omitempty"`
	Uploader     string            `json:"uploader,omitempty"`
	DurationMs   int               `json:"durationMs,omitempty"`
	Downloadable bool              `json:"downloadable"`
	Playable     bool              `json:"playable"`
	Explicit     *bool             `json:"explicit,omitempty"`
	Metadata     map[string]string `json:"metadata,omitempty"`
	EvidenceRefs []string          `json:"evidenceRefs,omitempty"`
}

func sanitizeCandidateForStorage(candidateID string, candidate Candidate) agentSourceCandidate {
	title := sanitizeBoundedField(candidate.Title, 240)
	if title == "" {
		title = "Untitled source"
	}
	provider := "soundcloud"
	if candidate.Provider == "youtube" {
		provider = "youtube"
	}
	var explicit *bool
	if candidate.Explicit != nil {
		value := *candidate.Explicit
		explicit = &value
	}
	return agentSourceCandidate{
		CandidateID: candidateID, Provider: provider, Title: title,
		Artist: sanitizeBoundedField(candidate.Artist, 180), Uploader: sanitizeBoundedField(candidate.Uploader, 180), DurationMs: clampAgentToolInt(candidate.DurationMs, 0, 86_400_000),
		Downloadable: candidate.Downloadable, Playable: candidate.Playable, Explicit: explicit,
		Metadata: sanitizeMetadata(candidate.Metadata),
	}
}

func cloneAgentSourceCandidate(candidate agentSourceCandidate) agentSourceCandidate {
	clone := candidate
	if candidate.Explicit != nil {
		value := *candidate.Explicit
		clone.Explicit = &value
	}
	if candidate.Metadata != nil {
		clone.Metadata = make(map[string]string, len(candidate.Metadata))
		for key, value := range candidate.Metadata {
			clone.Metadata[strings.Clone(key)] = strings.Clone(value)
		}
	}
	clone.EvidenceRefs = append([]string(nil), candidate.EvidenceRefs...)
	return clone
}

func retainedCandidateBytes(candidate agentSourceCandidate, evidenceURL string) int {
	encoded, _ := json.Marshal(candidate)
	total := len(encoded) + len(evidenceURL)
	for _, ref := range candidate.EvidenceRefs {
		total += len(ref)
	}
	return total
}

func (h *AgentToolsHandler) firecrawl(parent context.Context, sourceURL string) (string, string) {
	ctx, cancel := context.WithTimeout(parent, h.firecrawlTimeout)
	defer cancel()
	body, _ := json.Marshal(map[string]interface{}{"url": sourceURL, "formats": []string{"markdown"}, "onlyMainContent": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.firecrawlURL, strings.NewReader(string(body)))
	if err != nil {
		return "", "FIRECRAWL_FAILED"
	}
	req.Header.Set("Authorization", "Bearer "+h.firecrawlAPIKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.httpClient.Do(req)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return "", "FIRECRAWL_TIMEOUT"
		}
		return "", "FIRECRAWL_FAILED"
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return "", "FIRECRAWL_REDIRECT"
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return "", "FIRECRAWL_RATE_LIMIT"
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", "FIRECRAWL_FAILED"
	}
	limited := io.LimitReader(resp.Body, agentToolsMaxResponseBytes+1)
	contents, err := io.ReadAll(limited)
	if err != nil {
		return "", "FIRECRAWL_FAILED"
	}
	if len(contents) > agentToolsMaxResponseBytes {
		return "", "FIRECRAWL_RESPONSE_TOO_LARGE"
	}
	var parsed struct {
		Data struct {
			Markdown string `json:"markdown"`
		} `json:"data"`
	}
	if err := json.Unmarshal(contents, &parsed); err != nil || parsed.Data.Markdown == "" {
		return "", "FIRECRAWL_BAD_RESPONSE"
	}
	return parsed.Data.Markdown, ""
}

func (h *AgentToolsHandler) randomTokenLocked(prefix string) (string, error) {
	bytes := make([]byte, 32)
	if _, err := io.ReadFull(h.random, bytes); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(bytes), nil
}
func (h *AgentToolsHandler) cleanupLocked(now time.Time) {
	for token, state := range h.capabilities {
		if !now.Before(state.expiresAt) {
			delete(h.capabilities, token)
		}
	}
}

func (h *AgentToolsHandler) ensureCleanupLocked() {
	if h.cleanupRunning || len(h.capabilities) == 0 {
		return
	}
	ticks, stop := h.cleanupTickerFactory(h.cleanupInterval)
	if stop == nil {
		stop = func() {}
	}
	h.cleanupRunning = true
	go h.cleanupLoop(ticks, stop)
}

func (h *AgentToolsHandler) cleanupLoop(ticks <-chan time.Time, stop func()) {
	defer stop()
	for {
		select {
		case <-h.done:
			h.mu.Lock()
			h.cleanupRunning = false
			h.mu.Unlock()
			return
		case _, ok := <-ticks:
			if !ok {
				h.mu.Lock()
				h.cleanupRunning = false
				h.mu.Unlock()
				return
			}
			h.mu.Lock()
			h.cleanupLocked(h.now())
			if len(h.capabilities) == 0 {
				h.cleanupRunning = false
				h.mu.Unlock()
				return
			}
			h.mu.Unlock()
		}
	}
}

// Close stops the single background cleanup loop. Production owns one handler
// for process lifetime; tests and short-lived embeddings should call Close.
func (h *AgentToolsHandler) Close() {
	h.closeOnce.Do(func() { close(h.done) })
}

func acquireAgentToolSlot(ctx context.Context, slots chan struct{}) bool {
	if ctx.Err() != nil {
		return false
	}
	select {
	case slots <- struct{}{}:
		return true
	case <-ctx.Done():
		return false
	default:
		return false
	}
}

func releaseAgentToolSlot(slots chan struct{}) {
	<-slots
}

func decodeAgentToolJSON(w http.ResponseWriter, r *http.Request, target interface{}) error {
	if r.Header.Get("Content-Type") != "" && !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		return errors.New("content type")
	}
	r.Body = http.MaxBytesReader(w, r.Body, agentToolsMaxRequestBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing interface{}
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

func writeAgentToolJSON(w http.ResponseWriter, status int, value interface{}) {
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) > agentToolsMaxResponseBytes {
		writeAgentToolError(w, http.StatusInternalServerError, "RESPONSE_TOO_LARGE", "response exceeded safety limit")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(encoded)
}
func writeAgentToolError(w http.ResponseWriter, status int, code, message string) {
	writeAgentToolJSON(w, status, map[string]interface{}{"error": map[string]string{"code": code, "message": message}})
}
func constantTimeEqual(value, expected string) bool {
	if len(value) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(value), []byte(expected)) == 1
}
func bearerCapability(value string) (string, bool) {
	const prefix = "Bearer "
	if !strings.HasPrefix(value, prefix) || strings.TrimSpace(strings.TrimPrefix(value, prefix)) == "" {
		return "", false
	}
	return strings.TrimSpace(strings.TrimPrefix(value, prefix)), true
}
func validAgentQuery(value string) bool {
	value = strings.TrimSpace(value)
	return value != "" && len(value) <= agentToolsMaxQueryBytes && !unsafeText(value)
}
func validSourceProviders(values []string) bool {
	if len(values) > 2 {
		return false
	}
	for _, value := range values {
		if value != "youtube" && value != "soundcloud" {
			return false
		}
	}
	return true
}

func canonicalEvidenceURL(raw string) (string, bool) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Host == "" || parsed.Port() != "" || parsed.Fragment != "" || parsed.Opaque != "" || parsed.RawPath != "" {
		return "", false
	}
	switch strings.ToLower(parsed.Hostname()) {
	case "youtube.com", "www.youtube.com", "music.youtube.com":
		if parsed.Path != "/watch" || parsed.ForceQuery {
			return "", false
		}
		query, err := url.ParseQuery(parsed.RawQuery)
		if err != nil || len(query) != 1 || len(query["v"]) != 1 || !youtubeVideoIDPattern.MatchString(query.Get("v")) {
			return "", false
		}
		return "https://www.youtube.com/watch?v=" + query.Get("v"), true
	case "youtu.be":
		if parsed.RawQuery != "" || parsed.ForceQuery || !strings.HasPrefix(parsed.Path, "/") {
			return "", false
		}
		videoID := strings.TrimPrefix(parsed.Path, "/")
		if strings.Contains(videoID, "/") || !youtubeVideoIDPattern.MatchString(videoID) {
			return "", false
		}
		return "https://www.youtube.com/watch?v=" + videoID, true
	case "soundcloud.com", "www.soundcloud.com":
		if parsed.RawQuery != "" || parsed.ForceQuery {
			return "", false
		}
		segments := strings.Split(strings.TrimPrefix(parsed.Path, "/"), "/")
		if len(segments) != 2 || !soundCloudSlugPattern.MatchString(segments[0]) || !soundCloudSlugPattern.MatchString(segments[1]) || reservedSoundCloudPath(segments[0]) {
			return "", false
		}
		return "https://soundcloud.com/" + segments[0] + "/" + segments[1], true
	}
	return "", false
}

func reservedSoundCloudPath(segment string) bool {
	switch strings.ToLower(segment) {
	case "connect", "discover", "login", "oauth", "oauth2", "redirect", "search", "settings", "stream", "you":
		return true
	default:
		return false
	}
}

func sanitizeProviderSummaries(input []ProviderSummary) []ProviderSummary {
	if len(input) > 2 {
		input = input[:2]
	}
	output := make([]ProviderSummary, 0, len(input))
	for _, summary := range input {
		provider := strings.TrimSpace(summary.Provider)
		if !safeProviderName.MatchString(provider) || unsafeText(provider) {
			provider = "unknown"
		}
		status := summary.Status
		switch status {
		case ProviderStatusOK, ProviderStatusTimeout, ProviderStatusFailed, ProviderStatusDisabled, ProviderStatusUnsupported:
		default:
			status = ProviderStatusFailed
		}
		resultCount := summary.ResultCount
		if resultCount < 0 {
			resultCount = 0
		}
		if resultCount > 25 {
			resultCount = 25
		}
		elapsedMs := summary.ElapsedMs
		if elapsedMs < 0 {
			elapsedMs = 0
		}
		if elapsedMs > 60_000 {
			elapsedMs = 60_000
		}
		clean := ProviderSummary{Provider: provider, Status: status, ResultCount: resultCount, ElapsedMs: elapsedMs}
		if summary.Error != nil {
			code := summary.Error.Code
			if !providerErrorCodePattern.MatchString(code) || unsafeText(code) {
				code = ErrProviderUnavailable
			}
			message := "provider request failed"
			if status == ProviderStatusTimeout {
				message = "provider request timed out"
			}
			clean.Error = &ProviderError{Code: code, Message: message}
		}
		output = append(output, clean)
	}
	return output
}

func sanitizeCatalogItems(input []SearchItem, kind string) []SearchItem {
	if len(input) > 8 {
		input = input[:8]
	}
	output := make([]SearchItem, 0, len(input))
	for _, item := range input {
		if item.Kind != kind || !safeOpaqueReference(item.ID) {
			continue
		}
		title := sanitizeBoundedField(item.Title, 240)
		if title == "" {
			continue
		}
		clean := SearchItem{
			Kind: item.Kind, ID: item.ID, Title: title,
			Subtitle: sanitizeBoundedField(item.Subtitle, 240), Artist: sanitizeBoundedField(item.Artist, 180),
			Album: sanitizeBoundedField(item.Album, 240), DurationMs: clampAgentToolInt(item.DurationMs, 0, 86_400_000),
			ReleaseDate: sanitizeBoundedField(item.ReleaseDate, 32), Score: clampAgentToolInt(item.Score, 0, 100),
		}
		if safeOpaqueReference(item.ArtistMBID) {
			clean.ArtistMBID = item.ArtistMBID
		}
		if safeOpaqueReference(item.AlbumMBID) {
			clean.AlbumMBID = item.AlbumMBID
		}
		output = append(output, clean)
	}
	return output
}

func safeOpaqueReference(value string) bool {
	return opaqueReferencePattern.MatchString(value) && !unsafeSecretTextPattern.MatchString(value) && !strings.Contains(value, "://")
}

func sanitizeField(value string) string {
	return sanitizeBoundedField(value, 512)
}

func sanitizeBoundedField(value string, maximum int) string {
	if unsafeText(value) {
		return ""
	}
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > maximum {
		return string(runes[:maximum])
	}
	return strings.Clone(value)
}
func sanitizeMetadata(input map[string]interface{}) map[string]string {
	if len(input) == 0 {
		return nil
	}
	output := make(map[string]string)
	for key, value := range input {
		key = sanitizeBoundedField(key, 64)
		if len(output) >= 16 || key == "" || unsafeMetadataKey(key) {
			continue
		}
		text, ok := value.(string)
		if !ok {
			continue
		}
		if text = sanitizeField(text); text != "" {
			output[key] = text
		}
	}
	if len(output) == 0 {
		return nil
	}
	return output
}

func clampAgentToolInt(value, minimum, maximum int) int {
	if value < minimum {
		return minimum
	}
	if value > maximum {
		return maximum
	}
	return value
}
func unsafeMetadataKey(key string) bool {
	key = strings.ToLower(key)
	return strings.Contains(key, "url") || strings.Contains(key, "token") || strings.Contains(key, "secret") || strings.Contains(key, "password") || strings.Contains(key, "authorization") || strings.Contains(key, "cookie")
}
func unsafeText(value string) bool {
	lower := strings.ToLower(value)
	return unsafeURLTextPattern.MatchString(value) ||
		unsafeSecretTextPattern.MatchString(value) ||
		strings.Contains(lower, "<script") ||
		strings.Contains(lower, "javascript:") ||
		strings.Contains(lower, "token=") ||
		strings.Contains(lower, "secret=") ||
		strings.Contains(lower, "client_secret") ||
		strings.Contains(lower, "password=") ||
		strings.Contains(lower, "cookie:") ||
		strings.Contains(lower, "set-cookie:")
}
func sanitizeEvidence(markdown string) string {
	lines := strings.Split(markdown, "\n")
	output := make([]byte, 0, agentToolsMaxEvidenceBytes)
	for _, line := range lines {
		if unsafeText(line) {
			continue
		}
		line = strings.TrimSpace(agentToolURLPattern.ReplaceAllString(line, ""))
		if line == "" {
			continue
		}
		if len(output) > 0 {
			if len(output) == agentToolsMaxEvidenceBytes {
				break
			}
			output = append(output, '\n')
		}
		remaining := agentToolsMaxEvidenceBytes - len(output)
		if len(line) <= remaining {
			output = append(output, line...)
			continue
		}
		line = line[:remaining]
		for line != "" && !utf8.ValidString(line) {
			line = line[:len(line)-1]
		}
		output = append(output, line...)
		break
	}
	return string(output)
}
