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
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/research"
)

const (
	researchMaxRequestBodyBytes = 16 * 1024
	researchMaxQueryRunes       = 512
	researchMaxProviders        = 2
	researchMaxLimit            = 25
	researchMaxEventsLimit      = 100
	researchDefaultEventsLimit  = 50
	researchMaxIdempotencyKey   = 128
)

// researchJobService is deliberately limited to the authenticated HTTP surface.
// Keeping the worker/claim lifecycle out of this interface prevents handlers from
// bypassing durable repository transitions.
type researchJobService interface {
	Create(context.Context, research.CreateInput) (*research.Snapshot, error)
	Get(context.Context, string, string) (*research.Snapshot, error)
	Events(context.Context, string, string, int64, int) ([]research.Event, error)
	Cancel(context.Context, string, string) (*research.Snapshot, error)
	Retry(context.Context, string, string) (*research.Snapshot, error)
	Review(context.Context, string, string, research.ReviewInput) (*db.SourceSelectionDecision, error)
}

type researchBaselineBuilder interface {
	Build(context.Context, string, []string, int) (research.RevisionInput, error)
}

// ResearchObserver receives aggregate, bounded research lifecycle observations.
// Arguments intentionally exclude request content, IDs, provider names, URLs, and
// credentials so implementations can export them as metrics safely.
type ResearchObserver interface {
	ObserveResearchCreate(outcome string, baselineLatency time.Duration)
	ObserveResearchSnapshot(status, terminalStatus, degradation, revisionStage, revisionKind string, timeToLatest time.Duration, hasTimeToLatest bool)
	ObserveResearchMutation(operation, outcome string)
	ObserveResearchReview(action, outcome string)
	ObserveResearchToolCalls(calls int)
	ObserveResearchModelAttempt(stage, status string, repair bool, duration time.Duration)
}

type noopResearchObserver struct{}

func (noopResearchObserver) ObserveResearchCreate(string, time.Duration) {}
func (noopResearchObserver) ObserveResearchSnapshot(string, string, string, string, string, time.Duration, bool) {
}
func (noopResearchObserver) ObserveResearchMutation(string, string) {}
func (noopResearchObserver) ObserveResearchReview(string, string)   {}
func (noopResearchObserver) ObserveResearchToolCalls(int)           {}
func (noopResearchObserver) ObserveResearchModelAttempt(string, string, bool, time.Duration) {
}

type ResearchHandlers struct {
	service     researchJobService
	baseline    researchBaselineBuilder
	maxAttempts int
	observer    ResearchObserver
}

// NewResearchHandlers accepts an optional aggregate observer so direct handler
// tests and deployments that do not expose metrics retain the no-op behavior.
func NewResearchHandlers(service researchJobService, baseline researchBaselineBuilder, maxAttempts int, observers ...ResearchObserver) *ResearchHandlers {
	if maxAttempts < 1 || maxAttempts > 10 {
		maxAttempts = 3
	}
	observer := ResearchObserver(noopResearchObserver{})
	if len(observers) > 0 && observers[0] != nil {
		observer = observers[0]
	}
	return &ResearchHandlers{service: service, baseline: baseline, maxAttempts: maxAttempts, observer: observer}
}

type createResearchJobRequest struct {
	Query     string   `json:"query"`
	Providers []string `json:"providers"`
	Limit     int      `json:"limit"`
}

