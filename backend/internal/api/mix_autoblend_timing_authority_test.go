package api

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// These inputs cross the actual shared projection, not a test-only facts
// constructor. Confident marker spacing is not evidence of musical bar phase.
func TestAutoBlendEffectiveTimingGeneratedUnknownPhaseAbstains(t *testing.T) {
	for _, confidence := range []float64{0.1, 1} {
		t.Run(stringMustJSON(t, confidence), func(t *testing.T) {
			summary := json.RawMessage(`{"bpm":{"value":120,"confidence":` + stringMustJSON(t, confidence) + `,"provenance":"generated"},"meter":{"beats_per_bar":null,"provenance":"generated"},"downbeat_phase":{"index":null,"provenance":"generated"},"downbeats":{"positions_ms":[0,2000,44000,46000,58000],"confidence":` + stringMustJSON(t, confidence) + `,"provenance":"generated"}}`)
			effective, _ := db.ProjectEffectiveTiming(summary, nil)
			track := db.Track{ID: 1, DurationMs: sqlNullInt32(60000), AnalysisSummary: effective}
			before := string(track.AnalysisSummary)
			out := autoBlendTrackFactsFromAnalysis(track)
			in := out
			in.TrackID = 2
			transition := computeAutoBlendTransition(0, out, in)
			if transition.Preset != PresetFade || transition.Bars != 0 ||
				transition.OverlapMs != autoBlendSimpleFadeMs || !transition.Confidence.SimpleFade {
				t.Fatalf("unsupported phase produced aligned geometry: %+v", transition)
			}
			if !out.HasBPM || out.BPM != 120 || len(out.Downbeats) != 5 || string(track.AnalysisSummary) != before {
				t.Fatalf("abstention erased display facts: %+v, summary=%s", out, track.AnalysisSummary)
			}
			if confidence < 0.55 && (transition.Confidence.TempoMatched || transition.Confidence.TempoShift || transition.Confidence.TempoDeltaPercent != nil) {
				t.Fatalf("low-confidence tempo advertised sync authority: %+v", transition.Confidence)
			}
		})
	}
}

func TestAutoBlendManualAuthorityDoesNotRepairMalformedMarkers(t *testing.T) {
	for _, markers := range []string{`[0,44000,44000,58000]`, `[44000,0,58000]`, `[-1,0,44000]`, `[0,null,44000]`} {
		t.Run(markers, func(t *testing.T) {
			summary := json.RawMessage(`{"bpm":{"value":120},"downbeats":{"positions_ms":` + markers + `,"confidence":1,"provenance":"manual_override"}}`)
			facts := autoBlendTrackFactsFromAnalysis(db.Track{DurationMs: sqlNullInt32(60000), AnalysisSummary: summary})
			transition := computeAutoBlendTransition(0, facts, facts)
			if !transition.Confidence.SimpleFade || transition.Bars != 0 {
				t.Fatalf("malformed markers granted phase authority: %+v", transition)
			}
		})
	}
}

func TestAutoBlendManualDownbeatsMustFollowEffectiveBeatGrid(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":120},"beat_grid":{"beats_ms":[0,500,1000,1500,2000,44000,44500,45000,45500,46000,58000]},"downbeats":{"positions_ms":[0,2100,44000,46000,58000],"confidence":1,"provenance":"manual_override"}}`)
	effective, _ := db.ProjectEffectiveTiming(summary, nil)
	facts := autoBlendTrackFactsFromAnalysis(db.Track{DurationMs: sqlNullInt32(60000), AnalysisSummary: effective})
	transition := computeAutoBlendTransition(0, facts, facts)
	if !transition.Confidence.SimpleFade || transition.Bars != 0 {
		t.Fatalf("off-grid markers granted phase authority: %+v", transition)
	}
}

func TestAutoBlendRawTimingCannotCoerceAuthority(t *testing.T) {
	for _, fragment := range []string{
		`"bpm":{"value":120,"confidence":1.01}`,
		`"bpm":{"value":120,"confidence":-1}`,
		`"bpm":{"value":1e999}`,
		`"bpm":{"value":"120"}`,
		`"bpm":{"value":null}`,
		`"bpm":{"value":120},"downbeats":{"positions_ms":[null,44000,58000],"confidence":1,"provenance":"manual_override"}`,
		`"bpm":{"value":120},"downbeats":{"positions_ms":[0,44000.5,58000],"confidence":1,"provenance":"manual_override"}`,
		`"bpm":{"value":120},"meter":{"beats_per_bar":33,"confidence":1,"provenance":"manual_override"},"downbeat_phase":{"index":0,"confidence":1,"provenance":"manual_override"}`,
	} {
		t.Run(fragment, func(t *testing.T) {
			document := map[string]json.RawMessage{"downbeats": json.RawMessage(`{"positions_ms":[0,44000,58000],"confidence":1,"provenance":"manual_override"}`)}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal([]byte(`{`+fragment+`}`), &fields); err != nil {
				t.Fatal(err)
			}
			for key, value := range fields {
				document[key] = value
			}
			facts := autoBlendTrackFactsFromAnalysis(db.Track{DurationMs: sqlNullInt32(60000), AnalysisSummary: json.RawMessage(stringMustJSON(t, document))})
			transition := computeAutoBlendTransition(0, facts, facts)
			if !transition.Confidence.SimpleFade || transition.Bars != 0 {
				t.Fatalf("invalid timing granted authority: %+v", transition)
			}
		})
	}
}

