package discovery

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

const (
	ollamaSourceQualityProvenance = "ollama_source_quality_v1"
	ollamaSourceQualityModel      = "source-quality-judge"
	ollamaDefaultBaseURL          = "http://localhost:11434"
	ollamaDefaultTimeout          = 1500 * time.Millisecond

	ollamaMaxCandidates         = 8
	ollamaMaxJudgments          = ollamaMaxCandidates
	ollamaMaxQueryBytes         = 512
	ollamaMaxCandidateIDBytes   = 256
	ollamaMaxFeatureStringBytes = 256
	ollamaMaxMetadataHints      = 6
	ollamaMaxHintKeyBytes       = 64
	ollamaMaxHintValues         = 4
	ollamaMaxHintValueBytes     = 128
	ollamaMaxReasons            = 8
	ollamaMaxWarnings           = 8
	ollamaMaxReasonBytes        = 200
	ollamaMaxWarningBytes       = 200
	ollamaMaxRequestBytes       = 48 * 1024
	ollamaMaxResponseBytes      = 64 * 1024
	ollamaNumPredict            = 1024
	ollamaTemperature           = 0
)

// OllamaSourceQualityConfig is supplied by the caller. It deliberately has no
// dependency on process environment or the application's configuration layer.
type OllamaSourceQualityConfig struct {
	Enabled bool
	BaseURL string
	Model   string
	Timeout time.Duration
	APIKey  string
}

// OllamaSourceQualityJudge adapts Ollama's generate API to SourceQualityJudge.
type OllamaSourceQualityJudge struct {
	baseURL    string
	model      string
	apiKey     string
	httpClient *http.Client
}

// NewOllamaSourceQualityJudge returns nil when this optional judge is disabled.
func NewOllamaSourceQualityJudge(cfg OllamaSourceQualityConfig) *OllamaSourceQualityJudge {
	if !cfg.Enabled {
		return nil
	}
	baseURL := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if baseURL == "" {
		baseURL = ollamaDefaultBaseURL
	}
	model := strings.TrimSpace(cfg.Model)
	if model == "" {
		model = ollamaSourceQualityModel
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = ollamaDefaultTimeout
	}
	return &OllamaSourceQualityJudge{
		baseURL:    baseURL,
		model:      model,
		apiKey:     cfg.APIKey,
		httpClient: &http.Client{Timeout: timeout},
	}
}

