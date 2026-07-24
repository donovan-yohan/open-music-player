package api

import (
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestPlaylistTrackResponseIncludesCompactAnalysis(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":141.18},"key":{"value":"F#m"},"camelot":{"value":"11A"}}`)
	revision := time.Date(2026, 7, 10, 11, 0, 0, 123456789, time.UTC)

	responses := mapTrackResponses([]db.Track{{
		ID:                42,
		Title:             "Analyzed",
		AnalysisStatus:    sql.NullString{String: db.AnalysisStatusAnalyzed, Valid: true},
		AnalysisSummary:   summary,
		AnalysisUpdatedAt: sql.NullTime{Time: revision, Valid: true},
		FileSizeBytes:     sql.NullInt64{Int64: 3200000, Valid: true},
		Codec:             sql.NullString{String: "mp3", Valid: true},
		BitrateKbps:       sql.NullInt32{Int32: 137, Valid: true},
		SampleRateHz:      sql.NullInt32{Int32: 44100, Valid: true},
		Channels:          sql.NullInt32{Int32: 2, Valid: true},
		ContentType:       sql.NullString{String: "audio/mpeg", Valid: true},
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
	if responses[0].FileSizeBytes != 3200000 || responses[0].Codec != "mp3" ||
		responses[0].BitrateKbps != 137 || responses[0].SampleRateHz != 44100 ||
		responses[0].Channels != 2 || responses[0].ContentType != "audio/mpeg" {
		t.Fatalf("playlist quality projection = %+v", responses[0])
	}
	encoded, _ := json.Marshal(responses[0])
	if !strings.Contains(string(encoded), `"fileSizeBytes":3200000`) ||
		!strings.Contains(string(encoded), `"bitrateKbps":137`) ||
		strings.Contains(string(encoded), "bitrate_kbps") {
		t.Fatalf("playlist quality JSON casing = %s", encoded)
	}
}

func TestPlayEventTrackResponseIncludesCompactAnalysis(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":72.73},"camelot":{"value":"8A"}}`)
	revision := time.Date(2026, 7, 10, 11, 0, 0, 123456789, time.UTC)

	response := trackToPlayEventResponse(db.Track{
		ID:                7,
		Title:             "Recently played",
		AnalysisStatus:    sql.NullString{String: db.AnalysisStatusAnalyzed, Valid: true},
		AnalysisSummary:   summary,
		AnalysisUpdatedAt: sql.NullTime{Time: revision, Valid: true},
		FileSizeBytes:     sql.NullInt64{Int64: 4200000, Valid: true},
		Codec:             sql.NullString{String: "flac", Valid: true},
		BitrateKbps:       sql.NullInt32{Int32: 900, Valid: true},
		SampleRateHz:      sql.NullInt32{Int32: 48000, Valid: true},
		Channels:          sql.NullInt32{Int32: 2, Valid: true},
		ContentType:       sql.NullString{String: "audio/flac", Valid: true},
	})

	if response.AnalysisStatus != db.AnalysisStatusAnalyzed {
		t.Fatalf("analysis status = %q", response.AnalysisStatus)
	}
	if string(response.AnalysisSummary) != string(summary) {
		t.Fatalf("analysis summary = %s, want %s", response.AnalysisSummary, summary)
	}
	if response.AnalysisUpdatedAt != "2026-07-10T11:00:00.123456789Z" {
		t.Fatalf("analysis updated at = %q", response.AnalysisUpdatedAt)
	}
	if response.FileSizeBytes != 4200000 || response.Codec != "flac" ||
		response.BitrateKbps != 900 || response.SampleRateHz != 48000 ||
		response.Channels != 2 || response.ContentType != "audio/flac" {
		t.Fatalf("play event quality projection = %+v", response)
	}
	encoded, _ := json.Marshal(response)
	if !strings.Contains(string(encoded), `"sampleRateHz":48000`) ||
		!strings.Contains(string(encoded), `"contentType":"audio/flac"`) ||
		strings.Contains(string(encoded), "sample_rate_hz") {
		t.Fatalf("play event quality JSON casing = %s", encoded)
	}
}
