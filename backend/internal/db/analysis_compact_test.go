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

func TestProjectCompactAnalysisSelectsPhaseWithoutMutatingBeats(t *testing.T) {
	beats := []int64{100, 600, 1100, 1600, 2100, 2600, 3100, 3600}
	summary := json.RawMessage(`{"beat_grid":{"bpm":120,"beats_ms":[100,600,1100,1600,2100,2600,3100,3600]},"downbeats":{"positions_ms":[100,2100]}}`)
	overrides := json.RawMessage(`{"manual_timing_override":{"beats_per_bar":4,"downbeat_phase_index":1,"phrase_length_bars":8,"revision":7,"updated_at":"2026-07-26T00:00:00Z"}}`)

	merged, compactOverrides := projectCompactAnalysis(summary, overrides)
	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatal(err)
	}
	grid := document["beat_grid"].(map[string]any)
	gotBeats := grid["beats_ms"].([]any)
	if len(gotBeats) != len(beats) {
		t.Fatalf("beat count = %d, want %d", len(gotBeats), len(beats))
	}
	for index, beat := range beats {
		if gotBeats[index] != float64(beat) {
			t.Fatalf("beat[%d] = %#v, want %d", index, gotBeats[index], beat)
		}
	}
	downbeats := document["downbeats"].(map[string]any)["positions_ms"].([]any)
	if len(downbeats) != 2 || downbeats[0] != float64(600) || downbeats[1] != float64(2600) {
		t.Fatalf("phase-selected downbeats = %#v", downbeats)
	}
	var overrideDocument map[string]any
	if err := json.Unmarshal(compactOverrides, &overrideDocument); err != nil {
		t.Fatal(err)
	}
	timing := overrideDocument["manual_timing_v2"].(map[string]any)
	if timing["revision"] != float64(7) || timing["phrase_length_bars"] != float64(8) {
		t.Fatalf("compact timing metadata = %#v", timing)
	}
	if timing["schema_version"] != float64(2) {
		t.Fatalf("compact timing schema = %#v, want 2", timing["schema_version"])
	}
}

func TestProjectCompactAnalysisRegeneratesBPMAndInteriorAnchorBeforePhase(t *testing.T) {
	merged, _ := projectCompactAnalysis(
		json.RawMessage(`{"bpm":{"value":100},"beat_grid":{"bpm":100,"offset_ms":0,"beats_ms":[0,600,1200,1800,2400]}}`),
		json.RawMessage(`{
			"beat_grid":{"beats_ms":[0,600,1200,1800,2400]},
			"manual_timing_override":{"bpm":120,"beat_anchor_ms":750,"beats_per_bar":4,"downbeat_phase_index":1}
		}`),
	)
	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatal(err)
	}
	grid := document["beat_grid"].(map[string]any)
	if got := grid["offset_ms"]; got != float64(750) {
		t.Fatalf("effective anchor = %#v, want 750", got)
	}
	wantBeats := []float64{250, 750, 1250, 1750, 2250}
	gotBeats := grid["beats_ms"].([]any)
	if len(gotBeats) != len(wantBeats) {
		t.Fatalf("regenerated beats = %#v, want %#v", gotBeats, wantBeats)
	}
	for index, want := range wantBeats {
		if gotBeats[index] != want {
			t.Fatalf("regenerated beat[%d] = %#v, want %v", index, gotBeats[index], want)
		}
	}
	downbeats := document["downbeats"].(map[string]any)["positions_ms"].([]any)
	if len(downbeats) != 1 || downbeats[0] != float64(750) {
		t.Fatalf("phase did not select regenerated grid: %#v", downbeats)
	}
}

