package analyzer

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const SchemaVersion = 1

var ErrUnsupported = errors.New("audio analysis unsupported")

//go:embed testdata/synthetic_analysis.json
var syntheticAnalysisFixture []byte

type Request struct {
	TrackID                 int64
	StorageKey              string
	SourceURL               string
	SourceType              string
	DurationMs              int
	Title                   string
	Artist                  string
	SchemaVersion           int
	ExpectedAnalyzer        string
	ExpectedAnalyzerVersion string
	// Worker-side validation and claim fencing, never part of the HTTP DTO.
	PrivateSource *PrivateSourceProof `json:"-"`
}

type PrivateSourceProof struct {
	SHA256     string
	ByteLength int64
	Claim      string
}

type Result struct {
	SchemaVersion   int             `json:"schema_version"`
	SummaryJSON     json.RawMessage `json:"summary_json"`
	ArtifactsJSON   json.RawMessage `json:"artifacts_json"`
	ProvenanceJSON  json.RawMessage `json:"provenance_json"`
	Analyzer        string          `json:"-"`
	AnalyzerVersion string          `json:"-"`
}

type Client interface {
	Analyze(ctx context.Context, req Request) (*Result, error)
}

type FixtureClient struct {
	fixturePath string
}

func NewFixtureClient(fixturePath string) *FixtureClient {
	return &FixtureClient{fixturePath: fixturePath}
}

func (c *FixtureClient) Analyze(ctx context.Context, req Request) (*Result, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}
	if req.StorageKey == "" && req.SourceURL == "" {
		return nil, fmt.Errorf("%w: missing storage key/source url", ErrUnsupported)
	}
	path := c.fixturePath
	data := syntheticAnalysisFixture
	if path != "" {
		var err error
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read analysis fixture: %w", err)
		}
	}
	var fixture struct {
		SchemaVersion int             `json:"schema_version"`
		Summary       json.RawMessage `json:"summary"`
		Artifacts     json.RawMessage `json:"artifacts"`
		Provenance    json.RawMessage `json:"provenance"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		return nil, fmt.Errorf("parse analysis fixture: %w", err)
	}
	if fixture.SchemaVersion <= 0 {
		fixture.SchemaVersion = SchemaVersion
	}
	result := &Result{
		SchemaVersion:  fixture.SchemaVersion,
		SummaryJSON:    fixture.Summary,
		ArtifactsJSON:  fixture.Artifacts,
		ProvenanceJSON: fixture.Provenance,
	}
	if err := ValidateResultIdentity(req, result); err != nil {
		return nil, err
	}
	return result, nil
}

func IdentityFromProvenance(raw json.RawMessage) (string, string, error) {
	var provenance struct {
		Analyzer        string `json:"analyzer"`
		AnalyzerVersion string `json:"analyzer_version"`
	}
	if err := json.Unmarshal(raw, &provenance); err != nil {
		return "", "", fmt.Errorf("parse analyzer provenance identity: %w", err)
	}
	return provenance.Analyzer, provenance.AnalyzerVersion, nil
}

// Surrounding whitespace is presentation, not part of either opaque field.
func normalizeIdentity(name, version string) (string, string) {
	return strings.TrimSpace(name), strings.TrimSpace(version)
}

func ValidateResultIdentity(req Request, result *Result) error {
	if result == nil {
		return errors.New("analyzer returned nil result")
	}
	name, version, err := IdentityFromProvenance(result.ProvenanceJSON)
	if err != nil {
		return err
	}
	result.Analyzer, result.AnalyzerVersion = normalizeIdentity(name, version)
	if result.Analyzer == "" || result.AnalyzerVersion == "" {
		return errors.New("analyzer result provenance missing analyzer identity")
	}
	expectedAnalyzer, expectedVersion := normalizeIdentity(req.ExpectedAnalyzer, req.ExpectedAnalyzerVersion)
	if (expectedAnalyzer == "") != (expectedVersion == "") {
		return errors.New("expected analyzer identity requires both name and version")
	}
	if expectedAnalyzer != "" && (result.Analyzer != expectedAnalyzer || result.AnalyzerVersion != expectedVersion) {
		return fmt.Errorf(
			"analyzer result identity %q@%q does not match expected %q@%q",
			result.Analyzer,
			result.AnalyzerVersion,
			expectedAnalyzer,
			expectedVersion,
		)
	}
	// StoreResult decodes identity into a struct again, but startup SQL looks
	// up exact keys. Remove all aliases accepted by encoding/json's Unicode
	// case folding so neither a reparse nor JSONB key ordering can change it.
	var provenance map[string]json.RawMessage
	if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
		return fmt.Errorf("parse analyzer provenance: %w", err)
	}
	for key := range provenance {
		if strings.EqualFold(key, "analyzer") || strings.EqualFold(key, "analyzer_version") {
			delete(provenance, key)
		}
	}
	provenance["analyzer"], _ = json.Marshal(result.Analyzer) // strings always marshal
	provenance["analyzer_version"], _ = json.Marshal(result.AnalyzerVersion)
	result.ProvenanceJSON, err = json.Marshal(provenance)
	if err != nil {
		return fmt.Errorf("encode canonical analyzer provenance: %w", err)
	}
	return nil
}
