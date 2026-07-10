package db

import (
	"encoding/json"
	"testing"
)

func TestProjectCompactAnalysisDeepMergesAndRejectsMalformedOverrides(t *testing.T) {
	merged, overrides := projectCompactAnalysis(
		json.RawMessage(`{
			"bpm":{"value":120,"confidence":0.8},
			"beat_grid":{"bpm":120,"offset_ms":25,"beats_ms":[0,500,1000]},
			"downbeats":{"positions_ms":[0,2000]},
			"key":{"value":"G minor"},
			"waveform":{"peaks":[0.1,0.9]}
		}`),
		json.RawMessage(`{
			"bpm":{"value":"not-a-number"},
			"beat_grid":{"bpm":128,"beats_ms":"not-an-array"},
			"key":{"value":"A minor"},
			"waveform":{"peaks":[1,1,1]}
		}`),
	)

	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatalf("decode merged compact analysis: %v", err)
	}
	if got := document["bpm"].(map[string]any)["value"]; got != float64(120) {
		t.Fatalf("bpm = %#v, want valid analyzer value 120", got)
	}
	beatGrid := document["beat_grid"].(map[string]any)
	if got := beatGrid["bpm"]; got != float64(128) {
		t.Fatalf("beat-grid bpm = %#v, want override 128", got)
	}
	if got := len(beatGrid["beats_ms"].([]any)); got != 3 {
		t.Fatalf("beat positions = %d, want preserved analyzer positions", got)
	}
	if _, ok := document["waveform"]; ok {
		t.Fatal("merged compact analysis leaked waveform")
	}

	var overrideDocument map[string]any
	if err := json.Unmarshal(overrides, &overrideDocument); err != nil {
		t.Fatalf("decode compact overrides: %v", err)
	}
	if _, ok := overrideDocument["bpm"]; ok {
		t.Fatal("malformed BPM override should be omitted")
	}
	if _, ok := overrideDocument["waveform"]; ok {
		t.Fatal("compact overrides leaked waveform")
	}
}

func TestProjectCompactAnalysisCapsTimingArrays(t *testing.T) {
	beats := make([]int64, maxCompactBeatPositions+500)
	for index := range beats {
		beats[index] = int64(index * 250)
	}
	downbeats := make([]int64, maxCompactDownbeatPositions+500)
	for index := range downbeats {
		downbeats[index] = int64(index * 1000)
	}
	payload, err := json.Marshal(map[string]any{
		"beat_grid": map[string]any{"beats_ms": beats},
		"downbeats": map[string]any{"positions_ms": downbeats},
	})
	if err != nil {
		t.Fatalf("encode oversized analysis: %v", err)
	}

	merged, _ := projectCompactAnalysis(payload, nil)
	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatalf("decode bounded analysis: %v", err)
	}
	if got := len(document["beat_grid"].(map[string]any)["beats_ms"].([]any)); got != maxCompactBeatPositions {
		t.Fatalf("beat positions = %d, want cap %d", got, maxCompactBeatPositions)
	}
	if got := len(document["downbeats"].(map[string]any)["positions_ms"].([]any)); got != maxCompactDownbeatPositions {
		t.Fatalf("downbeat positions = %d, want cap %d", got, maxCompactDownbeatPositions)
	}
}
