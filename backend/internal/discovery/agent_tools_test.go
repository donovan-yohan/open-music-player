package discovery

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

type countingJudge struct{ calls atomic.Int32 }

func (j *countingJudge) JudgeSourceQuality(context.Context, string, []SourceQualityCandidateFeature) ([]SourceQualityJudgment, error) {
	j.calls.Add(1)
	return nil, nil
}

func TestSearchSourcesReusesProviderFanoutWithoutRanking(t *testing.T) {
	judge := &countingJudge{}
	provider := &countingProvider{name: "youtube"}
	service := NewService(ServiceConfig{Providers: []Provider{provider}, DefaultProviders: []string{"youtube"}, SourceQualityJudge: judge})

	result := service.SearchSources(context.Background(), "one", []string{"youtube"}, 5)
	if provider.calls.Load() != 1 || judge.calls.Load() != 0 {
		t.Fatalf("raw fanout calls provider=%d judge=%d, want 1 and 0", provider.calls.Load(), judge.calls.Load())
	}
	if len(result.Results) != 1 || result.Results[0].Metadata[SourceQualityMetadataKey] != nil {
		t.Fatalf("raw candidate = %#v, want unranked provider output", result.Results)
	}
}

func TestAgentToolsServiceAuthStrictJSONAndDisabledFallback(t *testing.T) {
	service := agentToolsTestService()
	if NewAgentToolsHandler(AgentToolsConfig{Search: service}) != nil {
		t.Fatal("handler without service token must be disabled")
	}
	handler := newAgentToolsTestHandler(t, service, "", time.Now, 3, time.Minute)

	request := httptest.NewRequest(http.MethodPost, agentToolsPrefix+"/capabilities", strings.NewReader(`{}`))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized || toolErrorCode(t, recorder) != "SERVICE_UNAUTHORIZED" {
		t.Fatalf("unauthenticated capability response = %d %s", recorder.Code, recorder.Body.String())
	}

	request = httptest.NewRequest(http.MethodPost, agentToolsPrefix+"/capabilities", strings.NewReader(`{"extra":true}`))
	request.Header.Set("X-OMP-Agent-Service-Token", "service-token")
	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest || toolErrorCode(t, recorder) != "INVALID_JSON" {
		t.Fatalf("unknown field response = %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestAgentToolsCapabilityExpiryAndCallQuota(t *testing.T) {
	now := time.Date(2026, 7, 17, 0, 0, 0, 0, time.UTC)
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", func() time.Time { return now }, 1, time.Minute)
	capability := issueCapability(t, handler)
	callTool(t, handler, "/search-catalog", capability, `{"query":"one","kind":"track"}`, http.StatusOK)
	callTool(t, handler, "/search-catalog", capability, `{"query":"one","kind":"track"}`, http.StatusTooManyRequests)

	capability = issueCapability(t, handler)
	now = now.Add(2 * time.Minute)
	response := callTool(t, handler, "/search-catalog", capability, `{"query":"one","kind":"track"}`, http.StatusUnauthorized)
	if toolErrorCode(t, response) != "CAPABILITY_EXPIRED" {
		t.Fatalf("expired capability code = %s, want expiry rejection", toolErrorCode(t, response))
	}
}

func TestAgentToolsActiveCapabilityAndIssuanceWindowLimits(t *testing.T) {
	now := time.Date(2026, 7, 17, 0, 0, 0, 0, time.UTC)
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", func() time.Time { return now }, 12, time.Minute, func(cfg *AgentToolsConfig) {
		cfg.MaxCapabilities = 2
		cfg.CapabilityTTL = 10 * time.Minute
		cfg.IssuanceLimit = 2
		cfg.IssuanceWindow = time.Minute
	})
	issueCapability(t, handler)
	issueCapability(t, handler)
	response := issueCapabilityResponse(handler)
	if response.Code != http.StatusTooManyRequests || toolErrorCode(t, response) != "CAPABILITY_RATE_LIMIT" {
		t.Fatalf("issuance limit = %d %s", response.Code, response.Body.String())
	}

	now = now.Add(time.Minute)
	response = issueCapabilityResponse(handler)
	if response.Code != http.StatusServiceUnavailable || toolErrorCode(t, response) != "CAPABILITY_BUSY" {
		t.Fatalf("active capability limit = %d %s", response.Code, response.Body.String())
	}
}

