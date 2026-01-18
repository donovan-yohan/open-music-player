package validators

import (
	"encoding/json"
	"net/http"
)

// Handlers provides HTTP handlers for URL validation
type Handlers struct {
	registry *Registry
}

// NewHandlers creates a new Handlers instance
func NewHandlers(registry *Registry) *Handlers {
	return &Handlers{
		registry: registry,
	}
}

// ValidateURLRequest is the request body for URL validation
type ValidateURLRequest struct {
	URL string `json:"url"`
}

// ValidateURLResponse is the response for URL validation
type ValidateURLResponse struct {
	ValidationResult
}

// SupportedSourcesResponse is the response for listing supported sources
type SupportedSourcesResponse struct {
	Sources []SourceType `json:"sources"`
}

// ErrorResponse represents an error response
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ValidateURL handles POST /api/v1/validate/url
func (h *Handlers) ValidateURL(w http.ResponseWriter, r *http.Request) {
	var req ValidateURLRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid JSON body")
		return
	}

	if req.URL == "" {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "url field is required")
		return
	}

	result := h.registry.Validate(req.URL)

	w.Header().Set("Content-Type", "application/json")
	if result.Valid {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusUnprocessableEntity)
	}
	json.NewEncoder(w).Encode(ValidateURLResponse{ValidationResult: result})
}

// ValidateURLQuery handles GET /api/v1/validate/url?url=...
func (h *Handlers) ValidateURLQuery(w http.ResponseWriter, r *http.Request) {
	url := r.URL.Query().Get("url")

	if url == "" {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "url query parameter is required")
		return
	}

	result := h.registry.Validate(url)

	w.Header().Set("Content-Type", "application/json")
	if result.Valid {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusUnprocessableEntity)
	}
	json.NewEncoder(w).Encode(ValidateURLResponse{ValidationResult: result})
}

// GetSupportedSources handles GET /api/v1/validate/sources
func (h *Handlers) GetSupportedSources(w http.ResponseWriter, r *http.Request) {
	sources := h.registry.GetSupportedSources()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(SupportedSourcesResponse{Sources: sources})
}

func writeErrorResponse(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
