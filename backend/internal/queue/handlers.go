package queue

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	service         queueHandlerService
	downloadService queueDownloadService
	analysisRepo    *db.AnalysisRepository
	selectionRepo   sourceDecisionRepository
	database        durableDownloadJobStore
}

// These seams keep the HTTP boundary testable without Redis or PostgreSQL.
// Production constructors still receive the concrete services and repository.
type queueHandlerService interface {
	GetQueue(context.Context, string) (*QueueState, error)
	AddToQueue(context.Context, string, int64, string) (*QueueState, error)
	ValidateInsertPosition(context.Context, string, string) error
	AddSourceCandidate(context.Context, string, SourceCandidate, string, string) (*QueueState, error)
	EnsureSourceCandidateWithID(context.Context, string, string, SourceCandidate, string, string) (*QueueState, error)
	RemoveQueueItem(context.Context, string, string) (*QueueState, error)
	QueueItemDownloadJobID(context.Context, string, string) (string, error)
	RetryQueueItem(context.Context, string, string) (*QueueState, string, error)
	ReorderQueueItem(context.Context, string, string, int) (*QueueState, error)
	ClearQueue(context.Context, string) error
	saveQueue(context.Context, string, *QueueState) error
}

type queueDownloadService interface {
	GetJob(context.Context, string) (*download.DownloadJob, error)
	EnqueueSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error)
	EnsureSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error)
	RetryJob(context.Context, string) error
}

type sourceDecisionRepository interface {
	GetDecisionForUser(context.Context, uuid.UUID, uuid.UUID) (*db.SourceSelectionDecision, error)
	AttachDownloadJobForUser(context.Context, uuid.UUID, uuid.UUID, uuid.UUID) error
	AttachDownloadJobWithQueueIntent(context.Context, uuid.UUID, uuid.UUID, uuid.UUID, string, string) (*db.SourceSelectionQueueIntent, error)
}

type durableDownloadJobStore interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

// NewHandlers creates a new Handlers instance
func NewHandlers(service queueHandlerService, downloadServices ...queueDownloadService) *Handlers {
	var downloadService queueDownloadService
	if len(downloadServices) > 0 {
		downloadService = downloadServices[0]
	}
	return &Handlers{service: service, downloadService: downloadService}
}

func NewHandlersWithAnalysis(service queueHandlerService, downloadService queueDownloadService, analysisRepo *db.AnalysisRepository) *Handlers {
	return &Handlers{service: service, downloadService: downloadService, analysisRepo: analysisRepo}
}

// NewHandlersWithSourceSelections enables the decision-gated source ingress.
// Library-track insertion remains independent of this dependency.
func NewHandlersWithSourceSelections(service queueHandlerService, downloadService queueDownloadService, analysisRepo *db.AnalysisRepository, selectionRepo sourceDecisionRepository, database durableDownloadJobStore) *Handlers {
	return &Handlers{service: service, downloadService: downloadService, analysisRepo: analysisRepo, selectionRepo: selectionRepo, database: database}
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
// SourceDecisionResponse is the named stable DTO used consistently in initial,
// live idempotent, and enqueue retry paths.
type SourceDecisionResponse struct {
	Queue         QueueResponse `json:"queue"`
	DownloadJobID string        `json:"downloadJobId"`
	Idempotent    bool          `json:"idempotent"`
}

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
	AnalysisUpdatedAt string           `json:"analysisUpdatedAt,omitempty"`
	CanPlay           bool             `json:"canPlay"`
	CanRetry          bool             `json:"canRetry"`
	CanRemove         bool             `json:"canRemove"`
	AddedAt           time.Time        `json:"addedAt"`
	UpdatedAt         time.Time        `json:"updatedAt"`
}

// AddQueueItemRequest is the mobile-facing queue insertion contract. It accepts
// either an existing playable track or a non-playable discovery source candidate.
type AddQueueItemRequest struct {
	Position         string  `json:"position"`
	TrackID          *int64  `json:"trackId,omitempty"`
	SourceDecisionID *string `json:"sourceDecisionId,omitempty"`
}