func TestProjectCompactAnalysisUsesBaseFactsForSingleGridCorrection(t *testing.T) {
	for name, fixture := range map[string]struct {
		override string
		want     []float64
	}{
		"anchor only uses base BPM": {
			override: `{"manual_timing_override":{"beat_anchor_ms":750}}`,
			want:     []float64{250, 750, 1250, 1750},
		},
		"BPM only uses base anchor": {
			override: `{"manual_timing_override":{"bpm":60}}`,
			want:     []float64{250, 1250},
		},
	} {
		t.Run(name, func(t *testing.T) {
			merged, _ := projectCompactAnalysis(
				json.RawMessage(`{"bpm":{"value":120},"beat_grid":{"bpm":120,"offset_ms":250,"beats_ms":[250,750,1250,1750]}}`),
				json.RawMessage(fixture.override),
			)
			var document map[string]any
			if err := json.Unmarshal(merged, &document); err != nil {
				t.Fatal(err)
			}
			got := document["beat_grid"].(map[string]any)["beats_ms"].([]any)
			if len(got) != len(fixture.want) {
				t.Fatalf("beats = %#v, want %#v", got, fixture.want)
			}
			for index, want := range fixture.want {
				if got[index] != want {
					t.Fatalf("beat[%d] = %#v, want %v", index, got[index], want)
				}
			}
		})
	}
}

func TestProjectCompactAnalysisDoesNotInventDownbeatsWithoutMeter(t *testing.T) {
	merged, _ := projectCompactAnalysis(
		json.RawMessage(`{"beat_grid":{"beats_ms":[100,600,1100,1600]}}`),
		json.RawMessage(`{"manual_timing_override":{"phrase_length_bars":8,"revision":2}}`),
	)
	var document map[string]any
	if err := json.Unmarshal(merged, &document); err != nil {
		t.Fatal(err)
	}
	if _, present := document["downbeats"]; present {
		t.Fatalf("phrase length fabricated downbeats: %#v", document["downbeats"])
	}
}

func TestProjectCompactAnalysisInvalidatesDownbeatsByIndependentTimingFact(t *testing.T) {
	base := json.RawMessage(`{
		"bpm":{"value":120},
		"beat_grid":{"bpm":120,"offset_ms":0,"beats_ms":[0,500,1000,1500,2000]},
		"downbeats":{"positions_ms":[0,2000]}
	}`)
	for name, fixture := range map[string]struct {
		override      string
		wantDownbeats []float64
	}{
		"BPM only clears": {
			override: `{"manual_timing_override":{"bpm":121}}`,
		},
		"anchor only clears": {
			override: `{"manual_timing_override":{"beat_anchor_ms":250}}`,
		},
		"meter only clears": {
			override: `{"manual_timing_override":{"beats_per_bar":4}}`,
		},
		"meter and phase select": {
			override:      `{"manual_timing_override":{"beats_per_bar":4,"downbeat_phase_index":1}}`,
			wantDownbeats: []float64{500},
		},
		"phrase only preserves": {
			override:      `{"manual_timing_override":{"phrase_length_bars":8}}`,
			wantDownbeats: []float64{0, 2000},
		},
		"metadata only preserves": {
			override:      `{"manual_timing_override":{"revision":3,"updated_at":"2026-07-26T00:00:00Z"}}`,
			wantDownbeats: []float64{0, 2000},
		},
	} {
		t.Run(name, func(t *testing.T) {
			merged, _ := projectCompactAnalysis(base, json.RawMessage(fixture.override))
			var document map[string]any
			if err := json.Unmarshal(merged, &document); err != nil {
				t.Fatal(err)
			}
			rawDownbeats, present := document["downbeats"]
			if len(fixture.wantDownbeats) == 0 {
				if present {
					t.Fatalf("stale downbeats survived: %#v", rawDownbeats)
				}
				return
			}
			if !present {
				t.Fatalf("downbeats missing, want %#v", fixture.wantDownbeats)
			}
			got := rawDownbeats.(map[string]any)["positions_ms"].([]any)
			if len(got) != len(fixture.wantDownbeats) {
				t.Fatalf("downbeats = %#v, want %#v", got, fixture.wantDownbeats)
			}
			for index, want := range fixture.wantDownbeats {
				if got[index] != want {
					t.Fatalf("downbeat[%d] = %#v, want %v", index, got[index], want)
				}
			}
		})
	}
}

func TestProjectCompactAnalysisPreservesManualTimingRevisionOnReset(t *testing.T) {
	merged, overrides := projectCompactAnalysis(
		json.RawMessage(`{"beat_grid":{"beats_ms":[0,500]}}`),
		json.RawMessage(`{"manual_timing_override":{"revision":4,"updated_at":"2026-07-26T00:00:00Z","confidence":1,"provenance":"manual_override"}}`),
	)
	var effective map[string]any
	if err := json.Unmarshal(merged, &effective); err != nil {
		t.Fatalf("decode effective projection: %v", err)
	}
	if _, present := effective["manual_timing_v2"]; present {
		t.Fatalf("effective projection leaked manual document: %#v", effective)
	}

	var document map[string]any
	if err := json.Unmarshal(overrides, &document); err != nil {
		t.Fatalf("decode overrides: %v", err)
	}
	timing, ok := document["manual_timing_v2"].(map[string]any)
	if !ok || timing["revision"] != float64(4) {
		t.Fatalf("reset metadata = %#v", document["manual_timing_v2"])
	}
}

