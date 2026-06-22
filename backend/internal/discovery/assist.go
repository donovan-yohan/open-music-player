package discovery

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/aiassist"
)

// urlPattern matches an absolute http(s) URL run anywhere in a string, regardless
// of surrounding punctuation or markup. A whitespace-tokenizer + prefix check is
// not enough: a model can glue a fabricated URL to other characters
// ("link:https://x", "[x](https://x)", `href="https://x"`, "a,https://x,b") to
// slip it past token-based stripping. Matching the scheme run anywhere closes
// that class of bypass. It deliberately over-matches into trailing punctuation;
// findFirstURL trims that back before handing a user URL to the resolver.
var urlPattern = regexp.MustCompile(`(?i)https?://\S+`)

// safeProviderName bounds a provider hint to a plain identifier so a model can
// never smuggle a URL (or other free text) into the provider list, which would
// otherwise echo into the search query, provider summaries, and caveats.
var safeProviderName = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

// assistMaxRequestBodyBytes caps the assist request body. The body is a short
// natural-language prompt, so 16 KiB is generous while rejecting abusive input.
const assistMaxRequestBodyBytes = 16 * 1024

// Assist envelope status values. The endpoint always returns HTTP 200 for an
// orchestrated outcome and lets the UI branch on this status, so disabled and
// upstream-error states are first-class data rather than transport failures.
const (
	AssistStatusOK            = "ok"
	AssistStatusDisabled      = "disabled"
	AssistStatusClarification = "clarification"
	AssistStatusError         = "error"
)

// AssistRequest is the POST /api/v1/discovery/assist body.
type AssistRequest struct {
	Prompt string `json:"prompt"`
	Limit  int    `json:"limit,omitempty"`
}

// AssistIntent is the grounded echo of how OMP interpreted the request. Unlike
// the raw model intent, DetectedURL here is only ever a URL that was present in
// the user's prompt AND accepted by the OMP resolver, never a model-emitted one.
type AssistIntent struct {
	Kind        string   `json:"kind"`
	SearchQuery string   `json:"searchQuery,omitempty"`
	Providers   []string `json:"providers,omitempty"`
	DetectedURL string   `json:"detectedUrl,omitempty"`
}

// AssistClarification is a follow-up question surfaced to the user.
type AssistClarification struct {
	Question string   `json:"question"`
	Options  []string `json:"options,omitempty"`
}

// AssistAction is a suggested, non-destructive next step. It never executes; the
// user must explicitly confirm queue/import/download in a separate request.
type AssistAction struct {
	Kind        string `json:"kind"`
	Label       string `json:"label"`
	CandidateID string `json:"candidateId,omitempty"`
}

// AssistError carries a stable code for disabled/upstream/timeout outcomes.
type AssistError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// AssistResponse is the deterministic, future-UI-friendly envelope. Candidates
// holds only resolver-grounded direct-URL candidates; search results live in
// Search (with its own provider summaries) so grounding provenance is explicit.
type AssistResponse struct {
	Status           string               `json:"status"`
	AssistantText    string               `json:"assistantText,omitempty"`
	Intent           *AssistIntent        `json:"intent,omitempty"`
	Clarification    *AssistClarification `json:"clarification,omitempty"`
	Search           *SearchResponse      `json:"search,omitempty"`
	Candidates       []Candidate          `json:"candidates,omitempty"`
	Caveats          []string             `json:"caveats,omitempty"`
	SuggestedActions []AssistAction       `json:"suggestedActions,omitempty"`
	Error            *AssistError         `json:"error,omitempty"`
}

// AssistService grounds a model intent against real OMP discovery and URL
// resolution. It holds the discovery Service and URLResolver but no queue or
// download dependency, so it cannot enqueue or download anything: it only
// returns candidates the user must explicitly act on. A nil client means the
// model is disabled; the direct-URL path still works without a model.
type AssistService struct {
	client   aiassist.Client
	search   *Service
	resolver *URLResolver
	timeout  time.Duration
}