const maxAddQueueItemRequestBytes = 8 * 1024

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

	r.Body = http.MaxBytesReader(w, r.Body, maxAddQueueItemRequestBytes)
	var req AddQueueItemRequest
	if err := decodeAddQueueItemRequest(r.Body, &req); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeError(w, http.StatusRequestEntityTooLarge, "QUEUE_ITEM_TOO_LARGE", "queue item request is too large")
			return
		}
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.TrackID != nil {
		if req.SourceDecisionID != nil {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId cannot be combined with source selection fields")
			return
		}
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

	if req.SourceDecisionID == nil || strings.TrimSpace(*req.SourceDecisionID) == "" {
		writeError(w, http.StatusBadRequest, "SOURCE_DECISION_REQUIRED", "sourceDecisionId is required for a new source")
		return
	}
	if h.selectionRepo == nil || h.database == nil {
		writeError(w, http.StatusServiceUnavailable, "SOURCE_SELECTION_UNAVAILABLE", "source selection processing is disabled")
		return
	}
	if h.service == nil || h.downloadService == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "queue and download processing are disabled")
		return
	}
	decisionID, err := uuid.Parse(strings.TrimSpace(*req.SourceDecisionID))
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_DECISION", "sourceDecisionId is invalid")
		return
	}
	decision, err := h.selectionRepo.GetDecisionForUser(r.Context(), userCtx.UserID, decisionID)
	if err != nil {
		writeSourceDecisionError(w, err)
		return
	}
	if decision.Action != db.SourceSelectionActionAccepted && decision.Action != db.SourceSelectionActionOverridden {
		writeError(w, http.StatusConflict, "SOURCE_DECISION_NOT_QUALIFIED", "source decision is not eligible for queueing")
		return
	}
	candidate, mbRecordingID, err := sourceCandidateFromDecision(decision.SelectedCandidate)
	if err != nil {
		writeError(w, http.StatusConflict, "INVALID_SOURCE_DECISION", "source decision candidate is invalid")
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
	jobID := ""
	createdJob := false
	if decision.DownloadJobID.Valid {
		jobID = decision.DownloadJobID.UUID.String()
	} else {
		jobID = uuid.NewString()
		if err := h.createDurableDownloadJob(r.Context(), userCtx.UserID.String(), jobID, candidate, mbRecordingID); err != nil {
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create download job")
			return
		}
		createdJob = true
	}
	intent, err := h.selectionRepo.AttachDownloadJobWithQueueIntent(r.Context(), userCtx.UserID, decisionID, uuid.MustParse(jobID), uuid.NewString(), req.Position)
	if err != nil {
		if createdJob {
			_ = h.deleteDurableDownloadJob(r.Context(), jobID)
		}
		writeSourceDecisionError(w, err)
		return
	}
	existingJob, getErr := h.downloadService.GetJob(r.Context(), jobID)
	jobAlreadyPublished := getErr == nil && existingJob != nil
	job, err := h.enqueueDecisionCandidate(r, userCtx.UserID.String(), jobID, candidate, intent.QueueItemID, intent.InsertPosition, mbRecordingID)
	if err != nil {
		writeQueueDecisionEnqueueError(w, err)
		return
	}
	state, _ := h.service.GetQueue(r.Context(), userCtx.UserID.String())
	status := http.StatusAccepted
	if jobAlreadyPublished {
		status = http.StatusOK
	}
	writeJSON(w, status, SourceDecisionResponse{
		Queue:         h.buildQueueResponse(r.Context(), state, map[string]*download.DownloadJob{jobID: job}),
		DownloadJobID: jobID,
		Idempotent:    !createdJob,
	})
}

func decodeAddQueueItemRequest(body io.Reader, request *AddQueueItemRequest) error {
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(request); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("multiple JSON values")
	}
	return nil
}

func sourceCandidateFromDecision(raw json.RawMessage) (SourceCandidate, *string, error) {
	var candidate SourceCandidate
	if err := json.Unmarshal(raw, &candidate); err != nil {
		return SourceCandidate{}, nil, err
	}
	candidate.SourceURL = strings.TrimSpace(candidate.SourceURL)
	if candidate.CandidateID == "" || candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" || !candidate.Downloadable {
		return SourceCandidate{}, nil, fmt.Errorf("invalid candidate")
	}
	if err := download.ValidateUserFacingURL(candidate.SourceURL); err != nil {
		return SourceCandidate{}, nil, err
	}
	mbRecordingID, err := selectedCandidateMBRecordingID(candidate.Metadata)
	if err != nil {
		return SourceCandidate{}, nil, err
	}
	return candidate, mbRecordingID, nil
}

