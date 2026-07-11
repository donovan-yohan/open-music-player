package analyzer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	defaultServiceTimeout    = 90 * time.Second
	maxAnalyzerResponseBytes = 8 << 20
)

// ServiceConfig controls the optional out-of-process analyzer integration.
// A nil service client means analysis is disabled; callers must not enqueue
// pending rows unless a client exists.
type ServiceConfig struct {
	Enabled   bool
	BaseURL   string
	AuthToken string
	Timeout   time.Duration
	Client    *http.Client
}

// ServiceClient calls an external analyzer service that implements the #90
// analysis contract over HTTP.
type ServiceClient struct {
	endpoint       string
	healthEndpoint string
	authToken      string
	client         *http.Client
}

// Info is the versioned identity advertised by the analyzer health endpoint.
// It is deliberately separate from analysis provenance so startup maintenance
// can avoid invalidating rows when the analyzer is unavailable.
type Info struct {
	Status          string `json:"status"`
	Analyzer        string `json:"analyzer"`
	AnalyzerVersion string `json:"analyzer_version"`
	TempoModel      string `json:"tempo_model"`
	KeyModel        string `json:"key_model"`
}

// NewServiceClient returns nil when the optional analyzer is disabled. When it
// is enabled, BaseURL is required and points at the analyzer service root; this
// client posts analysis requests to /analyze below that root.
func NewServiceClient(config ServiceConfig) (*ServiceClient, error) {
	baseURL := strings.TrimSpace(config.BaseURL)
	if !config.Enabled {
		return nil, nil
	}
	if baseURL == "" {
		return nil, errors.New("analyzer base URL is required when analyzer is enabled")
	}
	endpoint, err := analyzerEndpoint(baseURL)
	if err != nil {
		return nil, err
	}
	healthEndpoint, err := analyzerHealthEndpoint(baseURL)
	if err != nil {
		return nil, err
	}
	timeout := config.Timeout
	if timeout <= 0 {
		timeout = defaultServiceTimeout
	}
	client := config.Client
	if client == nil {
		client = &http.Client{Timeout: timeout}
	} else if client.Timeout == 0 {
		copy := *client
		copy.Timeout = timeout
		client = &copy
	}
	return &ServiceClient{
		endpoint:       endpoint,
		healthEndpoint: healthEndpoint,
		authToken:      strings.TrimSpace(config.AuthToken),
		client:         client,
	}, nil
}

func analyzerEndpoint(baseURL string) (string, error) {
	return analyzerServiceEndpoint(baseURL, "analyze")
}

func analyzerHealthEndpoint(baseURL string) (string, error) {
	return analyzerServiceEndpoint(baseURL, "health")
}