// Create creates the deterministic baseline before the durable job is written.
// The research service canonicalizes and hashes the server-built request; no
// client supplied hash is accepted on this boundary.
func (h *ResearchHandlers) Create(w http.ResponseWriter, r *http.Request) {
	user, ok := researchAuthenticatedUser(w, r)
	if !ok {
		return
	}
	if h == nil || h.service == nil || h.baseline == nil {
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}
	idempotencyKey, err := researchIdempotencyKey(r)
	if err != nil {
		h.observer.ObserveResearchCreate("invalid_request", 0)
		writeResearchError(w, http.StatusBadRequest, "IDEMPOTENCY_KEY_REQUIRED", err.Error())
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, researchMaxRequestBodyBytes)
	var request createResearchJobRequest
	if err := decodeStrictJSON(r, &request); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			h.observer.ObserveResearchCreate("invalid_request", 0)
			writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REQUEST", "research request is too large")
			return
		}
		h.observer.ObserveResearchCreate("invalid_request", 0)
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REQUEST", "research request must be a single JSON object with known fields")
		return
	}
	if err := validateResearchCreateRequest(&request); err != nil {
		h.observer.ObserveResearchCreate("invalid_request", 0)
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REQUEST", err.Error())
		return
	}

	baselineStarted := time.Now()
	baseline, err := h.baseline.Build(r.Context(), request.Query, request.Providers, request.Limit)
	baselineLatency := time.Since(baselineStarted)
	if err != nil {
		h.observer.ObserveResearchCreate("baseline_unavailable", baselineLatency)
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_BASELINE_UNAVAILABLE", "research baseline is temporarily unavailable")
		return
	}
	rawRequest, err := json.Marshal(request)
	if err != nil {
		h.observer.ObserveResearchCreate("unavailable", baselineLatency)
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}

	snapshot, err := h.service.Create(r.Context(), research.CreateInput{
		OwnerID:        user.UserID.String(),
		Request:        rawRequest,
		RetrySafe:      true,
		MaxAttempts:    h.maxAttempts,
		IdempotencyKey: idempotencyKey,
		Baseline:       baseline,
	})
	if err != nil {
		h.observer.ObserveResearchCreate(researchObserverOutcome(err), baselineLatency)
		writeResearchServiceError(w, err)
		return
	}
	h.observer.ObserveResearchCreate("created", baselineLatency)
	h.observeSnapshot(snapshot)
	writeResearchJSON(w, http.StatusCreated, researchSnapshotResponseFrom(snapshot))
}

func (h *ResearchHandlers) Get(w http.ResponseWriter, r *http.Request) {
	user, ok := researchAuthenticatedUser(w, r)
	if !ok {
		return
	}
	if h == nil || h.service == nil {
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}
	jobID, ok := researchJobID(w, r)
	if !ok {
		return
	}
	snapshot, err := h.service.Get(r.Context(), jobID, user.UserID.String())
	if err != nil {
		writeResearchServiceError(w, err)
		return
	}
	h.observeSnapshot(snapshot)
	writeResearchJSON(w, http.StatusOK, researchSnapshotResponseFrom(snapshot))
}

func (h *ResearchHandlers) Events(w http.ResponseWriter, r *http.Request) {
	user, ok := researchAuthenticatedUser(w, r)
	if !ok {
		return
	}
	if h == nil || h.service == nil {
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}
	jobID, ok := researchJobID(w, r)
	if !ok {
		return
	}
	after, limit, err := researchEventsPage(r)
	if err != nil {
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_EVENTS_QUERY", err.Error())
		return
	}
	events, err := h.service.Events(r.Context(), jobID, user.UserID.String(), after, limit)
	if err != nil {
		writeResearchServiceError(w, err)
		return
	}
	writeResearchJSON(w, http.StatusOK, map[string]any{
		"events":        events,
		"afterSequence": after,
		"limit":         limit,
	})
}

func (h *ResearchHandlers) Cancel(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, "cancel", func(ctx context.Context, jobID, ownerID string) (*research.Snapshot, error) {
		return h.service.Cancel(ctx, jobID, ownerID)
	})
}

func (h *ResearchHandlers) Retry(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, "retry", func(ctx context.Context, jobID, ownerID string) (*research.Snapshot, error) {
		return h.service.Retry(ctx, jobID, ownerID)
	})
}

func (h *ResearchHandlers) mutate(w http.ResponseWriter, r *http.Request, operationName string, operation func(context.Context, string, string) (*research.Snapshot, error)) {
	user, ok := researchAuthenticatedUser(w, r)
	if !ok {
		return
	}
	if h == nil || h.service == nil {
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}
	if !researchEmptyBody(w, r) {
		h.observer.ObserveResearchMutation(operationName, "invalid_request")
		return
	}
	jobID, ok := researchJobID(w, r)
	if !ok {
		return
	}
	snapshot, err := operation(r.Context(), jobID, user.UserID.String())
	if err != nil {
		h.observer.ObserveResearchMutation(operationName, researchObserverOutcome(err))
		writeResearchServiceError(w, err)
		return
	}
	h.observer.ObserveResearchMutation(operationName, "success")
	h.observeSnapshot(snapshot)
	writeResearchJSON(w, http.StatusOK, researchSnapshotResponseFrom(snapshot))
}

