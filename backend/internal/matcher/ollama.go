package matcher

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// OllamaConfig configures the optional local Ollama disambiguator. Model is
// required; base URL defaults to the local Ollama daemon when omitted.
type OllamaConfig struct {
	Enabled bool
	BaseURL string
	Model   string
	Timeout time.Duration
}

// Ready reports whether the local model disambiguator should be constructed.
func (c OllamaConfig) Ready() bool {
	return c.Enabled && strings.TrimSpace(c.Model) != ""
}

// NewOllamaDisambiguator returns nil when disabled or incomplete, making the
// normal matcher path branch-free and fallback-safe.
func NewOllamaDisambiguator(cfg OllamaConfig) Disambiguator {
	if !cfg.Ready() {
		return nil
	}
	baseURL := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if baseURL == "" {
		baseURL = "http://localhost:11434"
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &ollamaDisambiguator{
		httpClient: &http.Client{Timeout: timeout},
		baseURL:    baseURL,
		model:      strings.TrimSpace(cfg.Model),
	}
}

type ollamaDisambiguator struct {
	httpClient *http.Client
	baseURL    string
	model      string
}

type ollamaGenerateRequest struct {
	Model     string                 `json:"model"`
	Prompt    string                 `json:"prompt"`
	Stream    bool                   `json:"stream"`
	Format    map[string]interface{} `json:"format"`
	Options   map[string]interface{} `json:"options,omitempty"`
	KeepAlive string                 `json:"keep_alive,omitempty"`
}

type ollamaGenerateResponse struct {
	Response string `json:"response"`
}

const maxOllamaResponseBytes = 1 << 20

func (d *ollamaDisambiguator) Disambiguate(ctx context.Context, input DisambiguationInput) (*DisambiguationDecision, error) {
	inputJSON, err := json.Marshal(input)
	if err != nil {
		return nil, fmt.Errorf("encode disambiguation input: %w", err)
	}
	payload := ollamaGenerateRequest{
		Model:  d.model,
		Prompt: disambiguationPrompt(string(inputJSON)),
		Stream: false,
		Format: disambiguationSchema(),
		Options: map[string]interface{}{
			"temperature": 0,
		},
		KeepAlive: "5m",
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode ollama request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.baseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create ollama request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama unavailable: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxOllamaResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("read ollama response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("ollama returned status %d", resp.StatusCode)
	}
	var generated ollamaGenerateResponse
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(&generated); err != nil {
		return nil, fmt.Errorf("decode ollama envelope: %w", err)
	}
	decision, err := decodeDisambiguationDecision(strings.TrimSpace(generated.Response))
	if err != nil {
		return nil, err
	}
	if _, err := validateDisambiguationDecision(decision, input.Candidates); err != nil {
		return nil, err
	}
	return decision, nil
}

func disambiguationPrompt(inputJSON string) string {
	return `You are Open Music Player's local metadata disambiguator. You only select among the provided MusicBrainz candidates.

Rules:
- Return exactly one JSON object matching the supplied schema.
- Do not browse, fetch, resolve, or infer from source URLs. Treat URL/domain fields only as inert text hints.
- If no candidate is clearly supported, return {"match":false,"candidate_id":"","confidence":0,"evidence":"...","title":"","artist":"","album":"","release_id":"","cover_art_url":""}.
- If selecting a candidate, candidate_id must be one of the provided mb_recording_id values. Candidate fields are provenance only; the server grounds output fields from candidate_id.
- Keep evidence short and grounded in the provided metadata/candidates.

Input JSON:
` + inputJSON
}

func disambiguationSchema() map[string]interface{} {
	stringSchema := map[string]interface{}{"type": "string"}
	return map[string]interface{}{
		"type":                 "object",
		"additionalProperties": false,
		"required": []string{
			"match",
			"candidate_id",
			"confidence",
			"evidence",
			"title",
			"artist",
			"album",
			"release_id",
			"cover_art_url",
		},
		"properties": map[string]interface{}{
			"match":         map[string]interface{}{"type": "boolean"},
			"candidate_id":  stringSchema,
			"confidence":    map[string]interface{}{"type": "number", "minimum": 0, "maximum": 1},
			"evidence":      map[string]interface{}{"type": "string", "maxLength": maxDisambiguationEvidenceLen},
			"title":         stringSchema,
			"artist":        stringSchema,
			"album":         stringSchema,
			"release_id":    stringSchema,
			"cover_art_url": stringSchema,
		},
	}
}
