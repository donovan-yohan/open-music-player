package search

import (
	"database/sql"
	"encoding/json"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestRecordingResponseIncludesCompactAnalysis(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":128},"key":{"value":"Am"},"camelot":{"value":"8A"}}`)
	revision := time.Date(2026, 7, 10, 11, 0, 0, 123456789, time.UTC)

	responses := toRecordingResponses([]db.Track{{
		ID:                9,
		Title:             "Search result",
		AnalysisStatus:    sql.NullString{String: db.AnalysisStatusAnalyzed, Valid: true},
		AnalysisSummary:   summary,
		AnalysisUpdatedAt: sql.NullTime{Time: revision, Valid: true},
	}})

	if len(responses) != 1 {
		t.Fatalf("responses length = %d, want 1", len(responses))
	}
	if responses[0].AnalysisStatus != db.AnalysisStatusAnalyzed {
		t.Fatalf("analysis status = %q", responses[0].AnalysisStatus)
	}
	if string(responses[0].AnalysisSummary) != string(summary) {
		t.Fatalf("analysis summary = %s, want %s", responses[0].AnalysisSummary, summary)
	}
	if responses[0].AnalysisUpdatedAt != "2026-07-10T11:00:00.123456789Z" {
		t.Fatalf("analysis updated at = %q", responses[0].AnalysisUpdatedAt)
	}
}