// AssistConfig configures an AssistService.
type AssistConfig struct {
	Client  aiassist.Client
	Search  *Service
	Timeout time.Duration
}

// NewAssistService builds an AssistService, filling sane defaults. A nil Client
// yields a disabled-but-functional service (direct URL resolution still works).
// It builds a default resolver; when wired through NewHandlersWithAssist the
// handler shares its single resolver instead. The per-request search limit is
// clamped by the discovery Service itself, so it is not re-bounded here.
func NewAssistService(cfg AssistConfig) *AssistService {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 8 * time.Second
	}
	return &AssistService{
		client:   cfg.Client,
		search:   cfg.Search,
		resolver: NewURLResolver(nil),
		timeout:  cfg.Timeout,
	}
}

// Assist turns a natural-language prompt into a grounded AssistResponse.
//
// Grounding order, by design:
//  1. If the user's prompt contains an absolute http(s) URL, resolve it through
//     the existing OMP resolver and return a direct-URL candidate. This path is
//     model-independent and works even when the model is disabled.
//  2. Otherwise, if the model is disabled, return a useful disabled envelope.
//  3. Otherwise, ask the model for a structured intent and ground it: a search
//     intent calls OMP discovery; a clarify intent passes through; a direct_url
//     intent with no usable user URL degrades to a search with a caveat.
//
// Candidate URLs only ever originate from the user's pasted URL (after resolver
// validation) or from OMP discovery providers. A URL the model emits is never
// resolved and never becomes a candidate.
func (s *AssistService) Assist(ctx context.Context, prompt string, limit int) AssistResponse {
	prompt = strings.TrimSpace(prompt)

	// 1. Grounded direct-URL path: the URL comes from the user's own prompt.
	if raw := findFirstURL(prompt); raw != "" {
		if candidate, err := s.resolver.Resolve(raw); err == nil {
			return s.directURLResponse(candidate)
		}
		// A URL-looking token that the resolver rejects (unsupported host, bad
		// scheme) is not grounds to fail the whole request: fall through to the
		// model/disabled path so the user still gets help.
	}

	// 2. Disabled model: no URL to ground and no model to consult.
	if s.client == nil {
		return disabledAssistResponse()
	}

	// 3. Model-driven intent, grounded against real discovery.
	modelCtx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()
	rawIntent, err := s.client.ExtractIntent(modelCtx, prompt)
	if err != nil {
		return assistErrorResponse(err)
	}
	if rawIntent == nil {
		return assistErrorResponse(&aiassist.Error{Code: aiassist.CodeBadResponse, Message: "ai assist returned nil intent"})
	}
	// Strip any URL the model embedded in free text (assistantText, caveats,
	// clarification, even the search query). This makes the boundary airtight:
	// no model-originated URL can reach the client in any field, so a UI cannot
	// render a fabricated "playable" link. Grounded candidate URLs are untouched.
	intent := sanitizeIntent(rawIntent)

	switch intent.Kind {
	case aiassist.KindClarify:
		return s.clarificationResponse(intent)
	case aiassist.KindUnsupported:
		return AssistResponse{
			Status:        AssistStatusOK,
			AssistantText: firstNonEmpty(intent.AssistantText, "I can't help with that request."),
			Intent:        &AssistIntent{Kind: aiassist.KindUnsupported},
			Caveats:       intent.Caveats,
		}
	case aiassist.KindDirectURL:
		// The model thinks this is a link, but step 1 found no usable URL in the
		// prompt. We never resolve the model's DetectedURL, so degrade to search.
		caveats := append([]string{"I couldn't find a usable link in your message, so I searched instead."}, intent.Caveats...)
		return s.searchResponse(ctx, intent, limit, caveats)
	default: // KindSearch and any normalized-unknown kind
		return s.searchResponse(ctx, intent, limit, intent.Caveats)
	}
}

