package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// SourceSelectionHandlers exposes the durable, user-owned audit trail for
// discovery selections. It deliberately accepts only session/candidate/action
// fields; the repository resolves the candidate snapshot server-side.
type SourceSelectionHandlers struct {
	repository sourceSelectionRepository
}

// sourceSelectionRepository is deliberately narrow so HTTP contract mapping can
// be tested without a live PostgreSQL instance.
type sourceSelectionRepository interface {
	CreateDiscoveryDecision(context.Context, uuid.UUID, uuid.UUID, string, string, string) (*db.SourceSelectionDecision, error)
	GetDecisionForUser(context.Context, uuid.UUID, uuid.UUID) (*db.SourceSelectionDecision, error)
	ListDecisionsForUser(context.Context, uuid.UUID, int, int) ([]db.SourceSelectionDecision, error)
}

const sourceSelectionMaxRequestBodyBytes = 8 * 1024

func NewSourceSelectionHandlers(repository sourceSelectionRepository) *SourceSelectionHandlers {
	return &SourceSelectionHandlers{repository: repository}
}

type createSourceSelectionRequest struct {
	SessionID   string `json:"sessionId"`
	CandidateID string `json:"candidateId"`
	Action      string `json:"action"`
	Reason      string `json:"reason,omitempty"`
}

type sourceSelectionResponse struct {
	ID                     string          `json:"id"`
	SessionID              *string         `json:"sessionId,omitempty"`
	SelectedCandidateID    string          `json:"selectedCandidateId"`
	RecommendedCandidateID string          `json:"recommendedCandidateId"`
	Action                 string          `json:"action"`
	Origin                 string          `json:"origin"`
	Reason                 *string         `json:"reason,omitempty"`
	SelectedCandidate      json.RawMessage `json:"selectedCandidate"`
	SourceQuality          json.RawMessage `json:"sourceQuality"`
	DownloadJobID          *string         `json:"downloadJobId,omitempty"`
	TrackID                *int64          `json:"trackId,omitempty"`
	CreatedAt              time.Time       `json:"createdAt"`
}

func (h *SourceSelectionHandlers) Create(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeSourceSelectionError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.repository == nil {
		writeSourceSelectionError(w, http.StatusServiceUnavailable, "SOURCE_SELECTION_UNAVAILABLE", "source selections are unavailable")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, sourceSelectionMaxRequestBodyBytes)
	var request createSourceSelectionRequest
	if err := decodeStrictJSON(r, &request); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeSourceSelectionError(w, http.StatusRequestEntityTooLarge, "SOURCE_SELECTION_TOO_LARGE", "source selection request is too large")
			return
		}
		writeSourceSelectionError(w, http.StatusBadRequest, "INVALID_SOURCE_SELECTION", "invalid source selection request")
		return
	}
	sessionID, err := uuid.Parse(strings.TrimSpace(request.SessionID))
	if err != nil || strings.TrimSpace(request.CandidateID) == "" {
		writeSourceSelectionError(w, http.StatusBadRequest, "INVALID_SOURCE_SELECTION", "sessionId and candidateId are required")
		return
	}
	decision, err := h.repository.CreateDiscoveryDecision(r.Context(), user.UserID, sessionID, strings.TrimSpace(request.CandidateID), strings.TrimSpace(request.Action), request.Reason)
	if err != nil {
		writeSourceSelectionRepositoryError(w, err)
		return
	}
	writeSourceSelectionJSON(w, http.StatusCreated, sourceSelectionFromDB(decision))
}

func (h *SourceSelectionHandlers) Get(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeSourceSelectionError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.repository == nil {
		writeSourceSelectionError(w, http.StatusServiceUnavailable, "SOURCE_SELECTION_UNAVAILABLE", "source selections are unavailable")
		return
	}
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		writeSourceSelectionError(w, http.StatusBadRequest, "INVALID_SOURCE_SELECTION_ID", "source selection id is invalid")
		return
	}
	decision, err := h.repository.GetDecisionForUser(r.Context(), user.UserID, id)
	if err != nil {
		writeSourceSelectionRepositoryError(w, err)
		return
	}
	writeSourceSelectionJSON(w, http.StatusOK, sourceSelectionFromDB(decision))
}

