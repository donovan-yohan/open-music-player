package queue

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

// Handlers provides HTTP handlers for queue operations
type Handlers struct {
	service         *Service
	downloadService *download.Service
	analysisRepo    *db.AnalysisRepository
}

// NewHandlers creates a new Handlers instance
func NewHandlers(service *Service, downloadServices ...*download.Service) *Handlers {
	var downloadService *download.Service
	if len(downloadServices) > 0 {
		downloadService = downloadServices[0]
	}
	return &Handlers{service: service, downloadService: downloadService}
}

func NewHandlersWithAnalysis(service *Service, downloadService *download.Service, analysisRepo *db.AnalysisRepository) *Handlers {
	return &Handlers{service: service, downloadService: downloadService, analysisRepo: analysisRepo}
}

// ErrorResponse represents an error response
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// QueueResponse represents the canonical camelCase queue state response.
type QueueResponse struct {
	Items           []QueueItemResponse `json:"items"`
	CurrentPosition int                 `json:"currentPosition"`
	UpdatedAt       time.Time           `json:"updatedAt"`
}

// QueueItemResponse is the canonical camelCase API projection of a queue item.
type QueueItemResponse struct {
	ID                string           `json:"id"`
	QueueItemID       string           `json:"queueItemId"`
	Position          int              `json:"position"`
	Kind              string           `json:"kind"`
	TrackID           *int64           `json:"trackId"`
	PlaybackState     string           `json:"playbackState"`
	DownloadJobID     *string          `json:"downloadJobId"`
	SourceCandidate   *SourceCandidate `json:"sourceCandidate"`
	Title             string           `json:"title,omitempty"`
	Artist            string           `json:"artist,omitempty"`
	Album             string           `json:"album,omitempty"`
	Uploader          string           `json:"uploader,omitempty"`
	DurationMs        int              `json:"durationMs,omitempty"`
	ThumbnailURL      string           `json:"thumbnailUrl,omitempty"`
	Progress          int              `json:"progress"`
	Error             *string          `json:"error"`
	AnalysisStatus    string           `json:"analysisStatus,omitempty"`
	AnalysisSummary   json.RawMessage  `json:"analysisSummary,omitempty"`
	AnalysisOverrides json.RawMessage  `json:"analysisOverrides,omitempty"`
	CanPlay           bool             `json:"canPlay"`
	CanRetry          bool             `json:"canRetry"`
	CanRemove         bool             `json:"canRemove"`
	AddedAt           time.Time        `json:"addedAt"`
	UpdatedAt         time.Time        `json:"updatedAt"`
}

// AddQueueItemRequest is the mobile-facing queue insertion contract. It accepts
// either an existing playable track or a non-playable discovery source candidate.
type AddQueueItemRequest struct {
	Position        string           `json:"position"`
	TrackID         *int64           `json:"trackId,omitempty"`
	SourceCandidate *SourceCandidate `json:"sourceCandidate,omitempty"`
	MBRecordingID   *string          `json:"mbRecordingId,omitempty"`
}

// ReorderQueueRequest represents the item-id based queue reorder contract.
type ReorderQueueRequest struct {
	QueueItemID string `json:"queueItemId"`
	ToPosition  int    `json:"toPosition"`
}

// GetQueue handles GET /api/v1/queue
func (h *Handlers) GetQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	state, err := h.service.GetQueue(r.Context(), userCtx.UserID.String())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get queue")
		return
	}
	jobs := h.resolveDownloadBackedItems(r, userCtx.UserID.String(), state)

	writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), state, jobs))
}

// AddQueueItem handles POST /api/v1/queue/items.
func (h *Handlers) AddQueueItem(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req AddQueueItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.TrackID != nil {
		if *req.TrackID <= 0 {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId must be positive")
			return
		}
		state, err := h.service.AddToQueue(r.Context(), userCtx.UserID.String(), *req.TrackID, req.Position)
		if err != nil {
			if err == ErrInvalidPosition {
				writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
				return
			}
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add track to queue")
			return
		}
		writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), state, nil))
		return
	}

	if req.SourceCandidate == nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId or sourceCandidate is required")
		return
	}
	candidate := req.SourceCandidate
	candidate.SourceURL = strings.TrimSpace(candidate.SourceURL)
	if candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_CANDIDATE", "provider, sourceUrl, and title are required")
		return
	}
	if err := download.ValidateUserFacingURL(candidate.SourceURL); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_URL", "sourceCandidate.sourceUrl must be an absolute http(s) URL")
		return
	}
	if h.service == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "queue processing is disabled")
		return
	}
	if err := h.service.ValidateInsertPosition(r.Context(), userCtx.UserID.String(), req.Position); err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to validate queue position")
		return
	}
	if h.downloadService == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "download processing is disabled")
		return
	}
	jobID := uuid.NewString()
	state, err := h.service.AddSourceCandidate(r.Context(), userCtx.UserID.String(), *candidate, jobID, req.Position)
	if err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add source candidate to queue")
		return
	}
	job, err := h.downloadService.EnqueueSourceCandidateWithID(r.Context(), jobID, userCtx.UserID.String(), download.SourceCandidate{
		CandidateID:  candidate.CandidateID,
		Provider:     candidate.Provider,
		SourceID:     candidate.SourceID,
		SourceURL:    candidate.SourceURL,
		Title:        candidate.Title,
		Artist:       candidate.Artist,
		Album:        candidate.Album,
		Uploader:     candidate.Uploader,
		DurationMs:   candidate.DurationMs,
		ThumbnailURL: candidate.ThumbnailURL,
	}, req.MBRecordingID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create download job")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]interface{}{
		"queue":         h.buildQueueResponse(r.Context(), state, map[string]*download.DownloadJob{job.ID: job}),
		"downloadJobId": job.ID,
	})
}

