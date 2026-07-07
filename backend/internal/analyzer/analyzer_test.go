package analyzer

import (
	"context"
	"encoding/json"
	"testing"
)

func TestFixtureClientReturnsDJAnalysisArtifacts(t *testing.T) {
	client := NewFixtureClient("testdata/synthetic_analysis.json")

	result, err := client.Analyze(context.Background(), Request{
		TrackID:    42,
		StorageKey: "tracks/fixture/synthetic.wav",
		DurationMs: 197500,
	})
	if err != nil {
		t.Fatalf("Analyze returned error: %v", err)
	}
	if result.SchemaVersion != SchemaVersion {
		t.Fatalf("schema version = %d, want %d", result.SchemaVersion, SchemaVersion)
	}

	var summary map[string]any
	if err := json.Unmarshal(result.SummaryJSON, &summary); err != nil {
		t.Fatalf("summary json invalid: %v", err)
	}
	for _, key := range []string{"bpm", "beat_grid", "downbeats", "key", "camelot", "energy", "genre_hints", "tag_hints", "loudness", "true_peak", "waveform", "transients", "silence", "intro", "outro", "trim", "sections", "cue_candidates", "duration_sanity"} {
		if _, ok := summary[key]; !ok {
			t.Fatalf("summary missing %q: %s", key, result.SummaryJSON)
		}
	}
	beatGrid := summary["beat_grid"].(map[string]any)
	if beats, ok := beatGrid["beats_ms"].([]any); !ok || len(beats) == 0 {
		t.Fatalf("beat_grid missing beats_ms: %#v", beatGrid)
	}
	waveform := summary["waveform"].(map[string]any)
	if resolutions, ok := waveform["resolutions"].([]any); !ok || len(resolutions) < 2 {
		t.Fatalf("waveform missing multi-resolution summaries: %#v", waveform)
	}
	if _, ok := waveform["spectral_bands"].(map[string]any); !ok {
		t.Fatalf("waveform missing spectral band summaries: %#v", waveform)
	}

	var artifacts map[string]any
	if err := json.Unmarshal(result.ArtifactsJSON, &artifacts); err != nil {
		t.Fatalf("artifacts json invalid: %v", err)
	}
	for _, key := range []string{"source", "waveforms", "spectral_bands", "beat_grid", "markers"} {
		if _, ok := artifacts[key]; !ok {
			t.Fatalf("artifacts missing %q: %s", key, result.ArtifactsJSON)
		}
	}

	var provenance map[string]any
	if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance json invalid: %v", err)
	}
	if provenance["analyzer"] != "fixture" || provenance["analyzer_version"] != "fixture-v2" {
		t.Fatalf("provenance = %#v, want fixture fixture-v2", provenance)
	}
}

func TestFixtureClientDefaultUsesEmbeddedSyntheticContract(t *testing.T) {
	client := NewFixtureClient("")
	result, err := client.Analyze(context.Background(), Request{TrackID: 42, StorageKey: "tracks/fixture/song.wav"})
	if err != nil {
		t.Fatalf("Analyze with embedded default returned error: %v", err)
	}
	if result.SchemaVersion != SchemaVersion {
		t.Fatalf("schema version = %d, want %d", result.SchemaVersion, SchemaVersion)
	}
	if len(result.SummaryJSON) == 0 || len(result.ArtifactsJSON) == 0 || len(result.ProvenanceJSON) == 0 {
		t.Fatalf("embedded default returned empty contract payload: %#v", result)
	}
}
