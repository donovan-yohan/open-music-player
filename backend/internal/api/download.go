package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

const maxCreateDownloadBodyBytes = 16 * 1024

type trustedDownloadIngestion interface {
	CreateTrustedDownload(context.Context, uuid.UUID, string, download.SourceCandidate, string) (*db.SourceSelectionDownload, error)
	EnqueueTrustedDownload(context.Context, *db.SourceSelectionDownload, db.SourceSelectionDownloadEnqueuer) (*download.DownloadJob, error)
}

type downloadService interface {
	db.SourceSelectionDownloadEnqueuer
	GetJob(context.Context, string) (*download.DownloadJob, error)
	GetUserJobs(context.Context, string) ([]*download.DownloadJob, error)
}

type DownloadHandlers struct {
	downloadService downloadService
	ingestion       trustedDownloadIngestion
}

func NewDownloadHandlers(downloadService downloadService, ingestion ...trustedDownloadIngestion) *DownloadHandlers {
	var trustedIngestion trustedDownloadIngestion
	if len(ingestion) > 0 {
		trustedIngestion = ingestion[0]
	}
	return &DownloadHandlers{
		downloadService: downloadService,
		ingestion:       trustedIngestion,
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
	JobID            string `json:"job_id"`
	Status           string `json:"status"`
	SourceDecisionID string `json:"sourceDecisionId"`
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
	TrackID     *int64  `json:"track_id,omitempty"`
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
	if err := decodeCreateDownloadRequest(w, r, &req); err != nil {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}
	candidate, err := normalizedDirectCandidate(req)
	if err != nil {
		writeDownloadError(w, http.StatusBadRequest, "INVALID_URL", err.Error())
		return
	}
	if h.ingestion == nil || h.downloadService == nil {
		writeDownloadError(w, http.StatusServiceUnavailable, "DOWNLOAD_UNAVAILABLE", "download processing is unavailable")
		return
	}
	persisted, err := h.ingestion.CreateTrustedDownload(r.Context(), userCtx.UserID, db.SourceSelectionOriginDirectURL, candidate, "server-normalized authenticated direct/share URL")
	if err != nil {
		writeDownloadError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to persist trusted download")
		return
	}
	job, err := h.ingestion.EnqueueTrustedDownload(r.Context(), persisted, h.downloadService)
	if err != nil {
		writeDownloadError(w, http.StatusInternalServerError, "DOWNLOAD_ENQUEUE_FAILED", "failed to enqueue trusted download")
		return
	}

	writeDownloadJSON(w, http.StatusCreated, CreateDownloadResponse{
		JobID: job.ID, Status: job.Status, SourceDecisionID: persisted.Decision.ID.String(),
	})
}

func decodeCreateDownloadRequest(w http.ResponseWriter, r *http.Request, req *CreateDownloadRequest) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxCreateDownloadBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(req); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("multiple JSON values")
	}
	if len(strings.TrimSpace(req.URL)) == 0 || len(req.URL) > 4096 || len(req.SourceType) > 50 || len(req.PageMetadata.Title) > 500 || len(req.PageMetadata.Thumbnail) > 2048 {
		return fmt.Errorf("request fields exceed limits")
	}
	return nil
}

func normalizedDirectCandidate(req CreateDownloadRequest) (download.SourceCandidate, error) {
	rawURL := strings.TrimSpace(req.URL)
	if err := download.ValidateUserFacingURL(rawURL); err != nil {
		return download.SourceCandidate{}, fmt.Errorf("url must be an absolute http(s) URL")
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.User != nil {
		return download.SourceCandidate{}, fmt.Errorf("url must be an absolute http(s) URL")
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	if parsed.Scheme != "https" {
		return download.SourceCandidate{}, fmt.Errorf("url must use https")
	}
	parsed.Host = strings.ToLower(parsed.Host)
	parsed.Fragment = ""
	host := parsed.Hostname()
	provider := ""
	switch {
	case host == "youtube.com" || strings.HasSuffix(host, ".youtube.com") || host == "youtu.be":
		provider = "youtube"
	case host == "soundcloud.com" || strings.HasSuffix(host, ".soundcloud.com"):
		provider = "soundcloud"
	default:
		return download.SourceCandidate{}, fmt.Errorf("unsupported source URL")
	}
	normalized := parsed.String()
	digest := sha256.Sum256([]byte(normalized))
	sourceID := fmt.Sprintf("%x", digest[:16])
	title := strings.TrimSpace(req.PageMetadata.Title)
	if title == "" {
		title = "Shared " + provider + " source"
	}
	return download.SourceCandidate{CandidateID: provider + ":" + sourceID, Provider: provider, SourceID: sourceID, SourceURL: normalized, Title: title, ThumbnailURL: strings.TrimSpace(req.PageMetadata.Thumbnail), Metadata: map[string]interface{}{"trustedIngestion": true, "origin": db.SourceSelectionOriginDirectURL}}, nil
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
		TrackID:    job.TrackID,
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
			TrackID:    job.TrackID,
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