func (h *SourceSelectionHandlers) List(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeSourceSelectionError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.repository == nil {
		writeSourceSelectionError(w, http.StatusServiceUnavailable, "SOURCE_SELECTION_UNAVAILABLE", "source selections are unavailable")
		return
	}
	limit, offset, err := sourceSelectionPage(r)
	if err != nil {
		writeSourceSelectionError(w, http.StatusBadRequest, "INVALID_PAGINATION", "limit and offset must be non-negative integers")
		return
	}
	decisions, err := h.repository.ListDecisionsForUser(r.Context(), user.UserID, limit, offset)
	if err != nil {
		writeSourceSelectionRepositoryError(w, err)
		return
	}
	items := make([]sourceSelectionResponse, 0, len(decisions))
	for i := range decisions {
		items = append(items, sourceSelectionFromDB(&decisions[i]))
	}
	writeSourceSelectionJSON(w, http.StatusOK, map[string]any{"items": items, "limit": limit, "offset": offset})
}

func sourceSelectionPage(r *http.Request) (int, int, error) {
	limit, offset := 20, 0
	var err error
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 100 {
			return 0, 0, errors.New("invalid limit")
		}
	}
	if raw := r.URL.Query().Get("offset"); raw != "" {
		offset, err = strconv.Atoi(raw)
		if err != nil || offset < 0 {
			return 0, 0, errors.New("invalid offset")
		}
	}
	return limit, offset, nil
}

func sourceSelectionFromDB(decision *db.SourceSelectionDecision) sourceSelectionResponse {
	response := sourceSelectionResponse{ID: decision.ID.String(), SelectedCandidateID: decision.SelectedCandidateID, RecommendedCandidateID: decision.RecommendedCandidateID, Action: decision.Action, Origin: decision.Origin, SelectedCandidate: decision.SelectedCandidate, SourceQuality: decision.SourceQuality, CreatedAt: decision.CreatedAt}
	if decision.SessionID.Valid {
		value := decision.SessionID.UUID.String()
		response.SessionID = &value
	}
	if decision.Reason.Valid {
		value := decision.Reason.String
		response.Reason = &value
	}
	if decision.DownloadJobID.Valid {
		value := decision.DownloadJobID.UUID.String()
		response.DownloadJobID = &value
	}
	if decision.TrackID.Valid {
		value := decision.TrackID.Int64
		response.TrackID = &value
	}
	return response
}

func decodeStrictJSON(r *http.Request, value any) error {
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("request must contain one JSON object")
	}
	return nil
}

func writeSourceSelectionRepositoryError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, db.ErrSourceSelectionSessionNotFound):
		writeSourceSelectionError(w, http.StatusNotFound, "SOURCE_SELECTION_SESSION_NOT_FOUND", "source selection session was not found or has expired")
	case errors.Is(err, db.ErrSourceSelectionDecisionNotFound):
		writeSourceSelectionError(w, http.StatusNotFound, "SOURCE_SELECTION_NOT_FOUND", "source selection was not found")
	case errors.Is(err, db.ErrSourceSelectionConflict), errors.Is(err, db.ErrSourceSelectionConsumed):
		writeSourceSelectionError(w, http.StatusConflict, "SOURCE_SELECTION_CONFLICT", "source selection conflicts with an existing decision")
	case errors.Is(err, db.ErrInvalidSourceSelection):
		writeSourceSelectionError(w, http.StatusBadRequest, "INVALID_SOURCE_SELECTION", "source selection is invalid")
	default:
		writeSourceSelectionError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "source selection operation failed")
	}
}

func writeSourceSelectionJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func writeSourceSelectionError(w http.ResponseWriter, status int, code, message string) {
	writeSourceSelectionJSON(w, status, map[string]string{"code": code, "message": message})
}
