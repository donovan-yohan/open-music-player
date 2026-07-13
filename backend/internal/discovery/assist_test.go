package discovery

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/aiassist"
	"github.com/openmusicplayer/backend/internal/auth"
)

// fakeAssistClient is a deterministic stand-in for the OpenAI-compatible model.
// It records call count and the prompt it received so tests can prove the model
// was (or was not) consulted.
type fakeAssistClient struct {
	intent     *aiassist.Intent
	err        error
	calls      atomic.Int32
	lastPrompt string
}

func (c *fakeAssistClient) ExtractIntent(ctx context.Context, prompt string) (*aiassist.Intent, error) {
	c.calls.Add(1)
	c.lastPrompt = prompt
	if c.err != nil {
		return nil, c.err
	}
	if c.intent == nil {
		return nil, nil
	}
	clone := *c.intent
	return &clone, nil
}

// hallucinatedURL is a model-only "playable" URL that must NEVER appear in any
// assist response. It is not in any user prompt and not produced by any provider.
const hallucinatedURL = "https://ai-generated.example/track/fake-stream.mp3"

func newAssistService(client aiassist.Client, providers ...Provider) *AssistService {
	names := make([]string, 0, len(providers))
	for _, p := range providers {
		names = append(names, p.Name())
	}
	svc := NewService(ServiceConfig{Providers: providers, DefaultProviders: names})
	return NewAssistService(AssistConfig{Client: client, Search: svc})
}

func mustMarshal(t *testing.T, v interface{}) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

func TestAssistDirectURLFromPromptResolvesWithoutModel(t *testing.T) {
	client := &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch}}
	svc := newAssistService(client)

	resp := svc.Assist(context.Background(), "please grab https://www.youtube.com/watch?v=dQw4w9WgXcQ for me", 0)

	if calls := client.calls.Load(); calls != 0 {
		t.Fatalf("model called %d times for a prompt with a usable URL; the direct path must not consult the model", calls)
	}
	if resp.Status != AssistStatusOK || resp.Intent == nil || resp.Intent.Kind != aiassist.KindDirectURL {
		t.Fatalf("unexpected envelope: %#v", resp)
	}
	if len(resp.Candidates) != 1 || resp.Candidates[0].Provider != "youtube" || resp.Candidates[0].SourceID != "dQw4w9WgXcQ" {
		t.Fatalf("candidate not resolved from prompt URL: %#v", resp.Candidates)
	}
	if resp.Candidates[0].Playable {
		t.Fatalf("direct-url candidate must not be playable until downloaded")
	}
	if len(resp.SuggestedActions) != 1 || resp.SuggestedActions[0].Kind != "queue" {
		t.Fatalf("expected a single non-destructive queue action: %#v", resp.SuggestedActions)
	}
}

func TestAssistNilModelIntentReturnsBadResponse(t *testing.T) {
	svc := newAssistService(&fakeAssistClient{}, fakeProvider{name: "youtube"})

	resp := svc.Assist(context.Background(), "find shelter live", 0)

	if resp.Status != AssistStatusError {
		t.Fatalf("status = %q, want error", resp.Status)
	}
	if resp.Error == nil || resp.Error.Code != aiassist.CodeBadResponse {
		t.Fatalf("error envelope = %#v, want bad response", resp.Error)
	}
	if len(resp.Candidates) != 0 {
		t.Fatalf("nil model intent must not produce candidates: %#v", resp.Candidates)
	}
}