// RemoveQueueItem handles DELETE /api/v1/queue/items/{queueItemId}
func (h *Handlers) RemoveQueueItem(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	queueItemID := r.PathValue("queueItemId")
	if queueItemID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "queueItemId is required")
		return
	}

	state, err := h.service.RemoveQueueItem(r.Context(), userCtx.UserID.String(), queueItemID)
	if err != nil {
		if err == ErrTrackNotFound || err == ErrInvalidPosition {
			writeError(w, http.StatusNotFound, "QUEUE_ITEM_NOT_FOUND", "queue item not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to remove queue item")
		return
	}

	writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), state, nil))
}

// RetryQueueItem handles POST /api/v1/queue/items/{queueItemId}/retry
func (h *Handlers) RetryQueueItem(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h.downloadService == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "download processing is disabled")
		return
	}

	queueItemID := r.PathValue("queueItemId")
	if queueItemID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "queueItemId is required")
		return
	}

	jobID, err := h.service.QueueItemDownloadJobID(r.Context(), userCtx.UserID.String(), queueItemID)
	if err != nil {
		if err == ErrTrackNotFound {
			writeError(w, http.StatusNotFound, "QUEUE_ITEM_NOT_FOUND", "queue item not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retry queue item")
		return
	}
	job, err := h.downloadService.GetJob(r.Context(), jobID)
	if err != nil || job.UserID != userCtx.UserID.String() {
		writeError(w, http.StatusNotFound, "DOWNLOAD_JOB_NOT_FOUND", "download job not found")
		return
	}
	if err := h.downloadService.RetryJob(r.Context(), jobID); err != nil {
		if errors.Is(err, download.ErrJobNotRetryable) {
			writeError(w, http.StatusConflict, "DOWNLOAD_JOB_NOT_RETRYABLE", "download job is not retryable")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retry download job")
		return
	}
	state, _, err := h.service.RetryQueueItem(r.Context(), userCtx.UserID.String(), queueItemID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to update queue item retry state")
		return
	}

	writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), state, nil))
}

// ReorderQueue handles PUT /api/v1/queue/reorder
func (h *Handlers) ReorderQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req ReorderQueueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.QueueItemID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "queueItemId is required")
		return
	}

	state, err := h.service.ReorderQueueItem(r.Context(), userCtx.UserID.String(), req.QueueItemID, req.ToPosition)
	if err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		if err == ErrTrackNotFound {
			writeError(w, http.StatusNotFound, "QUEUE_ITEM_NOT_FOUND", "queue item not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to reorder queue")
		return
	}

	writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), state, nil))
}

// ClearQueue handles DELETE /api/v1/queue
func (h *Handlers) ClearQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	if err := h.service.ClearQueue(r.Context(), userCtx.UserID.String()); err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to clear queue")
		return
	}

	writeJSON(w, http.StatusOK, h.buildQueueResponse(r.Context(), &QueueState{Items: []QueueItem{}, CurrentPosition: 0, UpdatedAt: time.Now()}, nil))
}

func (h *Handlers) resolveDownloadBackedItems(r *http.Request, userID string, state *QueueState) map[string]*download.DownloadJob {
	jobs := map[string]*download.DownloadJob{}
	if h.downloadService == nil || state == nil {
		return jobs
	}
	changed := false
	for i := range state.Items {
		item := &state.Items[i]
		if item.DownloadJobID == "" || item.PlaybackState == "playable" {
			continue
		}
		job, err := h.downloadService.GetJob(r.Context(), item.DownloadJobID)
		if err != nil || job.UserID != userID {
			continue
		}
		jobs[item.DownloadJobID] = job
		switch job.Status {
		case download.StatusComplete:
			if job.TrackID != nil {
				item.TrackID = job.TrackID
				if item.PlaybackState != "playable" {
					item.PlaybackState = "playable"
					changed = true
				}
			}
		case download.StatusFailed:
			if item.PlaybackState != "failed" {
				item.PlaybackState = "failed"
				changed = true
			}
		case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading:
			if item.PlaybackState != job.Status {
				item.PlaybackState = job.Status
				changed = true
			}
		default:
			if item.PlaybackState != "pendingDownload" {
				item.PlaybackState = "pendingDownload"
				changed = true
			}
		}
	}
	if changed {
		state.UpdatedAt = time.Now()
		_ = h.service.saveQueue(r.Context(), userID, state)
	}
	return jobs
}

