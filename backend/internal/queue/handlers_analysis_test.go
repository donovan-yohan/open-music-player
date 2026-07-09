package queue

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestBuildQueueResponseWithAnalysisCompact(t *testing.T) {
	trackID := int64(42)
	state := &QueueState{
		UpdatedAt: time.Date(2026, 6, 26, 8, 0, 0, 0, time.UTC),
		Items: []QueueItem{{
			ID:            "q_analysis",
			Position:      0,
			TrackID:       &trackID,
			PlaybackState: "playable",
			AddedAt:       time.Date(2026, 6, 26, 7, 59, 0, 0, time.UTC),
		}},
	}
	summary := json.RawMessage(`{"bpm":{"value":124,"confidence":0.94,"provenance":"fixture"},"beat_grid":{"beats_ms":[320,804]},"loudness":{"integrated_lufs":-11.8}}`)
	overrides := json.RawMessage(`{"bpm":{"value":126,"provenance":"manual_override"},"downbeats":{"positions_ms":[500]}}`)
	resp := buildQueueResponseWithAnalysis(state, nil, map[int64]db.AnalysisCompact{
		trackID: {TrackID: trackID, Status: db.AnalysisStatusAnalyzed, SummaryJSON: summary, OverridesJSON: overrides},
	})
	if len(resp.Items) != 1 {
		t.Fatalf("items len = %d, want 1", len(resp.Items))
	}
	item := resp.Items[0]
	if item.AnalysisStatus != db.AnalysisStatusAnalyzed {
		t.Fatalf("analysis status = %q, want %q", item.AnalysisStatus, db.AnalysisStatusAnalyzed)
	}
	if string(item.AnalysisSummary) != string(summary) {
		t.Fatalf("analysis summary = %s, want %s", item.AnalysisSummary, summary)
	}
	if string(item.AnalysisOverrides) != string(overrides) {
		t.Fatalf("analysis overrides = %s, want %s", item.AnalysisOverrides, overrides)
	}
}

func TestBuildQueueResponseWithStaleAnalysisCompact(t *testing.T) {
	trackID := int64(42)
	state := &QueueState{
		UpdatedAt: time.Date(2026, 6, 26, 8, 0, 0, 0, time.UTC),
		Items: []QueueItem{{
			ID:            "q_analysis",
			Position:      0,
			TrackID:       &trackID,
			PlaybackState: "playable",
			AddedAt:       time.Date(2026, 6, 26, 7, 59, 0, 0, time.UTC),
		}},
	}
	resp := buildQueueResponseWithAnalysis(state, nil, map[int64]db.AnalysisCompact{
		trackID: {TrackID: trackID, Status: db.AnalysisStatusStale},
	})
	if got := resp.Items[0].AnalysisStatus; got != db.AnalysisStatusStale {
		t.Fatalf("analysis status = %q, want %q", got, db.AnalysisStatusStale)
	}
}