// TestAssistModelSuggestedURLIsNeverACandidate is the core #75 boundary test: a
// model that claims a direct URL (and emits a fabricated playable URL) must not
// produce a candidate from that URL. With no usable URL in the prompt, the model
// claim degrades to a grounded search whose only candidate comes from a provider.
func TestAssistModelSuggestedURLIsNeverACandidate(t *testing.T) {
	provider := fakeProvider{name: "youtube", items: []Candidate{{
		CandidateID: "youtube:real", Provider: "youtube", SourceID: "real",
		SourceURL: "https://www.youtube.com/watch?v=real0000000", Title: "Grounded result", Downloadable: true,
	}}}
	client := &fakeAssistClient{intent: &aiassist.Intent{
		Kind:        aiassist.KindDirectURL,
		DetectedURL: hallucinatedURL,
		SearchQuery: "shelter live",
		Caveats:     []string{"link " + hallucinatedURL},
	}}
	svc := newAssistService(client, provider)

	resp := svc.Assist(context.Background(), "find that shelter live cut", 0)

	body := mustMarshal(t, resp)
	if strings.Contains(body, "ai-generated.example") {
		t.Fatalf("model-suggested URL leaked into the response: %s", body)
	}
	// The only candidate is the provider's grounded result.
	if resp.Search == nil || len(resp.Search.Results) != 1 || resp.Search.Results[0].SourceURL != "https://www.youtube.com/watch?v=real0000000" {
		t.Fatalf("expected exactly one grounded provider candidate, got: %#v", resp.Search)
	}
	for _, c := range resp.Candidates {
		if strings.Contains(c.SourceURL, "ai-generated.example") {
			t.Fatalf("model URL became a candidate: %#v", c)
		}
	}
}

// TestAssistModelURLNeverLeaksInAnyForm hardens the #75 boundary against URL
// scrubbing bypasses: a fabricated URL is glued to model free text by every
// punctuation/markup form (and placed in the providers array) and must not
// survive into any field of the marshaled response. Each case fails against a
// naive whitespace-token scrubber and passes only with whole-string stripping
// plus provider allow-listing.
func TestAssistModelURLNeverLeaksInAnyForm(t *testing.T) {
	const host = "ai-generated.example"
	u := hallucinatedURL // https://ai-generated.example/track/fake-stream.mp3
	cases := []struct {
		name   string
		intent *aiassist.Intent
	}{
		{"assistantText glued by colon", &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "Listen here:" + u + " now", SearchQuery: "shelter"}},
		{"assistantText glued to word", &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "click" + u, SearchQuery: "shelter"}},
		{"markdown link in assistantText", &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "[tap](" + u + ")", SearchQuery: "shelter"}},
		{"html anchor in caveat", &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "shelter", Caveats: []string{`see <a href="` + u + `">here</a>`}}},
		{"comma-flanked in caveat", &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "shelter", Caveats: []string{"word," + u + ",word"}}},
		{"url inside searchQuery", &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "shelter,[" + u + "]"}},
		{"url in providers array", &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "shelter", Providers: []string{u, "youtube"}}},
		{"url in clarify options", &aiassist.Intent{Kind: aiassist.KindClarify, Clarification: &aiassist.Clarification{Question: "which one " + u + "?", Options: []string{"opt:" + u}}}},
		{"url in unsupported text", &aiassist.Intent{Kind: aiassist.KindUnsupported, AssistantText: "can't help, but try " + u}},
		{"url in direct_url detected hint", &aiassist.Intent{Kind: aiassist.KindDirectURL, DetectedURL: u, SearchQuery: "shelter"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			provider := fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=real0000000", Title: "Grounded", Downloadable: true}}}
			svc := newAssistService(&fakeAssistClient{intent: tc.intent}, provider)

			resp := svc.Assist(context.Background(), "find that shelter live cut", 0)

			if body := mustMarshal(t, resp); strings.Contains(body, host) {
				t.Fatalf("fabricated URL host leaked into response for %q: %s", tc.name, body)
			}
		})
	}
}

// TestAssistSanitizeProvidersDropsInjectedProviders proves a model-injected
// provider string never reaches the discovery search or the echoed intent.
func TestAssistSanitizeProvidersDropsInjectedProviders(t *testing.T) {
	counting := &countingProvider{name: "youtube"}
	client := &fakeAssistClient{intent: &aiassist.Intent{
		Kind:        aiassist.KindSearch,
		SearchQuery: "shelter live",
		Providers:   []string{"https://ai-generated.example/fake.mp3", "youtube", "drop this one"},
	}}
	svc := NewAssistService(AssistConfig{Client: client, Search: NewService(ServiceConfig{Providers: []Provider{counting}, DefaultProviders: []string{"youtube"}})})

	resp := svc.Assist(context.Background(), "messy", 0)

	if resp.Intent == nil || len(resp.Intent.Providers) != 1 || resp.Intent.Providers[0] != "youtube" {
		t.Fatalf("injected providers not dropped to allow-list: %#v", resp.Intent)
	}
	// Only the allow-listed youtube provider should have been queried; the
	// injected URL/free-text providers must not appear as provider summaries.
	for _, p := range resp.Search.Providers {
		if strings.Contains(p.Provider, "ai-generated.example") || p.Provider == "drop this one" {
			t.Fatalf("injected provider reached discovery: %#v", p)
		}
	}
}