func TestAgentToolsIssuanceWindowResets(t *testing.T) {
	now := time.Date(2026, 7, 17, 0, 0, 0, 0, time.UTC)
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", func() time.Time { return now }, 12, time.Minute, func(cfg *AgentToolsConfig) {
		cfg.MaxCapabilities = 8
		cfg.IssuanceLimit = 2
		cfg.IssuanceWindow = time.Minute
	})
	issueCapability(t, handler)
	issueCapability(t, handler)
	if response := issueCapabilityResponse(handler); response.Code != http.StatusTooManyRequests {
		t.Fatalf("window quota = %d, want %d", response.Code, http.StatusTooManyRequests)
	}
	now = now.Add(time.Minute)
	if response := issueCapabilityResponse(handler); response.Code != http.StatusOK {
		t.Fatalf("reset issuance = %d %s", response.Code, response.Body.String())
	}
}

func TestAgentToolsCandidateEvidenceAndRetainedByteQuotasAreAtomic(t *testing.T) {
	candidate := agentToolsTestCandidate()
	service := NewService(ServiceConfig{Providers: []Provider{fakeProvider{name: "youtube", items: []Candidate{candidate}}}, DefaultProviders: []string{"youtube"}})
	model := sanitizeCandidateForStorage("candidate_"+strings.Repeat("x", 43), candidate)
	model.EvidenceRefs = []string{"evidence_" + strings.Repeat("x", 43)}
	canonicalURL, ok := canonicalEvidenceURL(candidate.SourceURL)
	if !ok {
		t.Fatal("test source URL was not canonical")
	}
	entryBytes := retainedCandidateBytes(model, canonicalURL)

	t.Run("candidate", func(t *testing.T) {
		handler := newAgentToolsTestHandler(t, service, "", time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) {
			cfg.CandidateLimit = 1
			cfg.EvidenceLimit = 2
			cfg.RetainedByteLimit = entryBytes * 2
		})
		capability := issueCapability(t, handler)
		issuedEvidenceRef(t, handler, capability)
		response := callTool(t, handler, "/search-sources", capability, `{"query":"one"}`, http.StatusTooManyRequests)
		if toolErrorCode(t, response) != "CAPABILITY_RESOURCE_LIMIT" {
			t.Fatalf("candidate quota code = %s", toolErrorCode(t, response))
		}
	})

	t.Run("evidence", func(t *testing.T) {
		handler := newAgentToolsTestHandler(t, service, "", time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) {
			cfg.CandidateLimit = 2
			cfg.EvidenceLimit = 1
			cfg.RetainedByteLimit = entryBytes * 2
		})
		capability := issueCapability(t, handler)
		issuedEvidenceRef(t, handler, capability)
		response := callTool(t, handler, "/search-sources", capability, `{"query":"one"}`, http.StatusTooManyRequests)
		if toolErrorCode(t, response) != "CAPABILITY_RESOURCE_LIMIT" {
			t.Fatalf("evidence quota code = %s", toolErrorCode(t, response))
		}
	})

	t.Run("retained bytes and sanitized copy", func(t *testing.T) {
		huge := candidate
		huge.Title = strings.Repeat("title", 10_000)
		huge.Artist = strings.Repeat("artist", 10_000)
		huge.Uploader = strings.Repeat("uploader", 10_000)
		huge.SourceURL = "https://youtu.be/dQw4w9WgXcQ"
		huge.ThumbnailURL = "https://images.example/" + strings.Repeat("x", 100_000)
		huge.Metadata = map[string]interface{}{
			"album":     strings.Repeat("album", 10_000),
			"sourceUrl": "https://private.example/" + strings.Repeat("x", 100_000),
			"nested":    map[string]interface{}{"unbounded": strings.Repeat("x", 100_000)},
		}
		explicit := true
		huge.Explicit = &explicit
		huge.DurationMs = 999_999_999
		hugeService := NewService(ServiceConfig{Providers: []Provider{fakeProvider{name: "youtube", items: []Candidate{huge}}}, DefaultProviders: []string{"youtube"}})
		bounded := sanitizeCandidateForStorage("candidate_"+strings.Repeat("x", 43), huge)
		bounded.EvidenceRefs = []string{"evidence_" + strings.Repeat("x", 43)}
		limit := retainedCandidateBytes(bounded, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
		handler := newAgentToolsTestHandler(t, hugeService, "", time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) {
			cfg.CandidateLimit = 2
			cfg.EvidenceLimit = 2
			cfg.RetainedByteLimit = limit
		})
		capability := issueCapability(t, handler)
		issuedEvidenceRef(t, handler, capability)

		handler.mu.Lock()
		state := handler.capabilities[capability]
		if len(state.candidates) != 1 || len(state.evidence) != 1 || state.retainedBytes != limit {
			handler.mu.Unlock()
			t.Fatalf("retained state = candidates:%d evidence:%d bytes:%d", len(state.candidates), len(state.evidence), state.retainedBytes)
		}
		var stored agentSourceCandidate
		for _, entry := range state.candidates {
			stored = cloneAgentSourceCandidate(entry.candidate)
		}
		handler.mu.Unlock()
		if len(stored.Title) > 240 || len(stored.Artist) > 180 || len(stored.Uploader) > 180 || stored.DurationMs != 86_400_000 || stored.Explicit == nil || !*stored.Explicit {
			t.Fatalf("stored candidate was not bounded: %#v", stored)
		}
		if len(stored.Metadata) != 1 || len(stored.Metadata["album"]) > 512 {
			t.Fatalf("stored metadata was not sanitized: %#v", stored.Metadata)
		}
		*huge.Explicit = false
		huge.Metadata["album"] = "changed after search"
		if !*stored.Explicit || stored.Metadata["album"] == "changed after search" {
			t.Fatal("stored candidate retained provider-owned mutable data")
		}

		response := callTool(t, handler, "/search-sources", capability, `{"query":"one"}`, http.StatusTooManyRequests)
		if toolErrorCode(t, response) != "CAPABILITY_RESOURCE_LIMIT" {
			t.Fatalf("retained byte quota code = %s", toolErrorCode(t, response))
		}
		handler.mu.Lock()
		defer handler.mu.Unlock()
		if state.retainedBytes != limit || len(state.candidates) != 1 || len(state.evidence) != 1 {
			t.Fatalf("rejected batch mutated retained state: %#v", state)
		}
	})
}