func analyzerServiceEndpoint(baseURL, suffix string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("parse analyzer base URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("analyzer base URL must include scheme and host: %q", baseURL)
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/" + suffix
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

// Info returns the analyzer's health/version identity for startup reconciliation.
func (c *ServiceClient) Info(ctx context.Context) (Info, error) {
	if c == nil || c.client == nil || c.healthEndpoint == "" {
		return Info{}, errors.New("analyzer service client is unavailable")
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.healthEndpoint, nil)
	if err != nil {
		return Info{}, fmt.Errorf("build analyzer health request: %w", err)
	}
	httpReq.Header.Set("Accept", "application/json")
	if c.authToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.authToken)
	}
	resp, err := c.client.Do(httpReq)
	if err != nil {
		return Info{}, fmt.Errorf("call analyzer health endpoint: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxAnalyzerResponseBytes+1))
	if err != nil {
		return Info{}, fmt.Errorf("read analyzer health response: %w", err)
	}
	if len(body) > maxAnalyzerResponseBytes {
		return Info{}, fmt.Errorf("analyzer health response exceeds %d byte limit", maxAnalyzerResponseBytes)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return Info{}, fmt.Errorf("analyzer health endpoint returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var info Info
	if err := json.Unmarshal(body, &info); err != nil {
		return Info{}, fmt.Errorf("parse analyzer health response: %w", err)
	}
	if strings.TrimSpace(info.Analyzer) == "" || strings.TrimSpace(info.AnalyzerVersion) == "" {
		return Info{}, errors.New("analyzer health response missing analyzer identity")
	}
	if !strings.EqualFold(strings.TrimSpace(info.Status), "healthy") {
		return Info{}, fmt.Errorf("analyzer health response status is %q", info.Status)
	}
	if strings.TrimSpace(info.TempoModel) == "" || strings.TrimSpace(info.KeyModel) == "" {
		return Info{}, errors.New("analyzer health response missing model identity")
	}
	return info, nil
}

func (c *ServiceClient) Analyze(ctx context.Context, req Request) (*Result, error) {
	schemaVersion := req.SchemaVersion
	if schemaVersion <= 0 {
		schemaVersion = SchemaVersion
	}
	payload, err := json.Marshal(serviceRequest{
		SchemaVersion:           schemaVersion,
		TrackID:                 req.TrackID,
		StorageKey:              req.StorageKey,
		SourceURL:               req.SourceURL,
		SourceType:              req.SourceType,
		DurationMs:              req.DurationMs,
		Title:                   req.Title,
		Artist:                  req.Artist,
		ExpectedAnalyzer:        strings.TrimSpace(req.ExpectedAnalyzer),
		ExpectedAnalyzerVersion: strings.TrimSpace(req.ExpectedAnalyzerVersion),
	})
	if err != nil {
		return nil, fmt.Errorf("encode analyzer request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("build analyzer request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("X-OpenMusicPlayer-Analysis-Schema", fmt.Sprint(SchemaVersion))
	if c.authToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("call analyzer service: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxAnalyzerResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read analyzer response: %w", err)
	}
	if len(body) > maxAnalyzerResponseBytes {
		return nil, fmt.Errorf("analyzer service response exceeds %d byte limit", maxAnalyzerResponseBytes)
	}
	if resp.StatusCode == http.StatusUnsupportedMediaType || resp.StatusCode == http.StatusUnprocessableEntity {
		return nil, fmt.Errorf("%w: analyzer service returned %d: %s", ErrUnsupported, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("analyzer service returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return nil, errors.New("analyzer service returned empty response")
	}

	var decoded serviceResponse
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, fmt.Errorf("parse analyzer response: %w", err)
	}
	result := decoded.result()
	if len(bytes.TrimSpace(result.SummaryJSON)) == 0 {
		return nil, errors.New("analyzer response missing summary")
	}
	if result.SchemaVersion <= 0 {
		result.SchemaVersion = SchemaVersion
	}
	if err := ValidateResultIdentity(req, result); err != nil {
		return nil, err
	}
	return result, nil
}

type serviceRequest struct {
	SchemaVersion           int    `json:"schema_version"`
	TrackID                 int64  `json:"track_id"`
	StorageKey              string `json:"storage_key,omitempty"`
	SourceURL               string `json:"source_url,omitempty"`
	SourceType              string `json:"source_type,omitempty"`
	DurationMs              int    `json:"duration_ms,omitempty"`
	Title                   string `json:"title,omitempty"`
	Artist                  string `json:"artist,omitempty"`
	ExpectedAnalyzer        string `json:"expected_analyzer,omitempty"`
	ExpectedAnalyzerVersion string `json:"expected_analyzer_version,omitempty"`
}

type serviceResponse struct {
	SchemaVersion  int             `json:"schema_version"`
	Summary        json.RawMessage `json:"summary"`
	SummaryJSON    json.RawMessage `json:"summary_json"`
	Artifacts      json.RawMessage `json:"artifacts"`
	ArtifactsJSON  json.RawMessage `json:"artifacts_json"`
	Provenance     json.RawMessage `json:"provenance"`
	ProvenanceJSON json.RawMessage `json:"provenance_json"`
}

func (r serviceResponse) result() *Result {
	return &Result{
		SchemaVersion:  r.SchemaVersion,
		SummaryJSON:    firstRawJSON(r.SummaryJSON, r.Summary),
		ArtifactsJSON:  firstRawJSON(r.ArtifactsJSON, r.Artifacts, json.RawMessage(`{}`)),
		ProvenanceJSON: firstRawJSON(r.ProvenanceJSON, r.Provenance, json.RawMessage(`{}`)),
	}
}

func firstRawJSON(values ...json.RawMessage) json.RawMessage {
	for _, value := range values {
		if len(bytes.TrimSpace(value)) > 0 {
			return value
		}
	}
	return nil
}
