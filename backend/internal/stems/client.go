package stems

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
	// defaultServiceTimeout matches STEMS_TIMEOUT_MS. htdemucs runs at roughly
	// realtime on the x86 trickle host, so a long track legitimately occupies
	// this call for many minutes.
	defaultServiceTimeout = 30 * time.Minute
	// maxStemsResponseBytes bounds the manifest, which carries base64 energy
	// matrices for every channel. Audio bytes never travel over this call.
	maxStemsResponseBytes = 16 << 20
)

var (
	// ErrWorkerIdentityMismatch is the worker's 409: it is not the worker (or
	// version) the caller asked for. Callers must not persist such a result.
	ErrWorkerIdentityMismatch = errors.New("stems worker identity mismatch")
	// ErrUnsupported means the worker refused this source, not that it failed.
	ErrUnsupported = errors.New("stems worker cannot separate this source")
)

// ServiceConfig controls the optional out-of-process stems worker integration.
// A nil client means separation is disabled; callers must not create pending
// track_stems rows without one.
type ServiceConfig struct {
	Enabled   bool
	BaseURL   string
	AuthToken string
	Timeout   time.Duration
	Client    *http.Client
}

// ServiceClient calls the stems worker over HTTP.
//
// CRITIC refinement (docs/stems5-spec.md): a 30-minute synchronous POST
// /separate is far more fragile than the analyzer's 90 s call — connection
// resets, proxy idle timeouts, and tailnet hops all sit in the failure path. The
// mitigation is that this call is safely retryable rather than reliable: the
// Postgres track_stems row is the durable authority, RecoverInFlight resets an
// abandoned `separating` row back to pending after a restart, and StoreResult's
// status='separating' + expected_worker guard turns a duplicate manifest
// delivery into a no-op instead of a double-write. Switching to submit/poll is
// the follow-up before STEMS_BASE_URL points at a remote (server-mac) worker.
type ServiceClient struct {
	endpoint       string
	healthEndpoint string
	authToken      string
	client         *http.Client
}

// Info is the versioned identity advertised by the worker health endpoint.
type Info struct {
	Status           string `json:"status"`
	Worker           string `json:"worker"`
	WorkerVersion    string `json:"worker_version"`
	ChannelSet       string `json:"channel_set"`
	StemModelVersion string `json:"stem_model_version"`
	DemucsVersion    string `json:"demucs_version"`
	CheckpointSHA256 string `json:"checkpoint_sha256"`
}

// Request is the POST /separate body.
type Request struct {
	SchemaVersion         int    `json:"schema_version"`
	TrackID               int64  `json:"track_id"`
	StorageKey            string `json:"storage_key"`
	ChannelSet            string `json:"channel_set"`
	ExpectedWorker        string `json:"expected_worker,omitempty"`
	ExpectedWorkerVersion string `json:"expected_worker_version,omitempty"`
}

// Manifest is the worker's 200 response: the artifact manifest that gets
// persisted into track_stems. Per-stem energy curves live inside Artifacts and
// are delivered by GET /api/v1/tracks/{id}/stems — the stems service never
// writes track_analysis, which stays single-writer (the analyzer).
type Manifest struct {
	SchemaVersion    int             `json:"schema_version"`
	TrackID          int64           `json:"track_id"`
	ChannelSet       string          `json:"channel_set"`
	StemModelVersion string          `json:"stem_model_version"`
	SourceFileHash   string          `json:"source_file_hash"`
	SourceStorageKey string          `json:"source_storage_key"`
	DurationMs       int64           `json:"duration_ms"`
	Artifacts        json.RawMessage `json:"artifacts"`
	Provenance       json.RawMessage `json:"provenance"`
}

// ProvenanceIdentity extracts the worker identity the manifest actually claims,
// which is what the repository cross-checks before storing a result.
func (m *Manifest) ProvenanceIdentity() (string, string, error) {
	if m == nil {
		return "", "", errors.New("stems manifest is nil")
	}
	var provenance struct {
		Worker        string `json:"worker"`
		WorkerVersion string `json:"worker_version"`
	}
	if len(bytes.TrimSpace(m.Provenance)) == 0 {
		return "", "", errors.New("stems manifest missing provenance")
	}
	if err := json.Unmarshal(m.Provenance, &provenance); err != nil {
		return "", "", fmt.Errorf("parse stems manifest provenance: %w", err)
	}
	if strings.TrimSpace(provenance.Worker) == "" || strings.TrimSpace(provenance.WorkerVersion) == "" {
		return "", "", errors.New("stems manifest provenance missing worker identity")
	}
	return provenance.Worker, provenance.WorkerVersion, nil
}

// NewServiceClient returns nil when separation is disabled. When enabled,
// BaseURL is required and points at the worker root; this client posts to
// /separate and reads /health below that root.
func NewServiceClient(config ServiceConfig) (*ServiceClient, error) {
	baseURL := strings.TrimSpace(config.BaseURL)
	if !config.Enabled {
		return nil, nil
	}
	if baseURL == "" {
		return nil, errors.New("stems base URL is required when stems are enabled")
	}
	endpoint, err := stemsServiceEndpoint(baseURL, "separate")
	if err != nil {
		return nil, err
	}
	healthEndpoint, err := stemsServiceEndpoint(baseURL, "health")
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
		clone := *client
		clone.Timeout = timeout
		client = &clone
	}
	return &ServiceClient{
		endpoint:       endpoint,
		healthEndpoint: healthEndpoint,
		authToken:      strings.TrimSpace(config.AuthToken),
		client:         client,
	}, nil
}

