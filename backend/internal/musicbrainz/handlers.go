package musicbrainz

import (
	"encoding/json"
	"net/http"
	"strconv"
)

type Handlers struct {
	client *Client
}

func NewHandlers(client *Client) *Handlers {
	return &Handlers{client: client}
}

func (h *Handlers) SearchTracks(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "MISSING_QUERY", "Query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)
	skipCache := r.Header.Get("X-Skip-Cache") == "true"

	results, err := h.client.SearchTracks(r.Context(), query, limit, offset, skipCache)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "SEARCH_FAILED", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, results)
}

func (h *Handlers) SearchArtists(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "MISSING_QUERY", "Query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)
	skipCache := r.Header.Get("X-Skip-Cache") == "true"

	results, err := h.client.SearchArtists(r.Context(), query, limit, offset, skipCache)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "SEARCH_FAILED", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, results)
}

func (h *Handlers) SearchAlbums(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "MISSING_QUERY", "Query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)
	skipCache := r.Header.Get("X-Skip-Cache") == "true"

	results, err := h.client.SearchAlbums(r.Context(), query, limit, offset, skipCache)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "SEARCH_FAILED", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, results)
}

func parsePagination(r *http.Request) (limit, offset int) {
	limit = 20
	offset = 0

	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	if o := r.URL.Query().Get("offset"); o != "" {
		if parsed, err := strconv.Atoi(o); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	return limit, offset
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{
		"code":    code,
		"message": message,
	})
}
