package api

import (
	"database/sql"
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