func TestAutoBlendEffectiveBeatGridTempoFallback(t *testing.T) {
	for _, confidence := range []float64{0.1, 0.55, 1} {
		t.Run(stringMustJSON(t, confidence), func(t *testing.T) {
			summary := json.RawMessage(`{"beat_grid":{"bpm":120,"confidence":` + stringMustJSON(t, confidence) + `,"beats_ms":[0,500,1000,1500]},"downbeats":{"positions_ms":[0,44000,58000],"confidence":1,"provenance":"manual_override"}}`)
			effective, _ := db.ProjectEffectiveTiming(summary, nil)
			facts := autoBlendTrackFactsFromAnalysis(db.Track{DurationMs: sqlNullInt32(60000), AnalysisSummary: effective})
			if !facts.HasBPM || facts.BPM != 120 || facts.TempoEligible != (confidence >= 0.55) {
				t.Fatalf("beat-grid numeric tempo/eligibility disagrees with client adapter: %+v", facts)
			}
		})
	}
}

func TestAutoBlendInvalidNumericTempoNeverAdvertisesSync(t *testing.T) {
	for _, bpm := range []float64{0, -120, math.NaN(), math.Inf(1), math.Inf(-1)} {
		ratio := autoBlendTempoRatio(bpm, bpm, true, true)
		if ratio != math.MaxFloat64 || autoBlendTempoDeltaPercent(ratio) != nil {
			t.Fatalf("invalid bpm %v produced tempo ratio %v", bpm, ratio)
		}
	}
}

func TestCreateAutoMixUnknownPhasePersistsSimpleFadeGeometry(t *testing.T) {
	summary, _ := db.ProjectEffectiveTiming(json.RawMessage(`{"bpm":{"value":120,"confidence":0.1},"downbeats":{"positions_ms":[0,2000,44000,58000],"confidence":0.1}}`), nil)
	userID := uuid.New()
	tracks := []db.Track{
		{ID: 1, DurationMs: sqlNullInt32(60000), AnalysisSummary: summary},
		{ID: 2, DurationMs: sqlNullInt32(60000), AnalysisSummary: summary},
	}
	store := &fakeMixPlanStore{}
	h := NewPlaylistAutoBlendHandlers(&fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}, store, true)
	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 7))
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	payload := assertPersistedMixValid(t, store.created, 2)
	var response AutoMixResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	transition := response.Transitions[0]
	if !transition.Confidence.SimpleFade || transition.Bars != 0 || transition.Confidence.TempoMatched || transition.Confidence.TempoShift || transition.Confidence.TempoDeltaPercent != nil {
		t.Fatalf("unsupported authority leaked through handler: %+v", transition)
	}
	if payload.Clips[1].TimelineStartMs != 52000 || payload.Clips[0].FadeOutMs == nil || *payload.Clips[0].FadeOutMs != 8000 || payload.Clips[1].FadeInMs == nil || *payload.Clips[1].FadeInMs != 8000 {
		t.Fatalf("persisted fallback geometry=%+v", payload.Clips)
	}
}

func TestAutoBlendDifferentManualMetersDoNotClaimSharedBars(t *testing.T) {
	out := factsFor(autoBlendTrack(1, 60000, 120, true, "8A", 0, 44000, 58000))
	in := out
	// Explicitly trusted facts are still not evidence of one shared bar length.
	in.BeatsPerBar = 3
	transition := computeAutoBlendTransition(0, out, in)
	if !transition.Confidence.SimpleFade || transition.Bars != 0 {
		t.Fatalf("different meters produced shared-bar geometry: %+v", transition)
	}
}

func TestAutoBlendDirectFactsMustOptIntoTimingAuthority(t *testing.T) {
	facts := autoBlendTrackFacts{BPM: 120, HasBPM: true, DurationMs: 60000, BeatsPerBar: 4, Downbeats: []int64{0, 44000, 58000}}
	transition := computeAutoBlendTransition(0, facts, facts)
	if !transition.Confidence.SimpleFade || transition.Bars != 0 || transition.Confidence.TempoMatched || transition.Confidence.TempoDeltaPercent != nil {
		t.Fatalf("zero-value eligibility granted timing authority: %+v", transition)
	}
}

