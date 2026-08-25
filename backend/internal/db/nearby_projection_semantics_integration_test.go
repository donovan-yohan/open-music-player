package db

import (
	"encoding/json"
	"testing"
)

func TestGeneratedNearbyBPMProjectionMatchesCompactManualTimingSemantics(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)

	cases := []struct {
		name      string
		summary   json.RawMessage
		overrides json.RawMessage
	}{
		{
			name:      "valid v2 timing BPM wins direct override",
			summary:   json.RawMessage(`{"bpm":{"value":120}}`),
			overrides: json.RawMessage(`{"bpm":{"value":130},"manual_timing_v2":{"schema_version":2,"bpm":140}}`),
		},
		{
			name:      "timing meter above maximum falls back to direct override",
			summary:   json.RawMessage(`{"bpm":{"value":120}}`),
			overrides: json.RawMessage(`{"bpm":{"value":130},"manual_timing_v2":{"schema_version":2,"bpm":140,"beats_per_bar":33}}`),
		},
		{
			name:      "invalid v2 timing falls back to direct override",
			summary:   json.RawMessage(`{"bpm":{"value":120}}`),
			overrides: json.RawMessage(`{"bpm":{"value":130},"manual_timing_v2":{"schema_version":2,"bpm":140,"beats_per_bar":4,"downbeat_phase_index":4}}`),
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			trackID := seedPlayTrack(t, trackRepo, ctx, "Projection", testCase.name)
			if _, err := database.ExecContext(ctx, `
				INSERT INTO track_analysis (track_id, status, summary_json, overrides_json)
				VALUES ($1, 'analyzed', $2::jsonb, $3::jsonb)
			`, trackID, testCase.summary, testCase.overrides); err != nil {
				t.Fatalf("insert analysis: %v", err)
			}

			projectedJSON, _ := projectCompactAnalysis(testCase.summary, testCase.overrides)
			projected := decodeCompactAnalysis(projectedJSON)
			if projected.BPM == nil || projected.BPM.Value == nil {
				t.Fatalf("compact projection has no BPM: %s", projectedJSON)
			}

			var generated float64
			if err := database.QueryRowContext(ctx, `
				SELECT effective_bpm FROM track_analysis WHERE track_id = $1
			`, trackID).Scan(&generated); err != nil {
				t.Fatalf("read generated BPM: %v", err)
			}
			if generated != *projected.BPM.Value {
				t.Fatalf("generated BPM = %v, compact projection BPM = %v", generated, *projected.BPM.Value)
			}
		})
	}
}