// TestAssistGroundsPunctuationWrappedUserURL proves the inverse of the scrub fix:
// a user-pasted URL wrapped in punctuation is still grounded via the resolver.
func TestAssistGroundsPunctuationWrappedUserURL(t *testing.T) {
	client := &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch}}
	svc := newAssistService(client)

	resp := svc.Assist(context.Background(), "is this it? (https://www.youtube.com/watch?v=dQw4w9WgXcQ)", 0)

	if client.calls.Load() != 0 {
		t.Fatalf("punctuation-wrapped user URL should ground locally, not call the model (calls=%d)", client.calls.Load())
	}
	if len(resp.Candidates) != 1 || resp.Candidates[0].SourceID != "dQw4w9WgXcQ" {
		t.Fatalf("punctuation-wrapped user URL not resolved: %#v", resp.Candidates)
	}
}

// TestAssistSearchQueryURLDoesNotLeakIntoCandidates proves a URL embedded in the
// model's search query never becomes a candidate URL: candidates come only from
// the provider results, not from the query text.
func TestAssistSearchQueryURLDoesNotLeakIntoCandidates(t *testing.T) {
	counting := &countingProvider{name: "youtube"}
	client := &fakeAssistClient{intent: &aiassist.Intent{
		Kind:        aiassist.KindSearch,
		SearchQuery: "play " + hallucinatedURL + " now",
		Providers:   []string{"youtube"},
	}}
	svc := NewAssistService(AssistConfig{Client: client, Search: NewService(ServiceConfig{Providers: []Provider{counting}, DefaultProviders: []string{"youtube"}})})

	resp := svc.Assist(context.Background(), "messy request", 0)

	if counting.calls.Load() != 1 {
		t.Fatalf("discovery provider should have been called once, got %d", counting.calls.Load())
	}
	if resp.Search == nil || len(resp.Search.Results) != 1 {
		t.Fatalf("expected one grounded result: %#v", resp.Search)
	}
	if got := resp.Search.Results[0].SourceURL; strings.Contains(got, "ai-generated.example") {
		t.Fatalf("candidate sourceUrl came from model query text: %q", got)
	}
}

func TestAssistSearchGroundsAgainstDiscoveryAndShowsProvenance(t *testing.T) {
	provider := fakeProvider{name: "youtube", items: []Candidate{{
		CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=abc00000000", Title: "Shelter (Live)", Downloadable: true,
	}}}
	client := &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "Here are matches", SearchQuery: "Porter Robinson Shelter live", Providers: []string{"youtube"}}}
	svc := newAssistService(client, provider)

	resp := svc.Assist(context.Background(), "that live porter robinson shelter from youtube", 0)

	if resp.Status != AssistStatusOK {
		t.Fatalf("status = %q, want ok", resp.Status)
	}
	if resp.Intent == nil || resp.Intent.SearchQuery != "Porter Robinson Shelter live" {
		t.Fatalf("intent echo missing grounded query: %#v", resp.Intent)
	}
	if resp.Search == nil || len(resp.Search.Providers) == 0 {
		t.Fatalf("response missing provider provenance: %#v", resp.Search)
	}
	if len(resp.Search.Results) != 1 || resp.Search.Results[0].Title != "Shelter (Live)" {
		t.Fatalf("grounded result missing: %#v", resp.Search)
	}
}