func TestAgentToolsProviderAndFirecrawlSemaphoreContention(t *testing.T) {
	t.Run("provider", func(t *testing.T) {
		started := make(chan struct{})
		release := make(chan struct{})
		service := NewService(ServiceConfig{Providers: []Provider{blockingProvider{name: "youtube", started: started, release: release, items: []Candidate{agentToolsTestCandidate()}}}, DefaultProviders: []string{"youtube"}})
		handler := newAgentToolsTestHandler(t, service, "", time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) { cfg.ProviderConcurrency = 1 })
		capability := issueCapability(t, handler)
		result := make(chan *httptest.ResponseRecorder, 1)
		go func() { result <- agentToolRequest(handler, "/search-sources", capability, `{"query":"one"}`) }()
		<-started
		response := callTool(t, handler, "/search-sources", issueCapability(t, handler), `{"query":"one"}`, http.StatusServiceUnavailable)
		if toolErrorCode(t, response) != "PROVIDER_BUSY" {
			t.Fatalf("provider contention code = %s", toolErrorCode(t, response))
		}
		close(release)
		if response := <-result; response.Code != http.StatusOK {
			t.Fatalf("blocked provider request = %d %s", response.Code, response.Body.String())
		}
	})

	t.Run("firecrawl", func(t *testing.T) {
		started := make(chan struct{})
		release := make(chan struct{})
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			select {
			case started <- struct{}{}:
			default:
			}
			<-release
			_, _ = w.Write([]byte(`{"data":{"markdown":"safe evidence"}}`))
		}))
		defer server.Close()
		handler := newAgentToolsTestHandler(t, agentToolsTestService(), server.URL, time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) { cfg.FirecrawlConcurrency = 1 })
		handler.firecrawlAPIKey = "firecrawl-key"
		capability := issueCapability(t, handler)
		ref := issuedEvidenceRef(t, handler, capability)
		result := make(chan *httptest.ResponseRecorder, 1)
		go func() { result <- agentToolRequest(handler, "/extract-web", capability, `{"evidenceRef":"`+ref+`"}`) }()
		<-started
		response := callTool(t, handler, "/extract-web", capability, `{"evidenceRef":"`+ref+`"}`, http.StatusServiceUnavailable)
		if toolErrorCode(t, response) != "FIRECRAWL_BUSY" {
			t.Fatalf("Firecrawl contention code = %s", toolErrorCode(t, response))
		}
		close(release)
		if response := <-result; response.Code != http.StatusOK {
			t.Fatalf("blocked Firecrawl request = %d %s", response.Code, response.Body.String())
		}
	})
}

