// Package aiassist holds the OpenAI-compatible model client used by the grounded
// search assist endpoint (#75). It is deliberately narrow: it turns a user's
// natural-language prompt into a structured Intent and nothing else. It performs
// no discovery, never resolves URLs, and never produces playable/downloadable
// sources. The orchestration that grounds an Intent against real OMP discovery
// and URL resolution lives in the discovery package, so this package has no
// dependency on discovery and cannot, by construction, emit a candidate URL.
package aiassist

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Intent kinds the model may return. Unknown/empty kinds normalize to KindSearch
// so a malformed kind never silently drops the request.
const (
	KindSearch      = "search"
	KindClarify     = "clarify"
	KindDirectURL   = "direct_url"
	KindUnsupported = "unsupported"
)

// Error codes surfaced to the orchestration layer. They are stable strings so
// the HTTP envelope can branch on them without string matching. None of these
// messages ever contain the API key (see redact).
const (
	CodeDisabled      = "AI_DISABLED"
	CodeTimeout       = "AI_TIMEOUT"
	CodeUpstream      = "AI_UPSTREAM"
	CodeBadResponse   = "AI_BAD_RESPONSE"
	CodeConfigInvalid = "AI_CONFIG_INVALID"
)

// Error is a typed model-client failure carrying a stable machine code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Message }

// Clarification is a follow-up question the model asks when the request is too
// ambiguous to ground.
type Clarification struct {
	Question string   `json:"question"`
	Options  []string `json:"options,omitempty"`
}

// Intent is the structured output the model is forced to return. It is advisory
// only: SearchQuery/Providers steer OMP's own discovery search, and DetectedURL
// is treated as an untrusted hint that the orchestration layer never resolves.
// The model can never put a playable or downloadable URL into a candidate.
type Intent struct {
	Kind          string         `json:"kind"`
	AssistantText string         `json:"assistantText,omitempty"`
	SearchQuery   string         `json:"searchQuery,omitempty"`
	Providers     []string       `json:"providers,omitempty"`
	Clarification *Clarification `json:"clarification,omitempty"`
	DetectedURL   string         `json:"detectedUrl,omitempty"`
	Caveats       []string       `json:"caveats,omitempty"`
}

// normalize lowercases the kind, defaults unknown kinds to search, and trims
// provider hints so downstream provider matching is predictable.
func (i *Intent) normalize() {
	kind := strings.ToLower(strings.TrimSpace(i.Kind))
	switch kind {
	case KindSearch, KindClarify, KindDirectURL, KindUnsupported:
		i.Kind = kind
	default:
		i.Kind = KindSearch
	}
	providers := make([]string, 0, len(i.Providers))
	for _, p := range i.Providers {
		if trimmed := strings.TrimSpace(p); trimmed != "" {
			providers = append(providers, trimmed)
		}
	}
	i.Providers = providers
	i.SearchQuery = strings.TrimSpace(i.SearchQuery)
}

// Client extracts a structured Intent from a natural-language prompt.
type Client interface {
	ExtractIntent(ctx context.Context, prompt string) (*Intent, error)
}

// Config configures the OpenAI-compatible model client.
type Config struct {
	Enabled bool
	BaseURL string
	APIKey  string
	Model   string
	Timeout time.Duration
}

// Ready reports whether the assist client is enabled and fully configured.
// An enabled-but-incomplete config is not ready, so a half-set environment
// degrades to the disabled state rather than issuing broken requests.
func (c Config) Ready() bool {
	return c.Enabled && strings.TrimSpace(c.BaseURL) != "" && strings.TrimSpace(c.APIKey) != "" && strings.TrimSpace(c.Model) != ""
}

// NewClient builds a model client from cfg. It returns a true nil interface when
// the config is not ready, so callers treat a missing/disabled model as simply
// "no client" without a sentinel. This keeps the disabled path branch-free.
func NewClient(cfg Config) Client {
	if !cfg.Ready() {
		return nil
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 8 * time.Second
	}
	return &openAIClient{
		httpClient: &http.Client{Timeout: timeout},
		baseURL:    strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/"),
		apiKey:     strings.TrimSpace(cfg.APIKey),
		model:      strings.TrimSpace(cfg.Model),
	}
}