func TestAssistProviderFailureIsVisibleAndIsolated(t *testing.T) {
	provider := fakeProvider{name: "youtube", err: context.DeadlineExceeded}
	client := &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "anything"}}
	svc := newAssistService(client, provider)

	resp := svc.Assist(context.Background(), "find something", 0)

	if resp.Status != AssistStatusOK {
		t.Fatalf("a provider failure must not fail the whole assist; status = %q", resp.Status)
	}
	if resp.Search == nil || len(resp.Search.Providers) != 1 || resp.Search.Providers[0].Status == ProviderStatusOK {
		t.Fatalf("provider failure not visible in metadata: %#v", resp.Search)
	}
	var sawCaveat bool
	for _, c := range resp.Caveats {
		if strings.Contains(c, "youtube") {
			sawCaveat = true
		}
	}
	if !sawCaveat {
		t.Fatalf("degraded provider not surfaced as a caveat: %#v", resp.Caveats)
	}
}

func TestAssistClarificationPassesThrough(t *testing.T) {
	client := &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindClarify, AssistantText: "Need more", Clarification: &aiassist.Clarification{Question: "Which artist?", Options: []string{"Porter Robinson"}}}}
	svc := newAssistService(client)

	resp := svc.Assist(context.Background(), "shelter", 0)

	if resp.Status != AssistStatusClarification {
		t.Fatalf("status = %q, want clarification", resp.Status)
	}
	if resp.Clarification == nil || resp.Clarification.Question != "Which artist?" {
		t.Fatalf("clarification not passed through: %#v", resp.Clarification)
	}
	if resp.Search != nil {
		t.Fatalf("clarification must not run discovery search")
	}
}

func TestAssistModelErrorMapsToErrorEnvelope(t *testing.T) {
	client := &fakeAssistClient{err: &aiassist.Error{Code: aiassist.CodeTimeout, Message: "ai assist request timed out"}}
	svc := newAssistService(client)

	resp := svc.Assist(context.Background(), "anything", 0)

	if resp.Status != AssistStatusError {
		t.Fatalf("status = %q, want error", resp.Status)
	}
	if resp.Error == nil || resp.Error.Code != aiassist.CodeTimeout {
		t.Fatalf("error envelope = %#v, want timeout code", resp.Error)
	}
	if resp.AssistantText == "" {
		t.Fatalf("error envelope should still carry a user-facing fallback message")
	}
}

func TestAssistDisabledClientReturnsDisabledEnvelope(t *testing.T) {
	svc := NewAssistService(AssistConfig{Client: nil, Search: NewService(ServiceConfig{})})

	resp := svc.Assist(context.Background(), "find me a song", 0)

	if resp.Status != AssistStatusDisabled {
		t.Fatalf("status = %q, want disabled", resp.Status)
	}
	if resp.Error == nil || resp.Error.Code != aiassist.CodeDisabled {
		t.Fatalf("disabled envelope = %#v, want AI_DISABLED", resp.Error)
	}
}

func TestAssistDisabledClientStillResolvesPromptURL(t *testing.T) {
	// AI disabled must not break the direct-URL path: it needs no model.
	svc := NewAssistService(AssistConfig{Client: nil, Search: NewService(ServiceConfig{})})

	resp := svc.Assist(context.Background(), "https://soundcloud.com/porter-robinson/shelter-live", 0)

	if resp.Status != AssistStatusOK {
		t.Fatalf("status = %q, want ok for a resolvable URL even with AI disabled", resp.Status)
	}
	if len(resp.Candidates) != 1 || resp.Candidates[0].Provider != "soundcloud" {
		t.Fatalf("prompt URL not resolved with AI disabled: %#v", resp.Candidates)
	}
}

func TestAssistHandlerRejectsBadRequests(t *testing.T) {
	handlers := NewHandlers(NewService(ServiceConfig{}))
	cases := []struct {
		name       string
		body       string
		wantStatus int
		wantCode   string
	}{
		{name: "invalid json", body: `{`, wantStatus: http.StatusBadRequest, wantCode: "INVALID_REQUEST"},
		{name: "empty prompt", body: `{"prompt":"   "}`, wantStatus: http.StatusBadRequest, wantCode: "INVALID_PROMPT"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(tc.body))
			handlers.Assist(rec, req)
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			var payload struct {
				Code string `json:"code"`
			}
			_ = json.Unmarshal(rec.Body.Bytes(), &payload)
			if payload.Code != tc.wantCode {
				t.Fatalf("error code = %q, want %q", payload.Code, tc.wantCode)
			}
		})
	}
}

