package api

import (
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestPlaylistTrackResponseIncludesCompactAnalysis(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":141.18},"key":{"value":"F#m"},"camelot":{"value":"11A"}}`)

	responses := mapTrackResponses([]db.Track{{
		ID:              42,
		Title:           "Analyzed",
		AnalysisStatus:  sql.NullString{String: db.AnalysisStatusAnalyzed, Valid: true},
		AnalysisSummary: summary,
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
}

func TestPlayEventTrackResponseIncludesCompactAnalysis(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":72.73},"camelot":{"value":"8A"}}`)

	response := trackToPlayEventResponse(db.Track{
		ID:              7,
		Title:           "Recently played",
		AnalysisStatus:  sql.NullString{String: db.AnalysisStatusAnalyzed, Valid: true},
		AnalysisSummary: summary,
	})

	if response.AnalysisStatus != db.AnalysisStatusAnalyzed {
		t.Fatalf("analysis status = %q", response.AnalysisStatus)
	}
	if string(response.AnalysisSummary) != string(summary) {
		t.Fatalf("analysis summary = %s, want %s", response.AnalysisSummary, summary)
	}
}
