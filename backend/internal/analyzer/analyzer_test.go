package analyzer

import (
	"context"
	"encoding/json"
	"testing"
)

func TestFixtureClientReturnsSyntheticContract(t *testing.T) {
	client := NewFixtureClient("testdata/synthetic_analysis.json")
	result, err := client.Analyze(context.Background(), Request{TrackID: 42, StorageKey: "tracks/fixture/song.wav"})
	if err != nil {
		t.Fatalf("Analyze returned error: %v", err)
	}
	if result.SchemaVersion != SchemaVersion {
		t.Fatalf("schema version = %d, want %d", result.SchemaVersion, SchemaVersion)
	}
	var summary map[string]interface{}
	if err := json.Unmarshal(result.SummaryJSON, &summary); err != nil {
		t.Fatalf("summary json invalid: %v", err)
	}
	for _, key := range []string{"bpm", "key", "camelot", "energy", "genre_hints", "tag_hints", "waveform", "transients", "silence", "intro", "outro", "trim", "sections", "cue_candidates"} {
		if _, ok := summary[key]; !ok {
			t.Fatalf("summary missing %s", key)
		}
	}
	bpm, ok := summary["bpm"].(map[string]interface{})
	if !ok {
		t.Fatalf("bpm field has unexpected shape: %#v", summary["bpm"])
	}
	for _, key := range []string{"value", "confidence", "provenance"} {
		if _, ok := bpm[key]; !ok {
			t.Fatalf("bpm missing %s", key)
		}
	}
	var artifacts map[string]interface{}
	if err := json.Unmarshal(result.ArtifactsJSON, &artifacts); err != nil {
		t.Fatalf("artifacts json invalid: %v", err)
	}
	var provenance map[string]interface{}
	if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance json invalid: %v", err)
	}
	if provenance["analyzer"] != "fixture" {
		t.Fatalf("provenance analyzer = %#v, want fixture", provenance["analyzer"])
	}
}