func TestAssistHandlerOversizedBodyRejected(t *testing.T) {
	handlers := NewHandlers(NewService(ServiceConfig{}))
	body := `{"prompt":"` + strings.Repeat("a", assistMaxRequestBodyBytes+1) + `"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(body))
	handlers.Assist(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for oversized body", rec.Code)
	}
}

func TestAssistHandlerDefaultIsDisabledAnd200(t *testing.T) {
	// NewHandlers installs a disabled assist service (no model configured).
	handlers := NewHandlers(NewService(ServiceConfig{}))
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(`{"prompt":"find a song"}`))
	handlers.Assist(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 disabled envelope; body=%s", rec.Code, rec.Body.String())
	}
	var resp AssistResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Status != AssistStatusDisabled {
		t.Fatalf("status = %q, want disabled", resp.Status)
	}
	// No assist outcome may create queue/download work.
	raw := rec.Body.String()
	for _, forbidden := range []string{"queueItemId", "downloadJobId", "\"job\"", "\"queue\""} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("assist response unexpectedly contains %q: %s", forbidden, raw)
		}
	}
}

func assistRequestForUser(body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/assist", strings.NewReader(body))
	return req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
}

func TestAssistHandlerPersistsDirectCandidateSelection(t *testing.T) {
	store := &captureSelectionStore{}
	service := NewService(ServiceConfig{})
	h := NewHandlersWithAssistAndSelectionStore(service, NewAssistService(AssistConfig{Search: service}), store)
	rec := httptest.NewRecorder()
	h.Assist(rec, assistRequestForUser(`{"prompt":"add https://www.youtube.com/watch?v=dQw4w9WgXcQ"}`))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var response AssistResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if store.session == nil || len(store.session.Candidates) == 0 || store.session.Context != "discovery_assist_direct_url" {
		t.Fatalf("persisted session = %#v", store.session)
	}
	if !response.SelectionRequired || response.SelectionSessionID == "" || response.RecommendedCandidateID == "" || response.SelectionExpiresAt == nil {
		t.Fatalf("selection metadata = %#v", response)
	}
}

func TestAssistHandlerPersistsNestedSearchSelection(t *testing.T) {
	store := &captureSelectionStore{}
	provider := fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:found", Provider: "youtube", SourceURL: "https://example.test/found", Title: "Found", Downloadable: true}}}
	service := NewService(ServiceConfig{Providers: []Provider{provider}, DefaultProviders: []string{"youtube"}})
	assist := NewAssistService(AssistConfig{Client: &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "found", Providers: []string{"youtube"}}}, Search: service})
	h := NewHandlersWithAssistAndSelectionStore(service, assist, store)
	rec := httptest.NewRecorder()
	h.Assist(rec, assistRequestForUser(`{"prompt":"find found"}`))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var response AssistResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if store.session == nil || store.session.Query != "found" || store.session.Context != "discovery_assist_search" {
		t.Fatalf("persisted session = %#v", store.session)
	}
	if response.Search == nil || !response.SelectionRequired || response.SelectionSessionID == "" || response.RecommendedCandidateID != "youtube:found" || response.SelectionExpiresAt == nil {
		t.Fatalf("assist response = %#v", response)
	}
}

func TestAssistHandlerEmptyOutcomeExplicitlyHasNoSelection(t *testing.T) {
	store := &captureSelectionStore{}
	service := NewService(ServiceConfig{})
	h := NewHandlersWithAssistAndSelectionStore(service, NewAssistService(AssistConfig{Search: service}), store)
	rec := httptest.NewRecorder()
	h.Assist(rec, assistRequestForUser(`{"prompt":"find something"}`))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var response AssistResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if store.session != nil || response.SelectionRequired || response.SelectionSessionID != "" || response.RecommendedCandidateID != "" || response.SelectionExpiresAt != nil {
		t.Fatalf("empty assist selection = %#v, session=%#v", response, store.session)
	}
}

func TestAssistHandlerFailsWhenSelectionPersistenceFails(t *testing.T) {
	service := NewService(ServiceConfig{})
	h := NewHandlersWithAssistAndSelectionStore(service, NewAssistService(AssistConfig{Search: service}), &captureSelectionStore{err: errors.New("db unavailable")})
	rec := httptest.NewRecorder()
	h.Assist(rec, assistRequestForUser(`{"prompt":"add https://www.youtube.com/watch?v=dQw4w9WgXcQ"}`))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "SOURCE_SELECTION_PERSISTENCE_FAILED") {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

// TestAssistEndToEndWithFakeOpenAIEndpoint drives the REAL aiassist HTTP client
// against a fake OpenAI-compatible server, through the full orchestration. The
// fake model returns a search intent plus a fabricated playback URL; the response
// must carry grounded provider provenance and never the fabricated URL.
func TestAssistEndToEndWithFakeOpenAIEndpoint(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		content := `{"kind":"search","assistantText":"Found some live versions","searchQuery":"Porter Robinson Shelter live","providers":["youtube"],"detectedUrl":"` + hallucinatedURL + `","caveats":["might not be the live cut, see ` + hallucinatedURL + `"]}`
		resp := map[string]interface{}{"choices": []map[string]interface{}{{"message": map[string]interface{}{"content": content}}}}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := aiassist.NewClient(aiassist.Config{Enabled: true, BaseURL: srv.URL, APIKey: "sk-secret-key", Model: "m"})
	counting := &countingProvider{name: "youtube"}
	svc := NewAssistService(AssistConfig{Client: client, Search: NewService(ServiceConfig{Providers: []Provider{counting}, DefaultProviders: []string{"youtube"}})})

	resp := svc.Assist(context.Background(), "that live Porter Robinson shelter version from youtube", 0)

	if gotAuth != "Bearer sk-secret-key" {
		t.Fatalf("model endpoint did not receive bearer auth")
	}
	if counting.calls.Load() != 1 {
		t.Fatalf("discovery provider not called end-to-end (calls=%d)", counting.calls.Load())
	}
	if resp.Status != AssistStatusOK || resp.Search == nil || len(resp.Search.Providers) == 0 {
		t.Fatalf("missing grounded provenance: %#v", resp)
	}
	body := mustMarshal(t, resp)
	if strings.Contains(body, "ai-generated.example") {
		t.Fatalf("fabricated playback URL present end-to-end: %s", body)
	}
	if strings.Contains(body, "sk-secret-key") {
		t.Fatalf("api key leaked into response: %s", body)
	}
}

// TestAssistDogfoodMessyRequestHasProvenanceNotHallucination is the issue's
// dogfood scenario wired through a fake model endpoint end to end.
func TestAssistDogfoodMessyRequestHasProvenanceNotHallucination(t *testing.T) {
	counting := &countingProvider{name: "youtube"}
	client := &fakeAssistClient{intent: &aiassist.Intent{
		Kind:          aiassist.KindSearch,
		AssistantText: "Looking for the live Shelter cut",
		SearchQuery:   "Porter Robinson Shelter live",
		Providers:     []string{"youtube"},
		DetectedURL:   hallucinatedURL,
		Caveats:       []string{"I'm not certain this is the live version"},
	}}
	svc := NewAssistService(AssistConfig{Client: client, Search: NewService(ServiceConfig{Providers: []Provider{counting}, DefaultProviders: []string{"youtube"}})})

	resp := svc.Assist(context.Background(), "that live Porter Robinson shelter version from youtube", 0)

	if counting.calls.Load() != 1 {
		t.Fatalf("dogfood: discovery provider was not called (calls=%d)", counting.calls.Load())
	}
	if resp.Search == nil || len(resp.Search.Providers) == 0 {
		t.Fatalf("dogfood: response lacks provider provenance: %#v", resp.Search)
	}
	body := mustMarshal(t, resp)
	if strings.Contains(body, "ai-generated.example") {
		t.Fatalf("dogfood: hallucinated playback URL present in response: %s", body)
	}
	if !strings.Contains(body, "not certain") {
		t.Fatalf("dogfood: model caveat/uncertainty not surfaced: %s", body)
	}
}