func TestAgentToolsBackgroundCleanupAndClose(t *testing.T) {
	now := time.Date(2026, 7, 17, 0, 0, 0, 0, time.UTC)
	ticks := make(chan time.Time, 1)
	stopped := make(chan struct{})
	var stopOnce sync.Once
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", func() time.Time { return now }, 12, time.Minute, func(cfg *AgentToolsConfig) {
		cfg.CapabilityTTL = time.Second
		cfg.CleanupTickerFactory = func(time.Duration) (<-chan time.Time, func()) {
			return ticks, func() { stopOnce.Do(func() { close(stopped) }) }
		}
	})
	capability := issueCapability(t, handler)
	now = now.Add(2 * time.Second)
	ticks <- now
	deadline := time.After(time.Second)
	for {
		handler.mu.Lock()
		_, active := handler.capabilities[capability]
		running := handler.cleanupRunning
		handler.mu.Unlock()
		if !active && !running {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("cleanup did not evict expired capability (active=%t running=%t)", active, running)
		case <-time.After(time.Millisecond):
		}
	}
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("cleanup ticker was not stopped")
	}
	handler.Close()
}

func TestAgentToolsCloseStopsActiveCleanup(t *testing.T) {
	ticks := make(chan time.Time)
	stopped := make(chan struct{})
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", time.Now, 12, time.Minute, func(cfg *AgentToolsConfig) {
		cfg.CleanupTickerFactory = func(time.Duration) (<-chan time.Time, func()) {
			return ticks, func() { close(stopped) }
		}
	})
	issueCapability(t, handler)

	handler.mu.Lock()
	running := handler.cleanupRunning
	handler.mu.Unlock()
	if !running {
		t.Fatal("cleanup ticker was not active before Close")
	}
	handler.Close()

	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("cleanup ticker was not stopped by Close")
	}
	handler.mu.Lock()
	running = handler.cleanupRunning
	handler.mu.Unlock()
	if running {
		t.Fatal("cleanup remained running after Close")
	}
}

func TestSanitizeEvidenceByteBoundariesAndUTF8(t *testing.T) {
	if got := sanitizeEvidence(strings.Repeat("x", agentToolsMaxEvidenceBytes)); len(got) != agentToolsMaxEvidenceBytes || !utf8.ValidString(got) {
		t.Fatalf("exact bound = %d valid=%t", len(got), utf8.ValidString(got))
	}
	if got := sanitizeEvidence(strings.Repeat("x", agentToolsMaxEvidenceBytes+1)); len(got) != agentToolsMaxEvidenceBytes || !utf8.ValidString(got) {
		t.Fatalf("over bound = %d valid=%t", len(got), utf8.ValidString(got))
	}
	if got := sanitizeEvidence(strings.Repeat("界", agentToolsMaxEvidenceBytes)); len(got) > agentToolsMaxEvidenceBytes || !utf8.ValidString(got) {
		t.Fatalf("multibyte bound = %d valid=%t", len(got), utf8.ValidString(got))
	}
}