func (h *Handlers) buildQueueResponse(ctx context.Context, state *QueueState, jobs map[string]*download.DownloadJob) QueueResponse {
	return buildQueueResponseWithAnalysis(state, jobs, h.compactAnalysisForState(ctx, state, jobs))
}

func (h *Handlers) compactAnalysisForState(ctx context.Context, state *QueueState, jobs map[string]*download.DownloadJob) map[int64]db.AnalysisCompact {
	if h.analysisRepo == nil || state == nil {
		return nil
	}
	seen := map[int64]bool{}
	for _, item := range state.Items {
		if item.TrackID != nil {
			seen[*item.TrackID] = true
		}
		if job := jobs[item.DownloadJobID]; job != nil && job.TrackID != nil {
			seen[*job.TrackID] = true
		}
	}
	trackIDs := make([]int64, 0, len(seen))
	for id := range seen {
		trackIDs = append(trackIDs, id)
	}
	analysis, err := h.analysisRepo.GetCompactByTrackIDs(ctx, trackIDs)
	if err != nil {
		return nil
	}
	return analysis
}

func buildQueueResponse(state *QueueState, jobs map[string]*download.DownloadJob) QueueResponse {
	return buildQueueResponseWithAnalysis(state, jobs, nil)
}

func buildQueueResponseWithAnalysis(state *QueueState, jobs map[string]*download.DownloadJob, analysis map[int64]db.AnalysisCompact) QueueResponse {
	if state == nil {
		state = &QueueState{Items: []QueueItem{}, UpdatedAt: time.Now()}
	}
	items := make([]QueueItemResponse, len(state.Items))
	for i, item := range state.Items {
		items[i] = buildQueueItemResponse(item, state.UpdatedAt, jobs[item.DownloadJobID], analysis)
	}
	return QueueResponse{
		Items:           items,
		CurrentPosition: state.CurrentPosition,
		UpdatedAt:       state.UpdatedAt,
	}
}

func buildQueueItemResponse(item QueueItem, updatedAt time.Time, job *download.DownloadJob, analysis map[int64]db.AnalysisCompact) QueueItemResponse {
	trackID := item.TrackID
	state := projectedPlaybackState(item.PlaybackState)
	progress := 0
	var errText *string

	if state == "playable" {
		progress = 100
	}
	if job != nil {
		progress = job.Progress
		switch job.Status {
		case download.StatusComplete:
			if job.TrackID != nil {
				state = "playable"
				progress = 100
				trackID = job.TrackID
			}
		case download.StatusFailed:
			state = "failed"
			if job.Error != "" {
				err := job.Error
				errText = &err
			}
		case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading:
			state = job.Status
		default:
			state = projectedPlaybackState(item.PlaybackState)
		}
	}
	if progress < 0 {
		progress = 0
	}
	if progress > 100 {
		progress = 100
	}

	kind := "track"
	if item.Source != nil || (item.DownloadJobID != "" && state != "playable") {
		kind = "source"
	}
	if state == "playable" && trackID != nil {
		kind = "track"
	}

	var downloadJobID *string
	if item.DownloadJobID != "" {
		id := item.DownloadJobID
		downloadJobID = &id
	}

	response := QueueItemResponse{
		ID:              item.ID,
		QueueItemID:     item.ID,
		Position:        item.Position,
		Kind:            kind,
		TrackID:         trackID,
		PlaybackState:   state,
		DownloadJobID:   downloadJobID,
		SourceCandidate: item.Source,
		Progress:        progress,
		Error:           errText,
		CanPlay:         state == "playable" && trackID != nil,
		CanRetry:        state == "failed" && item.DownloadJobID != "",
		CanRemove:       true,
		AddedAt:         item.AddedAt,
		UpdatedAt:       updatedAt,
	}
	if item.Source != nil {
		response.Title = item.Source.Title
		response.Artist = item.Source.Artist
		response.Album = item.Source.Album
		response.Uploader = item.Source.Uploader
		response.DurationMs = item.Source.DurationMs
		response.ThumbnailURL = item.Source.ThumbnailURL
	}
	if trackID != nil && analysis != nil {
		if compact, ok := analysis[*trackID]; ok {
			response.AnalysisStatus = compact.Status
			response.AnalysisSummary = compact.SummaryJSON
			response.AnalysisOverrides = compact.OverridesJSON
		}
	}
	return response
}

func projectedPlaybackState(state string) string {
	switch state {
	case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading, "playable", download.StatusFailed:
		return state
	case "pendingDownload", "":
		return download.StatusQueued
	default:
		return state
	}
}

// writeJSON writes a JSON response
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// writeError writes an error response
func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
