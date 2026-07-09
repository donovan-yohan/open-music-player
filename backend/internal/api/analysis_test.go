package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
