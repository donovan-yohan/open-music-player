package api

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestNewAnalysisResponsePreservesUpdatedAtPrecision(t *testing.T) {
	updatedAt := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.FixedZone("offset", 3600))
	response := newAnalysisResponse(&db.TrackAnalysis{
		TrackID:     42,
		Status:      db.AnalysisStatusAnalyzed,
		RequestedAt: time.Date(2026, 7, 10, 10, 0, 0, 0, time.UTC),
		UpdatedAt:   updatedAt,
		Error:       sql.NullString{},
	})

	if got, want := response.UpdatedAt, "2026-07-10T11:00:00.123456Z"; got != want {
		t.Fatalf("updated_at = %q, want %q", got, want)
	}
}

func TestDecodeAnalysisOverridesRequestAcceptsCompactBody(t *testing.T) {
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/tracks/42/analysis/overrides",
		strings.NewReader(`{"overrides":{"bpm":{"value":124}}}`),
	)
	w := httptest.NewRecorder()

	decoded, err := decodeAnalysisOverridesRequest(w, req)
	if err != nil {
		t.Fatalf("decode compact overrides: %v", err)
	}
	if len(decoded.Overrides) == 0 {
		t.Fatal("expected overrides payload")
	}
}

func TestDecodeAnalysisOverridesRequestRejectsOversizedBody(t *testing.T) {
	body := `{"overrides":{"padding":"` +
		strings.Repeat("a", maxAnalysisOverridesRequestBytes) +
		`"}}`
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/tracks/42/analysis/overrides",
		strings.NewReader(body),
	)
	w := httptest.NewRecorder()

	if _, err := decodeAnalysisOverridesRequest(w, req); err == nil {
		t.Fatal("expected oversized overrides body to fail")
	}
}

func TestNormalizeAnalysisOverridesMarksManualTimingCorrectionsTrusted(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"value":124,"confidence":0.2,"provenance":"analyzer"},
		"beat_grid":{"bpm":124,"beats_ms":[120,604,1088]},
		"downbeats":{"positions_ms":[120,2056],"confidence":0.419}
	}`))
	if err != nil {
		t.Fatalf("normalize analysis overrides: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized overrides: %v", err)
	}
	for _, field := range []string{"bpm", "beat_grid", "downbeats"} {
		if got := overrides[field]["confidence"]; got != float64(1) {
			t.Fatalf("%s confidence = %#v, want 1", field, got)
		}
		if got := overrides[field]["provenance"]; got != manualAnalysisOverrideProvenance {
			t.Fatalf("%s provenance = %#v, want %q", field, got, manualAnalysisOverrideProvenance)
		}
	}
}

func TestNormalizeAnalysisOverridesCanonicalizesLegacyTimingAliases(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"nativeBpm":124},
		"beat_grid":{"offsetMs":12,"beatsMs":[0,484]},
		"downbeats":{"positionsMs":[0,1936]}
	}`))
	if err != nil {
		t.Fatalf("normalize aliases: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized aliases: %v", err)
	}
	bpm := overrides["bpm"]
	if got := bpm["value"]; got != float64(124) {
		t.Fatalf("canonical BPM value = %#v, want 124", got)
	}
	if _, ok := bpm["nativeBpm"]; ok {
		t.Fatal("legacy BPM alias survived normalization")
	}
	beatGrid := overrides["beat_grid"]
	if got := beatGrid["offset_ms"]; got != float64(12) {
		t.Fatalf("canonical beat-grid offset = %#v, want 12", got)
	}
	if got := beatGrid["beats_ms"]; !sameJSONNumbers(got, []float64{0, 484}) {
		t.Fatalf("canonical beat-grid markers = %#v", got)
	}
	if _, ok := beatGrid["offsetMs"]; ok {
		t.Fatal("legacy offset alias survived normalization")
	}
	if _, ok := beatGrid["beatsMs"]; ok {
		t.Fatal("legacy beats alias survived normalization")
	}
	downbeats := overrides["downbeats"]
	if got := downbeats["positions_ms"]; !sameJSONNumbers(got, []float64{0, 1936}) {
		t.Fatalf("canonical downbeats = %#v", got)
	}
	if _, ok := downbeats["positionsMs"]; ok {
		t.Fatal("legacy downbeat alias survived normalization")
	}
}