// searchResponse grounds a search intent against the discovery service. Provider
// and catalog failures stay isolated inside SearchResponse.Providers and are
// also surfaced as human caveats so the UI can show what degraded.
func (s *AssistService) searchResponse(ctx context.Context, intent *aiassist.Intent, limit int, caveats []string) AssistResponse {
	query := firstNonEmpty(intent.SearchQuery, intent.AssistantText)
	if query == "" {
		// Nothing groundable; ask the user to rephrase rather than guess.
		return AssistResponse{
			Status:        AssistStatusClarification,
			AssistantText: firstNonEmpty(intent.AssistantText, "Could you tell me the song or artist you're looking for?"),
			Clarification: &AssistClarification{Question: "What song, artist, or album are you looking for?"},
			Intent:        &AssistIntent{Kind: aiassist.KindSearch},
			Caveats:       caveats,
		}
	}

	result := s.search.Search(ctx, query, intent.Providers, limit)
	merged := append([]string(nil), caveats...)
	merged = append(merged, providerCaveats(result.Providers)...)

	return AssistResponse{
		Status:        AssistStatusOK,
		AssistantText: firstNonEmpty(intent.AssistantText, "Here's what I found from your sources."),
		Intent:        &AssistIntent{Kind: aiassist.KindSearch, SearchQuery: query, Providers: intent.Providers},
		Search:        &result,
		Caveats:       merged,
	}
}

// directURLResponse wraps a resolver-grounded candidate. The only suggested
// action is a queue intent the user must confirm; nothing is enqueued here.
func (s *AssistService) directURLResponse(candidate Candidate) AssistResponse {
	return AssistResponse{
		Status:        AssistStatusOK,
		AssistantText: "I recognized a direct link. Confirm to add it to your queue.",
		Intent:        &AssistIntent{Kind: aiassist.KindDirectURL, DetectedURL: candidate.SourceURL},
		Candidates:    []Candidate{candidate},
		SuggestedActions: []AssistAction{
			{Kind: "queue", Label: "Add to queue", CandidateID: candidate.CandidateID},
		},
	}
}

func (s *AssistService) clarificationResponse(intent *aiassist.Intent) AssistResponse {
	clar := &AssistClarification{Question: "Could you give me a bit more detail?"}
	if intent.Clarification != nil && strings.TrimSpace(intent.Clarification.Question) != "" {
		clar = &AssistClarification{Question: intent.Clarification.Question, Options: intent.Clarification.Options}
	}
	return AssistResponse{
		Status:        AssistStatusClarification,
		AssistantText: firstNonEmpty(intent.AssistantText, clar.Question),
		Clarification: clar,
		Intent:        &AssistIntent{Kind: aiassist.KindClarify},
		Caveats:       intent.Caveats,
	}
}

// disabledAssistResponse is the envelope returned when no model is configured.
// It is shared by the service's disabled branch and the handler's defensive
// branch so the disabled message stays identical in both.
func disabledAssistResponse() AssistResponse {
	return AssistResponse{
		Status:        AssistStatusDisabled,
		AssistantText: "AI assist is not configured. You can still search directly or paste a YouTube/SoundCloud link.",
		Error:         &AssistError{Code: aiassist.CodeDisabled, Message: "ai assist is disabled"},
	}
}

// assistErrorResponse maps a typed model-client error into the envelope. The
// message is taken from the typed error, which the client guarantees is free of
// the API key.
func assistErrorResponse(err error) AssistResponse {
	code := aiassist.CodeUpstream
	message := "ai assist request failed"
	if e, ok := err.(*aiassist.Error); ok {
		code = e.Code
		message = e.Message
	}
	return AssistResponse{
		Status:        AssistStatusError,
		AssistantText: "The assistant is unavailable right now. You can still search directly or paste a link.",
		Error:         &AssistError{Code: code, Message: message},
	}
}