func TestSanitizeMetadataKeysUsePythonLimit(t *testing.T) {
	if got := sanitizeMetadata(map[string]interface{}{strings.Repeat("k", 65): "value"}); got[strings.Repeat("k", 64)] != "value" {
		t.Fatalf("metadata key was not bounded to 64 characters: %#v", got)
	}
}

func TestAgentToolsLiveFirecrawlSmoke(t *testing.T) {
	apiKey := strings.TrimSpace(os.Getenv("FIRECRAWL_API_KEY"))
	if apiKey == "" {
		t.Skip("FIRECRAWL_API_KEY is not configured")
	}
	handler := NewAgentToolsHandler(AgentToolsConfig{ServiceToken: "service-token", FirecrawlAPIKey: apiKey, Search: agentToolsTestService()})
	defer handler.Close()
	markdown, code := handler.firecrawl(context.Background(), "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
	if code != "" {
		t.Fatalf("live Firecrawl smoke failed with %s", code)
	}
	if got := sanitizeEvidence(markdown); got == "" || len(got) > agentToolsMaxEvidenceBytes || !utf8.ValidString(got) {
		t.Fatalf("live Firecrawl returned unusable sanitized evidence: bytes=%d valid=%t", len(got), utf8.ValidString(got))
	}
}

func TestAgentToolsCandidateAndEvidenceAreCapabilityBoundAndNeverLeakURLs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer firecrawl-key" {
			t.Fatal("Firecrawl API key missing")
		}
		var body map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["url"] != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" || body["onlyMainContent"] != true {
			t.Fatalf("unexpected Firecrawl request: %#v", body)
		}
		formats, ok := body["formats"].([]interface{})
		if !ok || len(formats) != 1 || formats[0] != "markdown" {
			t.Fatalf("unexpected Firecrawl formats: %#v", body)
		}
		_, _ = w.Write([]byte(`{"data":{"markdown":"Good evidence\nhttps://secret.example/x\n<script>x</script>\nAuthorization: Bearer secret"}}`))
	}))
	defer server.Close()
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), server.URL, time.Now, 12, time.Minute)
	handler.firecrawlAPIKey = "firecrawl-key"
	capability := issueCapability(t, handler)
	response := callTool(t, handler, "/search-sources", capability, `{"query":"one","providers":["youtube"]}`, http.StatusOK)
	if strings.Contains(response.Body.String(), "youtube.com") || strings.Contains(response.Body.String(), "thumbnailUrl") || strings.Contains(response.Body.String(), "sourceUrl") {
		t.Fatalf("source search leaked a URL: %s", response.Body.String())
	}
	var payload struct {
		Candidates []struct {
			CandidateID  string   `json:"candidateId"`
			EvidenceRefs []string `json:"evidenceRefs"`
		} `json:"candidates"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Candidates) != 1 || len(payload.Candidates[0].EvidenceRefs) != 1 {
		t.Fatalf("candidate refs = %#v", payload)
	}
	candidateID, evidenceRef := payload.Candidates[0].CandidateID, payload.Candidates[0].EvidenceRefs[0]

	callTool(t, handler, "/inspect-source-metadata", issueCapability(t, handler), `{"candidateId":"`+candidateID+`"}`, http.StatusNotFound)
	inspect := callTool(t, handler, "/inspect-source-metadata", capability, `{"candidateId":"`+candidateID+`"}`, http.StatusOK)
	if strings.Contains(inspect.Body.String(), "youtube.com") || strings.Contains(inspect.Body.String(), "https://") {
		t.Fatalf("inspect leaked URL: %s", inspect.Body.String())
	}
	callTool(t, handler, "/extract-web", issueCapability(t, handler), `{"evidenceRef":"`+evidenceRef+`"}`, http.StatusNotFound)
	extract := callTool(t, handler, "/extract-web", capability, `{"evidenceRef":"`+evidenceRef+`"}`, http.StatusOK)
	if got := extract.Body.String(); strings.Contains(got, "https://") || strings.Contains(strings.ToLower(got), "script") || strings.Contains(strings.ToLower(got), "bearer") {
		t.Fatalf("unsafe markdown returned: %s", got)
	}
}

func TestAgentToolsCatalogKindAndCanonicalEvidenceURLs(t *testing.T) {
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", time.Now, 12, time.Minute)
	capability := issueCapability(t, handler)
	callTool(t, handler, "/search-catalog", capability, `{"query":"one","kind":"release"}`, http.StatusBadRequest)
	accepted := map[string]string{
		"https://youtube.com/watch?v=dQw4w9WgXcQ":           "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://music.youtube.com/watch?v=dQw4w9WgXcQ":     "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://youtu.be/dQw4w9WgXcQ":                      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://www.soundcloud.com/artist-name/track_name": "https://soundcloud.com/artist-name/track_name",
	}
	for raw, want := range accepted {
		if got, ok := canonicalEvidenceURL(raw); !ok || got != want {
			t.Fatalf("canonicalEvidenceURL(%q) = %q, %t; want %q, true", raw, got, ok, want)
		}
	}
	for _, raw := range []string{
		"http://www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ",
		"https://www.youtube.com/redirect?q=http%3A%2F%2F127.0.0.1%2Fadmin",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ&next=http%3A%2F%2F10.0.0.1",
		"https://www.youtube.com/watch?v=http%3A%2F%2F127.0.0.1",
		"https://youtu.be/dQw4w9WgXcQ/extra",
		"https://youtu.be/dQw4w9WgXcQ?next=https%3A%2F%2Fexample.test",
		"https://user@youtu.be/dQw4w9WgXcQ",
		"https://soundcloud.com/redirect/target",
		"https://soundcloud.com/artist/track?url=http%3A%2F%2F192.168.1.1",
		"https://soundcloud.com/artist/track#fragment",
	} {
		if canonical, ok := canonicalEvidenceURL(raw); ok {
			t.Fatalf("unsafe host accepted: %s", raw)
		} else if canonical != "" {
			t.Fatalf("rejected URL returned canonical value: %q", canonical)
		}
	}
}

func TestAgentToolsFirecrawlTypedFailures(t *testing.T) {
	cases := []struct {
		name    string
		handler http.HandlerFunc
		timeout time.Duration
		want    string
	}{
		{"redirect", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/other", http.StatusFound) }, time.Second, "FIRECRAWL_REDIRECT"},
		{"rate-limit", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusTooManyRequests) }, time.Second, "FIRECRAWL_RATE_LIMIT"},
		{"bad-json", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("not json")) }, time.Second, "FIRECRAWL_BAD_RESPONSE"},
		{"oversize", func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(`{"data":{"markdown":"` + strings.Repeat("x", agentToolsMaxResponseBytes+1) + `"}}`))
		}, time.Second, "FIRECRAWL_RESPONSE_TOO_LARGE"},
		{"timeout", func(w http.ResponseWriter, r *http.Request) { time.Sleep(50 * time.Millisecond) }, 5 * time.Millisecond, "FIRECRAWL_TIMEOUT"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(test.handler)
			defer server.Close()
			handler := newAgentToolsTestHandler(t, agentToolsTestService(), server.URL, time.Now, 12, test.timeout)
			handler.firecrawlAPIKey = "firecrawl-key"
			capability := issueCapability(t, handler)
			ref := issuedEvidenceRef(t, handler, capability)
			status := http.StatusBadGateway
			if test.want == "FIRECRAWL_RATE_LIMIT" {
				status = http.StatusTooManyRequests
			}
			response := callTool(t, handler, "/extract-web", capability, `{"evidenceRef":"`+ref+`"}`, status)
			if code := toolErrorCode(t, response); code != test.want {
				t.Fatalf("error code = %q, want %q", code, test.want)
			}
		})
	}
}

func TestAgentToolsMissingFirecrawlDoesNotAffectSources(t *testing.T) {
	handler := newAgentToolsTestHandler(t, agentToolsTestService(), "", time.Now, 12, time.Minute)
	capability := issueCapability(t, handler)
	if response := callTool(t, handler, "/search-sources", capability, `{"query":"one"}`, http.StatusOK); len(response.Body.Bytes()) == 0 {
		t.Fatal("source search unexpectedly changed by Firecrawl config")
	}
	ref := issuedEvidenceRef(t, handler, capability)
	response := callTool(t, handler, "/extract-web", capability, `{"evidenceRef":"`+ref+`"}`, http.StatusServiceUnavailable)
	if toolErrorCode(t, response) != "FIRECRAWL_DISABLED" {
		t.Fatalf("disabled code = %s", toolErrorCode(t, response))
	}
}

func agentToolsTestService() *Service {
	return NewService(ServiceConfig{Providers: []Provider{fakeProvider{name: "youtube", items: []Candidate{agentToolsTestCandidate()}}}, DefaultProviders: []string{"youtube"}, MusicCatalog: fakeMusicCatalog{}})
}

func agentToolsTestCandidate() Candidate {
	return Candidate{CandidateID: "real-provider-id", Provider: "youtube", SourceURL: "https://youtu.be/dQw4w9WgXcQ", ThumbnailURL: "https://images.example/abc", Title: "One", Artist: "Artist", Downloadable: true, Metadata: map[string]interface{}{"album": "Album", "secret": "nope", "link": "https://bad.example"}}
}

type blockingProvider struct {
	name    string
	started chan<- struct{}
	release <-chan struct{}
	items   []Candidate
}

func (p blockingProvider) Name() string { return p.name }

func (p blockingProvider) Search(context.Context, string, int) ([]Candidate, error) {
	select {
	case p.started <- struct{}{}:
	default:
	}
	<-p.release
	return p.items, nil
}
func newAgentToolsTestHandler(t *testing.T, service *Service, firecrawlURL string, now func() time.Time, calls int, timeout time.Duration, configure ...func(*AgentToolsConfig)) *AgentToolsHandler {
	t.Helper()
	cfg := AgentToolsConfig{ServiceToken: "service-token", Search: service, Clock: now, CapabilityCalls: calls, CapabilityTTL: time.Minute, FirecrawlURL: firecrawlURL, FirecrawlTimeout: timeout, CleanupInterval: time.Hour}
	for _, apply := range configure {
		apply(&cfg)
	}
	handler := NewAgentToolsHandler(cfg)
	t.Cleanup(handler.Close)
	return handler
}
func issueCapability(t *testing.T, handler *AgentToolsHandler) string {
	t.Helper()
	response := issueCapabilityResponse(handler)
	if response.Code != http.StatusOK {
		t.Fatalf("issue capability = %d %s", response.Code, response.Body.String())
	}
	var payload struct {
		Capability string `json:"capability"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(payload.Capability, "cap_") {
		t.Fatalf("capability not opaque: %q", payload.Capability)
	}
	return payload.Capability
}