func TestNormalizeAnalysisOverridesPrefersCanonicalTimingFields(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"value":124,"nativeBpm":126},
		"beat_grid":{"offset_ms":12,"offsetMs":24,"beats_ms":[0,484],"beatsMs":[1,485]},
		"downbeats":{"positions_ms":[0,1936],"positionsMs":[1,1937]}
	}`))
	if err != nil {
		t.Fatalf("normalize mixed aliases: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized mixed aliases: %v", err)
	}
	if got := overrides["bpm"]["value"]; got != float64(124) {
		t.Fatalf("canonical BPM value = %#v, want 124", got)
	}
	if got := overrides["beat_grid"]["offset_ms"]; got != float64(12) {
		t.Fatalf("canonical grid offset = %#v, want 12", got)
	}
	if got := overrides["downbeats"]["positions_ms"]; !sameJSONNumbers(got, []float64{0, 1936}) {
		t.Fatalf("canonical downbeats = %#v", got)
	}
}

func TestNormalizeAnalysisOverridesKeepsOffsetOnlyGridUntrusted(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"beat_grid":{"offset_ms":87,"confidence":1,"provenance":"manual_override"}
	}`))
	if err != nil {
		t.Fatalf("normalize offset-only override: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized offset-only override: %v", err)
	}
	grid := overrides["beat_grid"]
	if got := grid["offset_ms"]; got != float64(87) {
		t.Fatalf("offset = %#v, want 87", got)
	}
	if _, ok := grid["confidence"]; ok {
		t.Fatal("offset-only override retained grid-wide confidence")
	}
	if _, ok := grid["provenance"]; ok {
		t.Fatal("offset-only override retained grid-wide provenance")
	}
}

func TestNormalizeAnalysisOverridesCanonicalizesBareAndEmptyDownbeats(t *testing.T) {
	for name, input := range map[string]string{
		"bare markers":   `{"downbeats":[120,2056]}`,
		"explicit clear": `{"downbeats":[]}`,
	} {
		t.Run(name, func(t *testing.T) {
			normalized, err := normalizeAnalysisOverrides(json.RawMessage(input))
			if err != nil {
				t.Fatalf("normalize downbeats: %v", err)
			}
			var overrides map[string]map[string]any
			if err := json.Unmarshal(normalized, &overrides); err != nil {
				t.Fatalf("decode normalized downbeats: %v", err)
			}
			downbeats := overrides["downbeats"]
			if _, ok := downbeats["positions_ms"]; !ok {
				t.Fatal("canonical positions_ms is missing")
			}
			if got := downbeats["confidence"]; got != float64(1) {
				t.Fatalf("downbeat confidence = %#v, want 1", got)
			}
			if got := downbeats["provenance"]; got != manualAnalysisOverrideProvenance {
				t.Fatalf("downbeat provenance = %#v", got)
			}
		})
	}
}

func TestNormalizeAnalysisOverridesRejectsMalformedTimingValues(t *testing.T) {
	for name, input := range map[string]string{
		"BPM alias is text":             `{"bpm":{"nativeBpm":"fast"}}`,
		"grid is not an object":         `{"beat_grid":[120]}`,
		"grid offset is fractional":     `{"beat_grid":{"offsetMs":1.5}}`,
		"grid markers are malformed":    `{"beat_grid":{"beatsMs":[0,"bad"]}}`,
		"downbeats positions are text":  `{"downbeats":{"positionsMs":"bad"}}`,
		"bare downbeats are fractional": `{"downbeats":[0,1.5]}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := normalizeAnalysisOverrides(json.RawMessage(input)); err == nil {
				t.Fatal("expected malformed timing override to fail")
			}
		})
	}
}

func sameJSONNumbers(value any, want []float64) bool {
	values, ok := value.([]any)
	if !ok || len(values) != len(want) {
		return false
	}
	for index, expected := range want {
		if values[index] != expected {
			return false
		}
	}
	return true
}