func selectedCandidateMBRecordingID(metadata map[string]interface{}) (*string, error) {
	var selected *uuid.UUID
	for _, key := range []string{"mbRecordingId", "mb_recording_id"} {
		raw, exists := metadata[key]
		if !exists || raw == nil {
			continue
		}
		value, ok := raw.(string)
		if !ok || strings.TrimSpace(value) == "" {
			return nil, fmt.Errorf("invalid MusicBrainz recording id")
		}
		parsed, err := uuid.Parse(strings.TrimSpace(value))
		if err != nil {
			return nil, fmt.Errorf("invalid MusicBrainz recording id: %w", err)
		}
		if selected != nil && *selected != parsed {
			return nil, fmt.Errorf("conflicting MusicBrainz recording ids")
		}
		selected = &parsed
	}
	if selected == nil {
		return nil, nil
	}
	value := selected.String()
	return &value, nil
}

func (h *Handlers) createDurableDownloadJob(ctx context.Context, userID, jobID string, candidate SourceCandidate, mbRecordingID *string) error {
	metadata, err := json.Marshal(candidate.Metadata)
	if err != nil {
		return err
	}
	// Use exactly the same immutable derived mbRecordingID value that was validated.
	_, err = h.database.ExecContext(ctx, `INSERT INTO download_jobs (id, user_id, url, source_type, status, candidate_id, source_id, title, artist, album, uploader, duration_ms, thumbnail_url, metadata_json, mb_recording_id) VALUES ($1,$2,$3,$4,'queued',$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`, jobID, userID, candidate.SourceURL, candidate.Provider, candidate.CandidateID, candidate.SourceID, candidate.Title, candidate.Artist, candidate.Album, candidate.Uploader, candidate.DurationMs, candidate.ThumbnailURL, metadata, mbRecordingID)
	return err
}
func (h *Handlers) deleteDurableDownloadJob(ctx context.Context, jobID string) error {
	_, err := h.database.ExecContext(ctx, `DELETE FROM download_jobs WHERE id = $1`, jobID)
	return err
}
func (h *Handlers) enqueueDecisionCandidate(r *http.Request, userID, jobID string, candidate SourceCandidate, queueItemID, position string, mbRecordingID *string) (*download.DownloadJob, error) {
	state, err := h.service.GetQueue(r.Context(), userID)
	if err != nil {
		return nil, err
	}
	for _, item := range state.Items {
		if item.DownloadJobID == jobID {
			return h.downloadService.EnsureSourceCandidateWithID(r.Context(), jobID, userID, toDownloadCandidate(candidate), mbRecordingID)
		}
	}
	_, err = h.service.EnsureSourceCandidateWithID(r.Context(), userID, queueItemID, candidate, jobID, position)
	if err != nil {
		return nil, err
	}
	return h.downloadService.EnsureSourceCandidateWithID(r.Context(), jobID, userID, toDownloadCandidate(candidate), mbRecordingID)
}
func toDownloadCandidate(candidate SourceCandidate) download.SourceCandidate {
	return download.SourceCandidate{CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID, SourceURL: candidate.SourceURL, Title: candidate.Title, Artist: candidate.Artist, Album: candidate.Album, Uploader: candidate.Uploader, DurationMs: candidate.DurationMs, ThumbnailURL: candidate.ThumbnailURL, Metadata: candidate.Metadata}
}
func writeSourceDecisionError(w http.ResponseWriter, err error) {
	if errors.Is(err, db.ErrSourceSelectionDecisionNotFound) || errors.Is(err, db.ErrSourceSelectionSessionNotFound) {
		writeError(w, http.StatusNotFound, "SOURCE_DECISION_NOT_FOUND", "source decision was not found")
		return
	}
	if errors.Is(err, db.ErrSourceSelectionConflict) {
		writeError(w, http.StatusConflict, "SOURCE_DECISION_CONFLICT", "source decision conflicts with an existing download job")
		return
	}
	writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "source decision operation failed")
}
func writeQueueDecisionEnqueueError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrInvalidPosition) {
		writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
		return
	}
	writeError(w, http.StatusInternalServerError, "DOWNLOAD_ENQUEUE_FAILED", "failed to enqueue source decision")
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
			if !compact.UpdatedAt.IsZero() {
				response.AnalysisUpdatedAt = compact.UpdatedAt.UTC().Format(time.RFC3339Nano)
			}
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
