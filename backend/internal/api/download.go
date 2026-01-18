package api

import (
	"encoding/json"
	"net/http"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/download"
)

type DownloadHandlers struct {
	downloadService *download.Service
}

func NewDownloadHandlers(downloadService *download.Service) *DownloadHandlers {
	return &DownloadHandlers{
		downloadService: downloadService,
	}
}

// CreateDownloadRequest represents the request body for creating a download
type CreateDownloadRequest struct {
	URL          string       `json:"url"`
	SourceType   string       `json:"source_type"`
	PageMetadata PageMetadata `json:"page_metadata,omitempty"`
}

// PageMetadata contains metadata extracted from the source page
type PageMetadata struct {
	Title     string `json:"title,omitempty"`
	Thumbnail string `json:"thumbnail,omitempty"`
}

// CreateDownloadResponse represents the response for a created download job
type CreateDownloadResponse struct {
	JobID  string `json:"job_id"`
	Status string `json:"status"`
}

// DownloadErrorResponse represents an error response
type DownloadErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// GetJobResponse represents a job status response
type GetJobResponse struct {
	JobID       string  `json:"job_id"`
	Status      string  `json:"status"`
	Progress    int     `json:"progress"`
	Error       string  `json:"error,omitempty"`
	URL         string  `json:"url"`
	SourceType  string  `json:"source_type"`
	CreatedAt   string  `json:"created_at"`
	StartedAt   *string `json:"started_at,omitempty"`
	CompletedAt *string `json:"completed_at,omitempty"`
}

// CreateDownload handles POST /api/v1/downloads
func (h *DownloadHandlers) CreateDownload(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDownloadError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req CreateDownloadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.URL == "" {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_REQUEST", "url is required")
		return
	}

	if req.SourceType == "" {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_REQUEST", "source_type is required")
		return
	}

	// Validate source type
	validSourceTypes := map[string]bool{
		"youtube":    true,
		"soundcloud": true,
	}
	if !validSourceTypes[req.SourceType] {
		writeDownloadError(w, http.StatusBadRequest, "UNSUPPORTED_SOURCE", "unsupported source type")
		return
	}

	job, err := h.downloadService.EnqueueDownload(r.Context(), userCtx.UserID.String(), req.URL, req.SourceType, nil)
	if err != nil {
		writeDownloadError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create download job")
		return
	}

	writeDownloadJSON(w, http.StatusCreated, CreateDownloadResponse{
		JobID:  job.ID,
		Status: job.Status,
	})
}

// GetJob handles GET /api/v1/downloads/{job_id}
func (h *DownloadHandlers) GetJob(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDownloadError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	jobID := r.PathValue("job_id")
	if jobID == "" {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_REQUEST", "job_id is required")
		return
	}

	job, err := h.downloadService.GetJob(r.Context(), jobID)
	if err != nil {
		writeDownloadError(w, http.StatusNotFound, "JOB_NOT_FOUND", "job not found")
		return
	}

	// Verify job belongs to user
	if job.UserID != userCtx.UserID.String() {
		writeDownloadError(w, http.StatusNotFound, "JOB_NOT_FOUND", "job not found")
		return
	}

	resp := GetJobResponse{
		JobID:      job.ID,
		Status:     job.Status,
		Progress:   job.Progress,
		Error:      job.Error,
		URL:        job.URL,
		SourceType: job.SourceType,
		CreatedAt:  job.CreatedAt.Format("2006-01-02T15:04:05Z"),
	}

	if job.StartedAt != nil {
		startedAt := job.StartedAt.Format("2006-01-02T15:04:05Z")
		resp.StartedAt = &startedAt
	}
	if job.CompletedAt != nil {
		completedAt := job.CompletedAt.Format("2006-01-02T15:04:05Z")
		resp.CompletedAt = &completedAt
	}

	writeDownloadJSON(w, http.StatusOK, resp)
}

// GetUserJobs handles GET /api/v1/downloads
func (h *DownloadHandlers) GetUserJobs(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDownloadError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	jobs, err := h.downloadService.GetUserJobs(r.Context(), userCtx.UserID.String())
	if err != nil {
		writeDownloadError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve jobs")
		return
	}

	responses := make([]GetJobResponse, 0, len(jobs))
	for _, job := range jobs {
		resp := GetJobResponse{
			JobID:      job.ID,
			Status:     job.Status,
			Progress:   job.Progress,
			Error:      job.Error,
			URL:        job.URL,
			SourceType: job.SourceType,
			CreatedAt:  job.CreatedAt.Format("2006-01-02T15:04:05Z"),
		}
		if job.StartedAt != nil {
			startedAt := job.StartedAt.Format("2006-01-02T15:04:05Z")
			resp.StartedAt = &startedAt
		}
		if job.CompletedAt != nil {
			completedAt := job.CompletedAt.Format("2006-01-02T15:04:05Z")
			resp.CompletedAt = &completedAt
		}
		responses = append(responses, resp)
	}

	writeDownloadJSON(w, http.StatusOK, map[string]interface{}{
		"jobs": responses,
	})
}

func writeDownloadJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeDownloadError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(DownloadErrorResponse{
		Code:    code,
		Message: message,
	})
}