func TestProjectCompactAnalysisV2WinsAndGeneratedUnknownFactsStayUnknown(t *testing.T) {
	beats := `[100,600,1100,1600,2100]`
	merged, overrides := projectCompactAnalysis(
		json.RawMessage(`{
			"beat_grid":{"bpm":120,"beats_ms":`+beats+`},
			"meter":{"beats_per_bar":null,"confidence":null,"provenance":"tempo-model"},
			"downbeat_phase":{"index":null,"confidence":null,"provenance":"tempo-model"},
			"downbeats":{"positions_ms":[100,2100],"confidence":0.9,"provenance":"tempo-model"}
		}`),
		json.RawMessage(`{
			"manual_timing_override":{"beats_per_bar":3,"downbeat_phase_index":2},
			"manual_timing_v2":{"schema_version":2,"beats_per_bar":4,"downbeat_phase_index":1}
		}`),
	)
	var effective map[string]any
	if err := json.Unmarshal(merged, &effective); err != nil {
		t.Fatal(err)
	}
	gotBeats, err := json.Marshal(effective["beat_grid"].(map[string]any)["beats_ms"])
	if err != nil {
		t.Fatal(err)
	}
	if string(gotBeats) != beats {
		t.Fatalf("phase-only edit mutated beats: %s, want %s", gotBeats, beats)
	}
	if got := effective["meter"].(map[string]any)["beats_per_bar"]; got != float64(4) {
		t.Fatalf("effective meter = %#v, want v2 value 4", got)
	}
	if got := effective["downbeat_phase"].(map[string]any)["index"]; got != float64(1) {
		t.Fatalf("effective phase = %#v, want v2 value 1", got)
	}
	gotDownbeats := effective["downbeats"].(map[string]any)["positions_ms"].([]any)
	if len(gotDownbeats) != 1 || gotDownbeats[0] != float64(600) {
		t.Fatalf("v2 downbeats = %#v, want [600]", gotDownbeats)
	}
	var projectedOverrides map[string]any
	if err := json.Unmarshal(overrides, &projectedOverrides); err != nil {
		t.Fatal(err)
	}
	if _, present := projectedOverrides["manual_timing_override"]; present {
		t.Fatal("provisional manual_timing_override was dual-emitted")
	}
	if projectedOverrides["manual_timing_v2"].(map[string]any)["schema_version"] != float64(2) {
		t.Fatalf("canonical v2 missing: %#v", projectedOverrides)
	}
}

func TestProjectEffectiveTimingDoesNotInferLegacyMeterOrPhrase(t *testing.T) {
	effective, projectedOverrides := ProjectEffectiveTiming(
		json.RawMessage(`{
			"beat_grid":{"beats_ms":[0,500,1000,1500,2000]},
			"downbeats":{"positions_ms":[0,2000],"confidence":0.9}
		}`),
		json.RawMessage(`{"downbeats":{"positions_ms":[0,2000]}}`),
	)
	var timing map[string]any
	if err := json.Unmarshal(effective, &timing); err != nil {
		t.Fatal(err)
	}
	if _, present := timing["meter"]; present {
		t.Fatalf("legacy spacing inferred meter: %#v", timing["meter"])
	}
	if _, present := timing["downbeat_phase"]; present {
		t.Fatalf("legacy spacing inferred phase: %#v", timing["downbeat_phase"])
	}
	if _, present := timing["phrase_length_bars"]; present {
		t.Fatalf("legacy spacing inferred phrase: %#v", timing["phrase_length_bars"])
	}
	var overrides map[string]any
	if err := json.Unmarshal(projectedOverrides, &overrides); err != nil {
		t.Fatal(err)
	}
	if _, present := overrides["manual_timing_v2"]; present {
		t.Fatal("legacy array row was silently normalized to v2")
	}
}