// providerCaveats turns non-ok provider summaries into short human caveats so a
// degraded source is visible at the top level, not just in the search metadata.
func providerCaveats(providers []ProviderSummary) []string {
	var caveats []string
	for _, p := range providers {
		if p.Status != ProviderStatusOK && p.Status != "" {
			caveats = append(caveats, p.Provider+": "+p.Status)
		}
	}
	return caveats
}

// findFirstURL returns the first absolute http(s) URL in the prompt, or "". It
// trims trailing punctuation/markup the over-broad match may have captured so a
// user-pasted-but-punctuated link (e.g. "(https://youtu.be/x)") still grounds
// through the resolver, which makes the final accept/reject decision.
func findFirstURL(prompt string) string {
	match := urlPattern.FindString(prompt)
	if match == "" {
		return ""
	}
	return strings.TrimRight(match, `)]}>"',.;!?`)
}

// stripURLs removes every absolute http(s) URL run from model-originated free
// text, regardless of surrounding characters. It is the single choke point that
// prevents a model from surfacing a fabricated link in any user-visible string.
// Leftover whitespace is collapsed, which is fine for short assistant prose.
func stripURLs(s string) string {
	if s == "" || !urlPattern.MatchString(s) {
		return s
	}
	cleaned := urlPattern.ReplaceAllString(s, "")
	return strings.Join(strings.Fields(cleaned), " ")
}

// sanitizeProviders keeps only plain-identifier provider hints, dropping anything
// (URLs, free text) a model might inject. This stops a model-controlled string
// from reaching the discovery search query, provider summaries, or caveats.
func sanitizeProviders(in []string) []string {
	out := make([]string, 0, len(in))
	for _, p := range in {
		if trimmed := strings.TrimSpace(p); safeProviderName.MatchString(trimmed) {
			out = append(out, trimmed)
		}
	}
	return out
}

func stripURLsAll(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if cleaned := strings.TrimSpace(stripURLs(s)); cleaned != "" {
			out = append(out, cleaned)
		}
	}
	return out
}

// sanitizeIntent returns a copy of the model intent with all free-text fields
// scrubbed of URLs and fresh slices (so it never mutates a caller's intent).
// DetectedURL is retained but is never surfaced or resolved on the model path.
func sanitizeIntent(in *aiassist.Intent) *aiassist.Intent {
	// DetectedURL is intentionally dropped: the model path never resolves or
	// surfaces it (only a user-prompt URL grounds a direct candidate), so carrying
	// it forward would be dead state.
	out := &aiassist.Intent{
		Kind:          in.Kind,
		AssistantText: stripURLs(in.AssistantText),
		SearchQuery:   stripURLs(in.SearchQuery),
		Providers:     sanitizeProviders(in.Providers),
		Caveats:       stripURLsAll(in.Caveats),
	}
	if in.Clarification != nil {
		out.Clarification = &aiassist.Clarification{
			Question: stripURLs(in.Clarification.Question),
			Options:  stripURLsAll(in.Clarification.Options),
		}
	}
	return out
}

// Assist handles POST /api/v1/discovery/assist. Malformed requests get a 4xx;
// every orchestrated outcome (ok/disabled/clarification/error) returns 200 with
// the status encoded in the envelope. This handler starts no download and
// mutates no queue.
func (h *Handlers) Assist(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, assistMaxRequestBodyBytes)
	var req AssistRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}
	prompt := strings.TrimSpace(req.Prompt)
	if prompt == "" {
		writeError(w, http.StatusBadRequest, "INVALID_PROMPT", "prompt is required")
		return
	}
	if h.assist == nil {
		// Defensive: NewHandlers always installs a (possibly disabled) assist
		// service, so this only fires for a hand-built zero Handlers.
		writeJSON(w, http.StatusOK, disabledAssistResponse())
		return
	}
	writeJSON(w, http.StatusOK, h.assist.Assist(r.Context(), prompt, req.Limit))
}