func issueCapabilityResponse(handler *AgentToolsHandler) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, agentToolsPrefix+"/capabilities", bytes.NewBufferString(`{}`))
	request.Header.Set("X-OMP-Agent-Service-Token", "service-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func agentToolRequest(handler *AgentToolsHandler, path, capability, body string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, agentToolsPrefix+path, strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+capability)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
func callTool(t *testing.T, handler *AgentToolsHandler, path, capability, body string, wantStatus int) *httptest.ResponseRecorder {
	t.Helper()
	response := agentToolRequest(handler, path, capability, body)
	if response.Code != wantStatus {
		t.Fatalf("POST %s = %d %s, want %d", path, response.Code, response.Body.String(), wantStatus)
	}
	return response
}
func toolErrorCode(t *testing.T, response *httptest.ResponseRecorder) string {
	t.Helper()
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	return payload.Error.Code
}
func issuedEvidenceRef(t *testing.T, handler *AgentToolsHandler, capability string) string {
	t.Helper()
	response := callTool(t, handler, "/search-sources", capability, `{"query":"one"}`, http.StatusOK)
	var payload struct {
		Candidates []struct {
			EvidenceRefs []string `json:"evidenceRefs"`
		} `json:"candidates"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Candidates) != 1 || len(payload.Candidates[0].EvidenceRefs) != 1 {
		t.Fatalf("evidence refs = %#v", payload)
	}
	return payload.Candidates[0].EvidenceRefs[0]
}