// JudgeSourceQuality returns only validated, grounded model judgments. An
// error is intentional: rankSourceCandidatesWithJudge keeps its deterministic
// quality result unless the entire response has passed this boundary.
func (j *OllamaSourceQualityJudge) JudgeSourceQuality(ctx context.Context, query string, candidates []SourceQualityCandidateFeature) ([]SourceQualityJudgment, error) {
	if j == nil || len(candidates) == 0 {
		return nil, nil
	}

	bounded, candidateIDs, err := boundedOllamaCandidates(candidates)
	if err != nil {
		return nil, err
	}
	prompt, err := buildOllamaSourceQualityPrompt(query, bounded)
	if err != nil {
		return nil, err
	}
	body, err := json.Marshal(ollamaGenerateRequest{
		Model:  j.model,
		Prompt: prompt,
		Stream: false,
		Format: ollamaSourceQualitySchema(),
		Options: ollamaGenerateOptions{
			NumPredict:  ollamaNumPredict,
			Temperature: ollamaTemperature,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("marshal Ollama request: %w", err)
	}
	if len(body) > ollamaMaxRequestBytes {
		return nil, fmt.Errorf("Ollama request exceeds %d bytes", ollamaMaxRequestBytes)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, j.baseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build Ollama request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if j.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+j.apiKey)
	}

	resp, err := j.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("call Ollama: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("Ollama returned HTTP %d", resp.StatusCode)
	}
	responseBody, err := readOllamaResponse(resp.Body)
	if err != nil {
		return nil, err
	}

	envelope, err := decodeOllamaGenerateEnvelope(responseBody)
	if err != nil {
		return nil, fmt.Errorf("decode Ollama envelope: %w", err)
	}
	if !*envelope.Done {
		return nil, fmt.Errorf("Ollama response was not complete")
	}
	var output ollamaSourceQualityOutput
	if err := decodeOllamaStrictJSON([]byte(*envelope.Response), &output); err != nil {
		return nil, fmt.Errorf("decode Ollama source-quality output: %w", err)
	}
	return validateOllamaJudgments(output.Judgments, candidateIDs)
}

type ollamaGenerateRequest struct {
	Model   string                 `json:"model"`
	Prompt  string                 `json:"prompt"`
	Stream  bool                   `json:"stream"`
	Format  map[string]interface{} `json:"format"`
	Options ollamaGenerateOptions  `json:"options"`
}

type ollamaGenerateOptions struct {
	NumPredict  int     `json:"num_predict"`
	Temperature float64 `json:"temperature"`
}

// The generate endpoint evolves independently from the strict model-output
// contract. Decode only the required transport fields so documented additions
// such as thinking/logprobs, and future provider fields, remain compatible.
type ollamaGenerateResponse struct {
	Response *string `json:"response"`
	Done     *bool   `json:"done"`
}

type ollamaPrompt struct {
	Instruction string                  `json:"instruction"`
	Query       string                  `json:"query"`
	Candidates  []ollamaPromptCandidate `json:"candidates"`
}

type ollamaPromptCandidate struct {
	CandidateID   string              `json:"candidateId"`
	Provider      string              `json:"provider"`
	SourceID      string              `json:"sourceId"`
	SourceURL     string              `json:"sourceUrl"`
	Title         string              `json:"title"`
	Artist        string              `json:"artist"`
	Uploader      string              `json:"uploader"`
	DurationMs    int                 `json:"durationMs"`
	Downloadable  bool                `json:"downloadable"`
	MetadataHints map[string][]string `json:"metadataHints,omitempty"`
}

type ollamaSourceQualityOutput struct {
	Judgments []ollamaSourceQualityJudgment `json:"judgments"`
}

type ollamaSourceQualityJudgment struct {
	CandidateID string                    `json:"candidateId"`
	Quality     *ollamaSourceQualityValue `json:"quality"`
}

// The model shape deliberately omits provenance and source URLs. Provenance is
// assigned only after strict validation by this adapter.
type ollamaSourceQualityValue struct {
	Score          *int     `json:"score"`
	Classification *string  `json:"classification"`
	Recommendation *string  `json:"recommendation"`
	Confidence     *float64 `json:"confidence"`
	Reasons        []string `json:"reasons,omitempty"`
	Warnings       []string `json:"warnings,omitempty"`
}

func buildOllamaSourceQualityPrompt(query string, candidates []ollamaPromptCandidate) (string, error) {
	prompt, err := json.Marshal(ollamaPrompt{
		Instruction: "Judge only the supplied candidates. sourceUrl is an inert hint and must never be returned. Return exactly the JSON object required by the response schema; do not invent candidate IDs or provenance.",
		Query:       limitOllamaString(query, ollamaMaxQueryBytes),
		Candidates:  candidates,
	})
	if err != nil {
		return "", fmt.Errorf("marshal Ollama prompt: %w", err)
	}
	return string(prompt), nil
}

func boundedOllamaCandidates(candidates []SourceQualityCandidateFeature) ([]ollamaPromptCandidate, map[string]struct{}, error) {
	limit := len(candidates)
	if limit > ollamaMaxCandidates {
		limit = ollamaMaxCandidates
	}
	bounded := make([]ollamaPromptCandidate, 0, limit)
	ids := make(map[string]struct{}, limit)
	for _, candidate := range candidates[:limit] {
		if candidate.CandidateID == "" || len(candidate.CandidateID) > ollamaMaxCandidateIDBytes {
			return nil, nil, fmt.Errorf("invalid candidateId")
		}
		if _, exists := ids[candidate.CandidateID]; exists {
			return nil, nil, fmt.Errorf("duplicate candidateId %q", candidate.CandidateID)
		}
		ids[candidate.CandidateID] = struct{}{}
		bounded = append(bounded, ollamaPromptCandidate{
			CandidateID:   candidate.CandidateID,
			Provider:      limitOllamaString(candidate.Provider, ollamaMaxFeatureStringBytes),
			SourceID:      limitOllamaString(candidate.SourceID, ollamaMaxFeatureStringBytes),
			SourceURL:     limitOllamaString(candidate.SourceURL, ollamaMaxFeatureStringBytes),
			Title:         limitOllamaString(candidate.Title, ollamaMaxFeatureStringBytes),
			Artist:        limitOllamaString(candidate.Artist, ollamaMaxFeatureStringBytes),
			Uploader:      limitOllamaString(candidate.Uploader, ollamaMaxFeatureStringBytes),
			DurationMs:    candidate.DurationMs,
			Downloadable:  candidate.Downloadable,
			MetadataHints: boundedOllamaHints(candidate.MetadataHints),
		})
	}
	return bounded, ids, nil
}

func boundedOllamaHints(hints map[string]interface{}) map[string][]string {
	if len(hints) == 0 {
		return nil
	}
	keys := make([]string, 0, len(hints))
	for key := range hints {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	bounded := make(map[string][]string, minInt(len(keys), ollamaMaxMetadataHints))
	for _, originalKey := range keys {
		if len(bounded) == ollamaMaxMetadataHints {
			break
		}
		key := limitOllamaString(originalKey, ollamaMaxHintKeyBytes)
		if key == "" {
			continue
		}
		values := ollamaHintStrings(hints[originalKey])
		if len(values) > 0 {
			bounded[key] = values
		}
	}
	if len(bounded) == 0 {
		return nil
	}
	return bounded
}

func ollamaHintStrings(value interface{}) []string {
	var raw []string
	switch typed := value.(type) {
	case string:
		raw = []string{typed}
	case []string:
		raw = typed
	case []interface{}:
		for _, item := range typed {
			if text, ok := item.(string); ok {
				raw = append(raw, text)
			}
		}
	}
	values := make([]string, 0, minInt(len(raw), ollamaMaxHintValues))
	for _, value := range raw {
		if len(values) == ollamaMaxHintValues {
			break
		}
		value = limitOllamaString(value, ollamaMaxHintValueBytes)
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}

func ollamaSourceQualitySchema() map[string]interface{} {
	return map[string]interface{}{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"judgments"},
		"properties": map[string]interface{}{
			"judgments": map[string]interface{}{
				"type": "array", "minItems": 1, "maxItems": ollamaMaxJudgments,
				"items": map[string]interface{}{
					"type": "object", "additionalProperties": false, "required": []string{"candidateId", "quality"},
					"properties": map[string]interface{}{
						"candidateId": map[string]interface{}{"type": "string", "minLength": 1, "maxLength": ollamaMaxCandidateIDBytes},
						"quality": map[string]interface{}{
							"type": "object", "additionalProperties": false,
							"required": []string{"score", "classification", "recommendation", "confidence"},
							"properties": map[string]interface{}{
								"score":          map[string]interface{}{"type": "integer", "minimum": 0, "maximum": 100},
								"classification": map[string]interface{}{"type": "string", "enum": ollamaClassifications()},
								"recommendation": map[string]interface{}{"type": "string", "enum": ollamaRecommendations()},
								"confidence":     map[string]interface{}{"type": "number", "minimum": 0, "maximum": 1},
								"reasons":        map[string]interface{}{"type": "array", "maxItems": ollamaMaxReasons, "items": map[string]interface{}{"type": "string", "maxLength": ollamaMaxReasonBytes}},
								"warnings":       map[string]interface{}{"type": "array", "maxItems": ollamaMaxWarnings, "items": map[string]interface{}{"type": "string", "maxLength": ollamaMaxWarningBytes}},
							},
						},
					},
				},
			},
		},
	}
}

func ollamaClassifications() []string {
	return []string{SourceQualityOfficialAudio, SourceQualityTopicAudio, SourceQualityArtistUpload, SourceQualityMusicVideo, SourceQualityVisualizer, SourceQualityLive, SourceQualityLyricVideo, SourceQualityInterview, SourceQualityCover, SourceQualityRemix, SourceQualityAlteredAudio, SourceQualityDirectURL, SourceQualityUnknown}
}

func ollamaRecommendations() []string {
	return []string{SourceQualityPreferred, SourceQualityAcceptable, SourceQualityReview, SourceQualityAvoid}
}

func readOllamaResponse(body io.Reader) ([]byte, error) {
	value, err := io.ReadAll(io.LimitReader(body, ollamaMaxResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read Ollama response: %w", err)
	}
	if len(value) > ollamaMaxResponseBytes {
		return nil, fmt.Errorf("Ollama response exceeds %d bytes", ollamaMaxResponseBytes)
	}
	return value, nil
}

func decodeOllamaGenerateEnvelope(value []byte) (ollamaGenerateResponse, error) {
	var envelope ollamaGenerateResponse
	if err := decodeOllamaJSON(value, &envelope, false); err != nil {
		return ollamaGenerateResponse{}, err
	}
	if envelope.Response == nil || envelope.Done == nil {
		return ollamaGenerateResponse{}, fmt.Errorf("missing required response or done")
	}
	return envelope, nil
}

// decodeOllamaStrictJSON keeps the model-produced schema closed while the
// provider envelope stays forward-compatible.
func decodeOllamaStrictJSON(value []byte, target interface{}) error {
	return decodeOllamaJSON(value, target, true)
}

func decodeOllamaJSON(value []byte, target interface{}, disallowUnknownFields bool) error {
	decoder := json.NewDecoder(bytes.NewReader(value))
	if disallowUnknownFields {
		decoder.DisallowUnknownFields()
	}
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return fmt.Errorf("unexpected trailing JSON")
		}
		return err
	}
	return nil
}

func validateOllamaJudgments(modelJudgments []ollamaSourceQualityJudgment, candidateIDs map[string]struct{}) ([]SourceQualityJudgment, error) {
	if len(modelJudgments) == 0 || len(modelJudgments) > ollamaMaxJudgments {
		return nil, fmt.Errorf("invalid judgment count %d", len(modelJudgments))
	}
	seen := make(map[string]struct{}, len(modelJudgments))
	judgments := make([]SourceQualityJudgment, 0, len(modelJudgments))
	for index, judgment := range modelJudgments {
		if judgment.CandidateID == "" {
			return nil, fmt.Errorf("judgment %d has empty candidateId", index)
		}
		if _, exists := candidateIDs[judgment.CandidateID]; !exists {
			return nil, fmt.Errorf("judgment %d has unknown candidateId %q", index, judgment.CandidateID)
		}
		if _, exists := seen[judgment.CandidateID]; exists {
			return nil, fmt.Errorf("judgment %d duplicates candidateId %q", index, judgment.CandidateID)
		}
		seen[judgment.CandidateID] = struct{}{}
		if judgment.Quality == nil || judgment.Quality.Score == nil || judgment.Quality.Classification == nil || judgment.Quality.Recommendation == nil || judgment.Quality.Confidence == nil {
			return nil, fmt.Errorf("judgment %d has incomplete quality", index)
		}
		quality := judgment.Quality
		if *quality.Score < 0 || *quality.Score > 100 || !knownSourceQualityClassification(*quality.Classification) || !knownSourceQualityRecommendation(*quality.Recommendation) || *quality.Confidence < 0 || *quality.Confidence > 1 {
			return nil, fmt.Errorf("judgment %d has invalid quality", index)
		}
		if err := validateOllamaStrings(quality.Reasons, ollamaMaxReasons, ollamaMaxReasonBytes, "reasons"); err != nil {
			return nil, fmt.Errorf("judgment %d: %w", index, err)
		}
		if err := validateOllamaStrings(quality.Warnings, ollamaMaxWarnings, ollamaMaxWarningBytes, "warnings"); err != nil {
			return nil, fmt.Errorf("judgment %d: %w", index, err)
		}
		judgments = append(judgments, SourceQualityJudgment{CandidateID: judgment.CandidateID, Quality: SourceQuality{Score: *quality.Score, Classification: *quality.Classification, Recommendation: *quality.Recommendation, Confidence: *quality.Confidence, Reasons: quality.Reasons, Warnings: quality.Warnings, Provenance: ollamaSourceQualityProvenance}})
	}
	return judgments, nil
}

func validateOllamaStrings(values []string, maxItems, maxBytes int, field string) error {
	if len(values) > maxItems {
		return fmt.Errorf("%s has too many values", field)
	}
	for _, value := range values {
		if len(value) > maxBytes {
			return fmt.Errorf("%s value exceeds %d bytes", field, maxBytes)
		}
	}
	return nil
}

func limitOllamaString(value string, maxBytes int) string {
	if len(value) <= maxBytes {
		return value
	}
	return value[:maxBytes]
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}