func TestAutoBlendEffectiveBeatEligibilityDoesNotImplyBarPhase(t *testing.T) {
	for _, tt := range []struct {
		name, beats string
		wantBeat    bool
	}{
		{"coherent variable tempo", `[0,500,1020,1560,2120]`, true},
		{"sparse", `[0,500,1000]`, false},
		{"duplicate", `[0,500,500,1000]`, false},
		{"abrupt missing cell", `[0,500,1000,5000]`, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			effective, _ := db.ProjectEffectiveTiming(json.RawMessage(`{"bpm":{"value":120,"confidence":1},"beat_grid":{"beats_ms":`+tt.beats+`},"downbeats":{"positions_ms":[0,44000,58000],"confidence":1}}`), nil)
			facts := autoBlendTrackFactsFromAnalysis(db.Track{DurationMs: sqlNullInt32(60000), AnalysisSummary: effective})
			if facts.BeatGridEligible != tt.wantBeat || facts.BarEligible {
				t.Fatalf("beat/bar eligibility conflated: %+v", facts)
			}
		})
	}
}

func stringMustJSON(t *testing.T, value any) string {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}

func TestAutoBlendEffectiveTimingAuthorityParity(t *testing.T) {
	// The client analysis adapter accepts only canonical manual meter+phase or
	// explicit legacy manual downbeats. A bare summary is not that legacy path.
	beats := make([]int64, 120)
	for i := range beats {
		beats[i] = int64(i) * 500
	}
	base := `{"bpm":{"value":120,"confidence":1},"beat_grid":{"bpm":120,"beats_ms":` + stringMustJSON(t, beats) + `},"downbeats":{"positions_ms":[0,2000,44000,46000,58000],"confidence":1}}`
	tests := []struct {
		name, summary, overrides string
		wantBars                 int
		wantOverlap              int64
	}{
		{"unlabelled legacy summary is display only", base, `{}`, 0, 8000},
		{"generated known meter and phase still uncalibrated", base[:len(base)-1] + `,"meter":{"beats_per_bar":4,"confidence":1,"provenance":"generated"},"downbeat_phase":{"index":0,"confidence":1,"provenance":"generated"}}`, `{}`, 0, 8000},
		{"legacy manual markers retain implicit four beat compatibility", base, `{"downbeats":{"positions_ms":[0,2000,44000,46000,58000]}}`, 8, 16000},
		{"legacy BPM only does not promote phase", base, `{"bpm":{"value":120}}`, 0, 8000},
		{"canonical manual four beat phase", base, `{"manual_timing_v2":{"schema_version":2,"beats_per_bar":4,"downbeat_phase_index":0}}`, 8, 16000},
		{"provisional manual timing alias shares canonical projection", base, `{"manual_timing_override":{"beats_per_bar":4,"downbeat_phase_index":0}}`, 8, 16000},
		{"manual three beat meter is not forced to four", base, `{"manual_timing_v2":{"schema_version":2,"beats_per_bar":3,"downbeat_phase_index":0}}`, 8, 12000},
		{"phase-only correction retains source beat origin", base, `{"manual_timing_v2":{"schema_version":2,"beats_per_bar":4,"downbeat_phase_index":1}}`, 8, 16000},
		{"manual BPM and anchor retain phase authority", base, `{"manual_timing_v2":{"schema_version":2,"bpm":120,"beat_anchor_ms":0,"beats_per_bar":4,"downbeat_phase_index":0}}`, 8, 16000},
		{"canonical meter without phase cannot inherit old markers", base, `{"manual_timing_v2":{"schema_version":2,"beats_per_bar":4}}`, 0, 8000},
		{"canonical BPM without phase cannot inherit old markers", base, `{"manual_timing_v2":{"schema_version":2,"bpm":120}}`, 0, 8000},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			effective, _ := db.ProjectEffectiveTiming(json.RawMessage(tt.summary), json.RawMessage(tt.overrides))
			facts := autoBlendTrackFactsFromAnalysis(db.Track{ID: 1, DurationMs: sqlNullInt32(60000), AnalysisSummary: effective})
			transition := computeAutoBlendTransition(0, facts, facts)
			if tt.name == "phase-only correction retains source beat origin" {
				var timing struct {
					BeatGrid struct {
						Beats []int64 `json:"beats_ms"`
					} `json:"beat_grid"`
				}
				if err := json.Unmarshal(effective, &timing); err != nil {
					t.Fatal(err)
				}
				if len(timing.BeatGrid.Beats) != len(beats) || timing.BeatGrid.Beats[0] != 0 || facts.Downbeats[0] != 500 {
					t.Fatalf("phase-only edit changed beat origin or ignored phase: %s", effective)
				}
			}
			if transition.Bars != tt.wantBars || transition.OverlapMs != tt.wantOverlap || transition.Confidence.SimpleFade != (tt.wantOverlap == 8000) {
				t.Fatalf("transition=%+v, effective=%s", transition, effective)
			}
		})
	}
}