func stemsServiceEndpoint(baseURL, suffix string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("parse stems base URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("stems base URL must include scheme and host: %q", baseURL)
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/" + suffix
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

// Info returns the worker's health/version identity for startup reconciliation.
func (c *ServiceClient) Info(ctx context.Context) (Info, error) {
	if c == nil || c.client == nil || c.healthEndpoint == "" {
		return Info{}, errors.New("stems service client is unavailable")
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.healthEndpoint, nil)
	if err != nil {
		return Info{}, fmt.Errorf("build stems health request: %w", err)
	}
	httpReq.Header.Set("Accept", "application/json")
	if c.authToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.authToken)
	}
	resp, err := c.client.Do(httpReq)
	if err != nil {
		return Info{}, fmt.Errorf("call stems health endpoint: %w", err)
	}
	defer resp.Body.Close()
	body, err := readBoundedBody(resp.Body)
	if err != nil {
		return Info{}, fmt.Errorf("read stems health response: %w", err)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return Info{}, fmt.Errorf("stems health endpoint returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var info Info
	if err := json.Unmarshal(body, &info); err != nil {
		return Info{}, fmt.Errorf("parse stems health response: %w", err)
	}
	if strings.TrimSpace(info.Worker) == "" || strings.TrimSpace(info.WorkerVersion) == "" {
		return Info{}, errors.New("stems health response missing worker identity")
	}
	if !strings.EqualFold(strings.TrimSpace(info.Status), "healthy") {
		return Info{}, fmt.Errorf("stems health response status is %q", info.Status)
	}
	if strings.TrimSpace(info.ChannelSet) == "" || strings.TrimSpace(info.StemModelVersion) == "" {
		return Info{}, errors.New("stems health response missing model identity")
	}
	return info, nil
}

// Separate runs one separation and returns the artifact manifest.
func (c *ServiceClient) Separate(ctx context.Context, req Request) (*Manifest, error) {
	if c == nil || c.client == nil || c.endpoint == "" {
		return nil, errors.New("stems service client is unavailable")
	}
	schemaVersion := req.SchemaVersion
	if schemaVersion <= 0 {
		schemaVersion = SchemaVersion
	}
	payload, err := json.Marshal(Request{
		SchemaVersion:         schemaVersion,
		TrackID:               req.TrackID,
		StorageKey:            strings.TrimSpace(req.StorageKey),
		ChannelSet:            strings.TrimSpace(req.ChannelSet),
		ExpectedWorker:        strings.TrimSpace(req.ExpectedWorker),
		ExpectedWorkerVersion: strings.TrimSpace(req.ExpectedWorkerVersion),
	})
	if err != nil {
		return nil, fmt.Errorf("encode stems request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("build stems request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("X-OpenMusicPlayer-Stems-Schema", fmt.Sprint(SchemaVersion))
	if c.authToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("call stems service: %w", err)
	}
	defer resp.Body.Close()
	body, err := readBoundedBody(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read stems response: %w", err)
	}
	if resp.StatusCode == http.StatusConflict {
		return nil, fmt.Errorf("%w: stems service returned 409: %s", ErrWorkerIdentityMismatch, strings.TrimSpace(string(body)))
	}
	if resp.StatusCode == http.StatusUnsupportedMediaType || resp.StatusCode == http.StatusUnprocessableEntity {
		return nil, fmt.Errorf("%w: stems service returned %d: %s", ErrUnsupported, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("stems service returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return nil, errors.New("stems service returned empty response")
	}

	var manifest Manifest
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(&manifest); err != nil {
		return nil, fmt.Errorf("parse stems response: %w", err)
	}
	if manifest.SchemaVersion <= 0 {
		manifest.SchemaVersion = SchemaVersion
	}
	if len(bytes.TrimSpace(manifest.Artifacts)) == 0 {
		return nil, errors.New("stems response missing artifacts")
	}
	worker, workerVersion, err := manifest.ProvenanceIdentity()
	if err != nil {
		return nil, err
	}
	if expected := strings.TrimSpace(req.ExpectedWorker); expected != "" && expected != worker {
		return nil, fmt.Errorf("%w: worker %q, expected %q", ErrWorkerIdentityMismatch, worker, expected)
	}
	if expected := strings.TrimSpace(req.ExpectedWorkerVersion); expected != "" && expected != workerVersion {
		return nil, fmt.Errorf("%w: worker version %q, expected %q", ErrWorkerIdentityMismatch, workerVersion, expected)
	}
	if channelSet := strings.TrimSpace(req.ChannelSet); channelSet != "" && manifest.ChannelSet != channelSet {
		return nil, fmt.Errorf("stems response channel set %q does not match request %q", manifest.ChannelSet, channelSet)
	}
	if strings.TrimSpace(manifest.StemModelVersion) == "" {
		return nil, errors.New("stems response missing stem model version")
	}
	return &manifest, nil
}

func readBoundedBody(body io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(body, maxStemsResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxStemsResponseBytes {
		return nil, fmt.Errorf("stems service response exceeds %d byte limit", maxStemsResponseBytes)
	}
	return data, nil
}