type researchReviewRequest struct {
	CandidateID string `json:"candidateId"`
	Action      string `json:"action"`
	Reason      string `json:"reason,omitempty"`
}

// Review uses the snapshot's current immutable revision. Clients cannot select
// a historical or foreign revision, nor submit provider or URL-shaped payloads.
func (h *ResearchHandlers) Review(w http.ResponseWriter, r *http.Request) {
	user, ok := researchAuthenticatedUser(w, r)
	if !ok {
		return
	}
	if h == nil || h.service == nil {
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is unavailable")
		return
	}
	jobID, ok := researchJobID(w, r)
	if !ok {
		return
	}
	idempotencyKey, err := researchIdempotencyKey(r)
	if err != nil {
		h.observer.ObserveResearchReview("unknown", "invalid_request")
		writeResearchError(w, http.StatusBadRequest, "IDEMPOTENCY_KEY_REQUIRED", err.Error())
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, researchMaxRequestBodyBytes)
	var request researchReviewRequest
	if err := decodeStrictJSON(r, &request); err != nil {
		h.observer.ObserveResearchReview("unknown", "invalid_request")
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REVIEW", "review request must be a single JSON object with known fields")
		return
	}
	if err := validateResearchReviewRequest(&request); err != nil {
		h.observer.ObserveResearchReview("unknown", "invalid_request")
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REVIEW", err.Error())
		return
	}
	decision, err := h.service.Review(r.Context(), jobID, user.UserID.String(), research.ReviewInput{
		CandidateID:    request.CandidateID,
		Action:         research.ReviewAction(request.Action),
		Reason:         request.Reason,
		IdempotencyKey: idempotencyKey,
		ReviewerID:     user.UserID.String(),
	})
	if err != nil {
		h.observer.ObserveResearchReview(request.Action, researchObserverOutcome(err))
		writeResearchServiceError(w, err)
		return
	}
	h.observer.ObserveResearchReview(request.Action, "created")
	writeSourceSelectionJSON(w, http.StatusCreated, sourceSelectionFromDB(decision))
}

func (h *ResearchHandlers) observeSnapshot(snapshot *research.Snapshot) {
	if h == nil || h.observer == nil || snapshot == nil {
		return
	}
	status := string(snapshot.Job.Status)
	terminalStatus := ""
	if snapshot.Job.Status.Terminal() {
		terminalStatus = status
	}
	degradation := ""
	if snapshot.LatestDegradation != nil {
		degradation = string(snapshot.LatestDegradation.Code)
	}

	stage, kind := "unknown", "unknown"
	var timeToLatest time.Duration
	hasTimeToLatest := false
	for _, revision := range snapshot.Revisions {
		if revision.ID != snapshot.Job.LatestRevisionID || revision.ValidatedAt.IsZero() {
			continue
		}
		kind = string(revision.Kind)
		var payload struct {
			Stage research.RevisionStage `json:"stage"`
		}
		if json.Unmarshal(revision.Payload, &payload) == nil {
			stage = string(payload.Stage)
		}
		if !snapshot.Job.CreatedAt.IsZero() && !revision.ValidatedAt.Before(snapshot.Job.CreatedAt) {
			timeToLatest = revision.ValidatedAt.Sub(snapshot.Job.CreatedAt)
			hasTimeToLatest = true
		}
		break
	}
	h.observer.ObserveResearchSnapshot(status, terminalStatus, degradation, stage, kind, timeToLatest, hasTimeToLatest)

	if snapshot.LatestTerminalTelemetry == nil {
		return
	}
	telemetry := snapshot.LatestTerminalTelemetry
	h.observer.ObserveResearchToolCalls(telemetry.ToolCalls)
	for _, attempt := range telemetry.ModelAttempts {
		h.observer.ObserveResearchModelAttempt(string(attempt.Stage), attempt.Status, attempt.Repair, time.Duration(attempt.DurationMs)*time.Millisecond)
	}
}

