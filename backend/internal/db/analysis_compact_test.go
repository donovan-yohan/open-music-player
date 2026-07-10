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

func TestProjectCompactAnalysisTrustsManualTimingOverrides(t *testing.T) {
	merged, overrides := projectCompactAnalysis(
		json.RawMessage(`{
			"bpm":{"value":120,"confidence":0.8,"provenance":"analyzer"},
			"beat_grid":{"bpm":120,"confidence":0.8,"beats_ms":[0,500,1000],"provenance":"analyzer"},
			"downbeats":{"positions_ms":[0,2000],"confidence":0.419,"provenance":"analyzer"}
		}`),
		json.RawMessage(`{
			"bpm":{"value":124},
			"beat_grid":{"bpm":124,"beats_ms":[120,604,1088]},
			"downbeats":{"positions_ms":[120,2120]}
		}`),
	)

	for name, payload := range map[string]json.RawMessage{
		"merged":    merged,
		"overrides": overrides,
	} {
		var document map[string]any
		if err := json.Unmarshal(payload, &document); err != nil {
			t.Fatalf("decode %s compact analysis: %v", name, err)
		}
		bpm := document["bpm"].(map[string]any)
		beatGrid := document["beat_grid"].(map[string]any)
		downbeats := document["downbeats"].(map[string]any)
		if got := bpm["confidence"]; got != float64(1) {
			t.Fatalf("%s BPM confidence = %#v, want 1", name, got)
		}
		if got := beatGrid["confidence"]; got != float64(1) {
			t.Fatalf("%s beat-grid confidence = %#v, want 1", name, got)
		}
		if got := downbeats["confidence"]; got != float64(1) {
			t.Fatalf("%s downbeat confidence = %#v, want 1", name, got)
		}
		for field, value := range map[string]any{
			"bpm":       bpm,
			"beat_grid": beatGrid,
			"downbeats": downbeats,
		} {
			if got := value.(map[string]any)["provenance"]; got != manualOverrideProvenance {
				t.Fatalf("%s %s provenance = %#v, want %q", name, field, got, manualOverrideProvenance)
			}
		}
	}
}

func TestProjectCompactAnalysisPreservesUntouchedAnalyzerConfidence(t *testing.T) {
	merged, _ := projectCompactAnalysis(
		json.RawMessage(`{
			"bpm":{"value":120,"confidence":0.8,"provenance":"analyzer"},
			"beat_grid":{"bpm":120,"confidence":0.8,"provenance":"analyzer"},
			"downbeats":{"positions_ms":[0,2000],"confidence":0.419,"provenance":"analyzer"}
		}`),
		nil,
	)

	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatalf("decode compact analysis: %v", err)
	}
	for field, wantConfidence := range map[string]float64{
		"bpm": 0.8, "beat_grid": 0.8, "downbeats": 0.419,
	} {
		value := document[field].(map[string]any)
		if got := value["confidence"]; got != wantConfidence {
			t.Fatalf("untouched %s confidence = %#v, want %v", field, got, wantConfidence)
		}
		if got := value["provenance"]; got != "analyzer" {
			t.Fatalf("untouched %s provenance = %#v, want analyzer", field, got)
		}
	}
}

func TestProjectCompactAnalysisKeepsAnalyzerTrustForOffsetOnlyGridOverride(t *testing.T) {
	merged, overrides := projectCompactAnalysis(
		json.RawMessage(`{
			"beat_grid":{"bpm":120,"confidence":0.2,"provenance":"analyzer"}
		}`),
		json.RawMessage(`{
			"beat_grid":{"offset_ms":87,"confidence":1,"provenance":"manual_override"}
		}`),
	)

	for name, payload := range map[string]json.RawMessage{
		"merged":    merged,
		"overrides": overrides,
	} {
		var document map[string]any
		if err := json.Unmarshal(payload, &document); err != nil {
			t.Fatalf("decode %s compact analysis: %v", name, err)
		}
		grid := document["beat_grid"].(map[string]any)
		if got := grid["offset_ms"]; got != float64(87) {
			t.Fatalf("%s offset = %#v, want 87", name, got)
		}
		if name == "merged" {
			if got := grid["confidence"]; got != 0.2 {
				t.Fatalf("merged confidence = %#v, want analyzer 0.2", got)
			}
			if got := grid["provenance"]; got != "analyzer" {
				t.Fatalf("merged provenance = %#v, want analyzer", got)
			}
		} else if _, ok := grid["confidence"]; ok {
			t.Fatal("offset-only override must not carry grid-wide confidence")
		}
	}
}

func TestProjectCompactAnalysisCanonicalizesLegacyTimingAliases(t *testing.T) {
	merged, overrides := projectCompactAnalysis(
		nil,
		json.RawMessage(`{
			"bpm":{"nativeBpm":124},
			"beat_grid":{"offsetMs":87,"beatsMs":[0,484]},
			"downbeats":{"positionsMs":[0,1936]}
		}`),
	)

	for name, payload := range map[string]json.RawMessage{
		"merged":    merged,
		"overrides": overrides,
	} {
		var document map[string]any
		if err := json.Unmarshal(payload, &document); err != nil {
			t.Fatalf("decode %s compact analysis: %v", name, err)
		}
		bpm := document["bpm"].(map[string]any)
		if got := bpm["value"]; got != float64(124) {
			t.Fatalf("%s BPM = %#v, want canonical 124", name, got)
		}
		grid := document["beat_grid"].(map[string]any)
		if got := grid["offset_ms"]; got != float64(87) {
			t.Fatalf("%s grid offset = %#v, want canonical 87", name, got)
		}
		if got := grid["beats_ms"].([]any); len(got) != 2 {
			t.Fatalf("%s grid markers = %#v", name, got)
		}
		downbeats := document["downbeats"].(map[string]any)
		if got := downbeats["positions_ms"].([]any); len(got) != 2 {
			t.Fatalf("%s downbeats = %#v", name, got)
		}
		for _, field := range []string{"bpm", "beat_grid", "downbeats"} {
			if _, ok := document[field].(map[string]any)["confidence"]; !ok {
				t.Fatalf("%s %s is missing manual confidence", name, field)
			}
		}
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