// SystemPrompt is the grounding contract handed to the model on every call. It is
// exported so tests and reviewers can assert the boundary language stays intact.
const SystemPrompt = `You are the sourcing assistant for Open Music Player (OMP), a personal, local-first music library and queue tool. You are NOT a streaming service, a licensed catalog, or a download agent.

Your only job is to turn the user's message into a structured search/source intent. You DO NOT have access to playable audio, and you MUST NEVER invent, guess, or output streaming, download, or file URLs. OMP's own discovery and URL-resolution code is the only source of truth for sources; you never are.

Respond with a single JSON object and nothing else, matching:
{
  "kind": "search" | "clarify" | "direct_url" | "unsupported",
  "assistantText": "one short sentence to the user",
  "searchQuery": "a clean search query for OMP discovery (omit URLs)",
  "providers": ["youtube" and/or "soundcloud" when the user names a source"],
  "clarification": { "question": "...", "options": ["..."] },
  "detectedUrl": "a URL only if the USER pasted one, else empty",
  "caveats": ["honest uncertainty, e.g. 'I am not sure this is the live version'"]
}

Rules:
- Use "search" for natural-language song/artist/album requests; put your best normalized query in searchQuery.
- Use "clarify" only when you truly cannot form a query without more info; ask one concise question.
- Use "direct_url" only when the user pasted a link; never fabricate one.
- Use "unsupported" for requests OMP cannot help with.
- Never claim certainty you do not have. Prefer caveats over false confidence.
- Output JSON only. No prose outside the JSON object.`

type openAIClient struct {
	httpClient *http.Client
	baseURL    string
	apiKey     string
	model      string
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type responseFormat struct {
	Type string `json:"type"`
}

type chatRequest struct {
	Model          string          `json:"model"`
	Temperature    float64         `json:"temperature"`
	Messages       []chatMessage   `json:"messages"`
	ResponseFormat *responseFormat `json:"response_format,omitempty"`
}

type chatCompletion struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

// maxResponseBytes caps how much of the model response we read. Intent JSON is
// tiny; a larger body is treated as a bad response rather than buffered.
const maxResponseBytes = 1 << 20

// ExtractIntent calls the OpenAI-compatible chat completions endpoint with JSON
// response forcing and parses the structured Intent. Every error path is mapped
// to a typed *Error with a stable code and a message guaranteed not to contain
// the API key.
func (c *openAIClient) ExtractIntent(ctx context.Context, prompt string) (*Intent, error) {
	payload := chatRequest{
		Model:          c.model,
		Temperature:    0,
		ResponseFormat: &responseFormat{Type: "json_object"},
		Messages: []chatMessage{
			{Role: "system", Content: SystemPrompt},
			{Role: "user", Content: prompt},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, &Error{Code: CodeBadResponse, Message: "failed to encode assist request"}
	}

	endpoint := c.baseURL + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, &Error{Code: CodeUpstream, Message: c.redact(err.Error())}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(ctx.Err(), context.Canceled) {
			return nil, &Error{Code: CodeTimeout, Message: "ai assist request timed out"}
		}
		return nil, &Error{Code: CodeUpstream, Message: c.redact(err.Error())}
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(ctx.Err(), context.Canceled) {
			return nil, &Error{Code: CodeTimeout, Message: "ai assist request timed out"}
		}
		return nil, &Error{Code: CodeUpstream, Message: c.redact(err.Error())}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Deliberately do not echo the upstream body: it could repeat the request
		// (and thus the key) and adds no machine-actionable signal beyond status.
		return nil, &Error{Code: CodeUpstream, Message: fmt.Sprintf("ai assist upstream returned status %d", resp.StatusCode)}
	}

	var completion chatCompletion
	if err := json.Unmarshal(raw, &completion); err != nil || len(completion.Choices) == 0 {
		return nil, &Error{Code: CodeBadResponse, Message: "ai assist returned an unreadable response"}
	}
	content := strings.TrimSpace(completion.Choices[0].Message.Content)
	var intent Intent
	if err := json.Unmarshal([]byte(content), &intent); err != nil {
		return nil, &Error{Code: CodeBadResponse, Message: "ai assist returned malformed intent json"}
	}
	intent.normalize()
	return &intent, nil
}

// redact strips the API key from any string before it is surfaced as an error.
// net/http errors carry the request URL but not headers, so the key should never
// reach here; this is defense in depth against transport-layer leakage.
func (c *openAIClient) redact(s string) string {
	if c.apiKey == "" {
		return s
	}
	return strings.ReplaceAll(s, c.apiKey, "[REDACTED]")
}
