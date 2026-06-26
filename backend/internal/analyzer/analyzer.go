package analyzer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

const SchemaVersion = 1

var ErrUnsupported = errors.New("audio analysis unsupported")

type Request struct {
	TrackID       int64
	StorageKey    string
	SourceURL     string
	SourceType    string
	DurationMs    int
	Title         string
	Artist        string
	SchemaVersion int
}

type Result struct {
	SchemaVersion  int             `json:"schema_version"`
	SummaryJSON    json.RawMessage `json:"summary_json"`
	ArtifactsJSON  json.RawMessage `json:"artifacts_json"`
	ProvenanceJSON json.RawMessage `json:"provenance_json"`
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
	if path == "" {
		path = "internal/analyzer/testdata/synthetic_analysis.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read analysis fixture: %w", err)
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
	return &Result{
		SchemaVersion:  fixture.SchemaVersion,
		SummaryJSON:    fixture.Summary,
		ArtifactsJSON:  fixture.Artifacts,
		ProvenanceJSON: fixture.Provenance,
	}, nil
}