func researchObserverOutcome(err error) string {
	switch {
	case errors.Is(err, research.ErrIdempotencyConflict), errors.Is(err, research.ErrInvalidTransition):
		return "conflict"
	case errors.Is(err, research.ErrNotFound), errors.Is(err, research.ErrForbidden):
		return "not_found"
	case errors.Is(err, research.ErrInvalidReview), errors.Is(err, research.ErrInvalidRevision), errors.Is(err, research.ErrInvalidDegradation):
		return "invalid_request"
	case errors.Is(err, research.ErrNoJobAvailable):
		return "capacity_exhausted"
	default:
		return "unavailable"
	}
}

func researchAuthenticatedUser(w http.ResponseWriter, r *http.Request) (*auth.UserContext, bool) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeResearchError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return nil, false
	}
	return user, true
}

func researchJobID(w http.ResponseWriter, r *http.Request) (string, bool) {
	jobID := strings.TrimSpace(r.PathValue("id"))
	if jobID == "" || len(jobID) > 128 || !utf8.ValidString(jobID) {
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_JOB_ID", "research job id is invalid")
		return "", false
	}
	if _, err := uuid.Parse(jobID); err != nil {
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_JOB_ID", "research job id is invalid")
		return "", false
	}
	return jobID, true
}

func researchIdempotencyKey(r *http.Request) (string, error) {
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > researchMaxIdempotencyKey || !utf8.ValidString(key) || strings.ContainsAny(key, "\r\n") {
		return "", errors.New("Idempotency-Key is required and must be at most 128 characters")
	}
	return key, nil
}

func validateResearchCreateRequest(request *createResearchJobRequest) error {
	request.Query = strings.TrimSpace(request.Query)
	if request.Query == "" || !utf8.ValidString(request.Query) || utf8.RuneCountInString(request.Query) > researchMaxQueryRunes {
		return errors.New("query must be between 1 and 512 characters")
	}
	if request.Limit < 1 || request.Limit > researchMaxLimit {
		return errors.New("limit must be between 1 and 25")
	}
	if len(request.Providers) == 0 || len(request.Providers) > researchMaxProviders {
		return errors.New("providers must contain one or two supported providers")
	}
	seen := make(map[string]bool, len(request.Providers))
	for index, provider := range request.Providers {
		provider = strings.TrimSpace(provider)
		if provider != "youtube" && provider != "soundcloud" {
			return errors.New("providers must contain only youtube or soundcloud")
		}
		if seen[provider] {
			return errors.New("providers must not contain duplicates")
		}
		seen[provider] = true
		request.Providers[index] = provider
	}
	return nil
}

func validateResearchReviewRequest(request *researchReviewRequest) error {
	request.CandidateID = strings.TrimSpace(request.CandidateID)
	request.Action = strings.TrimSpace(request.Action)
	request.Reason = strings.TrimSpace(request.Reason)
	if request.CandidateID == "" || len(request.CandidateID) > 256 || !utf8.ValidString(request.CandidateID) || researchReviewURLLike(request.CandidateID) {
		return errors.New("candidateId is invalid")
	}
	if request.Action != string(research.ReviewAccepted) && request.Action != string(research.ReviewOverridden) {
		return errors.New("action must be accepted or overridden")
	}
	if len(request.Reason) > 512 || !utf8.ValidString(request.Reason) || researchReviewURLLike(request.Reason) {
		return errors.New("reason is invalid")
	}
	return nil
}

func researchReviewURLLike(value string) bool {
	value = strings.ToLower(value)
	return strings.Contains(value, "://") || strings.Contains(value, "www.") || strings.Contains(value, "mailto:")
}

func researchEventsPage(r *http.Request) (int64, int, error) {
	query := r.URL.Query()
	for key := range query {
		if key != "afterSequence" && key != "limit" {
			return 0, 0, errors.New("unknown research events query parameter")
		}
	}
	afterRaw, err := researchSingleQueryValue(query, "afterSequence")
	if err != nil {
		return 0, 0, err
	}
	limitRaw, err := researchSingleQueryValue(query, "limit")
	if err != nil {
		return 0, 0, err
	}
	after := int64(0)
	if afterRaw != "" {
		after, err = strconv.ParseInt(afterRaw, 10, 64)
		if err != nil || after < 0 {
			return 0, 0, errors.New("afterSequence must be a non-negative integer")
		}
	}
	limit := researchDefaultEventsLimit
	if limitRaw != "" {
		limit, err = strconv.Atoi(limitRaw)
		if err != nil || limit < 1 || limit > researchMaxEventsLimit {
			return 0, 0, errors.New("limit must be between 1 and 100")
		}
	}
	return after, limit, nil
}

