package search

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestParsePagination(t *testing.T) {
	tests := []struct {
		name           string
		queryString    string
		expectedLimit  int
		expectedOffset int
	}{
		{
			name:           "default values",
			queryString:    "",
			expectedLimit:  20,
			expectedOffset: 0,
		},
		{
			name:           "custom limit",
			queryString:    "?limit=50",
			expectedLimit:  50,
			expectedOffset: 0,
		},
		{
			name:           "custom offset",
			queryString:    "?offset=10",
			expectedLimit:  20,
			expectedOffset: 10,
		},
		{
			name:           "both custom",
			queryString:    "?limit=30&offset=15",
			expectedLimit:  30,
			expectedOffset: 15,
		},
		{
			name:           "invalid limit uses default",
			queryString:    "?limit=invalid",
			expectedLimit:  20,
			expectedOffset: 0,
		},
		{
			name:           "negative limit uses default",
			queryString:    "?limit=-5",
			expectedLimit:  20,
			expectedOffset: 0,
		},
		{
			name:           "negative offset uses default",
			queryString:    "?offset=-10",
			expectedLimit:  20,
			expectedOffset: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/search"+tt.queryString, nil)
			limit, offset := parsePagination(req)

			if limit != tt.expectedLimit {
				t.Errorf("expected limit %d, got %d", tt.expectedLimit, limit)
			}
			if offset != tt.expectedOffset {
				t.Errorf("expected offset %d, got %d", tt.expectedOffset, offset)
			}
		})
	}
}

func TestSearchRecordingsValidation(t *testing.T) {
	h := NewHandlers(nil)

	t.Run("missing query parameter returns error", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search/recordings", nil)
		w := httptest.NewRecorder()

		h.SearchRecordings(w, req)

		if w.Code != http.StatusBadRequest {
			t.Errorf("expected status %d, got %d", http.StatusBadRequest, w.Code)
		}

		var resp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Code != "VALIDATION_ERROR" {
			t.Errorf("expected code VALIDATION_ERROR, got %s", resp.Code)
		}
	})
}

func TestUnifiedSearchValidation(t *testing.T) {
	h := NewHandlers(nil)

	t.Run("missing query parameter returns error", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search", nil)
		w := httptest.NewRecorder()

		h.Search(w, req)

		if w.Code != http.StatusBadRequest {
			t.Errorf("expected status %d, got %d", http.StatusBadRequest, w.Code)
		}

		var resp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Code != "VALIDATION_ERROR" {
			t.Errorf("expected code VALIDATION_ERROR, got %s", resp.Code)
		}
	})
}

func TestSearchArtistsValidation(t *testing.T) {
	h := NewHandlers(nil)

	t.Run("missing query parameter returns error", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search/artists", nil)
		w := httptest.NewRecorder()

		h.SearchArtists(w, req)

		if w.Code != http.StatusBadRequest {
			t.Errorf("expected status %d, got %d", http.StatusBadRequest, w.Code)
		}

		var resp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Code != "VALIDATION_ERROR" {
			t.Errorf("expected code VALIDATION_ERROR, got %s", resp.Code)
		}
	})
}

func TestSearchReleasesValidation(t *testing.T) {
	h := NewHandlers(nil)

	t.Run("missing query parameter returns error", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/search/releases", nil)
		w := httptest.NewRecorder()

		h.SearchReleases(w, req)

		if w.Code != http.StatusBadRequest {
			t.Errorf("expected status %d, got %d", http.StatusBadRequest, w.Code)
		}

		var resp ErrorResponse
		if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
			t.Fatalf("failed to decode response: %v", err)
		}

		if resp.Code != "VALIDATION_ERROR" {
			t.Errorf("expected code VALIDATION_ERROR, got %s", resp.Code)
		}
	})
}

func TestToReleaseResponsesIncludesNumericID(t *testing.T) {
	responses := toReleaseResponses([]db.Release{
		{
			ID:          42,
			Name:        "Catalog Album",
			Artist:      "Catalog Artist",
			CoverArtURL: sql.NullString{String: "https://example.test/cover.jpg", Valid: true},
			TrackCount:  2,
		},
	})

	if len(responses) != 1 {
		t.Fatalf("expected 1 response, got %d", len(responses))
	}
	if responses[0].ID != 42 {
		t.Fatalf("release response ID = %d, want 42", responses[0].ID)
	}

	encoded, err := json.Marshal(responses[0])
	if err != nil {
		t.Fatalf("marshal release response: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal(encoded, &payload); err != nil {
		t.Fatalf("unmarshal release response: %v", err)
	}
	if payload["id"] != float64(42) {
		t.Fatalf("json id = %#v, want 42", payload["id"])
	}
}