func researchEmptyBody(w http.ResponseWriter, r *http.Request) bool {
	if r.Body == nil {
		return true
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, 1))
	if err != nil || len(data) != 0 {
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REQUEST", "request body is not allowed")
		return false
	}
	return true
}

func researchSingleQueryValue(query map[string][]string, key string) (string, error) {
	values, ok := query[key]
	if !ok {
		return "", nil
	}
	if len(values) != 1 {
		return "", errors.New(key + " must be provided at most once")
	}
	return values[0], nil
}

type researchJobResponse struct {
	ID               string             `json:"id"`
	Status           research.JobStatus `json:"status"`
	RetrySafe        bool               `json:"retrySafe"`
	Attempts         int                `json:"attempts"`
	MaxAttempts      int                `json:"maxAttempts"`
	AvailableAt      any                `json:"availableAt,omitempty"`
	LatestRevision   int                `json:"latestRevision"`
	LatestRevisionID string             `json:"latestRevisionId"`
	CreatedAt        any                `json:"createdAt"`
	UpdatedAt        any                `json:"updatedAt"`
}

type researchSnapshotResponse struct {
	Job                     researchJobResponse         `json:"job"`
	Revisions               []research.Revision         `json:"revisions"`
	LatestDegradation       *research.Degradation       `json:"latestDegradation,omitempty"`
	LatestTerminalTelemetry *research.TerminalTelemetry `json:"latestTerminalTelemetry,omitempty"`
}

func researchSnapshotResponseFrom(snapshot *research.Snapshot) researchSnapshotResponse {
	if snapshot == nil {
		return researchSnapshotResponse{}
	}
	job := snapshot.Job
	telemetry := snapshot.LatestTerminalTelemetry
	if job.Assignment.Variant == research.VariantBoundedAgentDarkLaunch && !snapshot.SurfaceDeepAgentRevisions {
		telemetry = nil
	}
	return researchSnapshotResponse{
		Job: researchJobResponse{
			ID: job.ID, Status: job.Status, RetrySafe: job.RetrySafe, Attempts: job.Attempts, MaxAttempts: job.MaxAttempts,
			AvailableAt: job.AvailableAt, LatestRevision: job.LatestRevision, LatestRevisionID: job.LatestRevisionID,
			CreatedAt: job.CreatedAt, UpdatedAt: job.UpdatedAt,
		},
		Revisions:               append([]research.Revision(nil), snapshot.Revisions...),
		LatestDegradation:       snapshot.LatestDegradation,
		LatestTerminalTelemetry: telemetry,
	}
}

func writeResearchServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, research.ErrNotFound), errors.Is(err, research.ErrForbidden):
		writeResearchError(w, http.StatusNotFound, "RESEARCH_JOB_NOT_FOUND", "research job was not found")
	case errors.Is(err, research.ErrIdempotencyConflict):
		writeResearchError(w, http.StatusConflict, "IDEMPOTENCY_CONFLICT", "Idempotency-Key conflicts with an existing request")
	case errors.Is(err, research.ErrInvalidTransition):
		writeResearchError(w, http.StatusConflict, "RESEARCH_JOB_CONFLICT", "research job cannot transition from its current state")
	case errors.Is(err, research.ErrInvalidReview):
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REVIEW", "research review is invalid")
	case errors.Is(err, research.ErrInvalidRevision), errors.Is(err, research.ErrInvalidDegradation):
		writeResearchError(w, http.StatusBadRequest, "INVALID_RESEARCH_REQUEST", "research request is invalid")
	case errors.Is(err, research.ErrNoJobAvailable):
		writeResearchError(w, http.StatusTooManyRequests, "RESEARCH_CAPACITY_EXHAUSTED", "research capacity is temporarily exhausted")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is temporarily unavailable")
	default:
		writeResearchError(w, http.StatusServiceUnavailable, "RESEARCH_UNAVAILABLE", "research is temporarily unavailable")
	}
}

func writeResearchJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeResearchError(w http.ResponseWriter, status int, code, message string) {
	writeResearchJSON(w, status, map[string]string{"code": code, "message": message})
}
