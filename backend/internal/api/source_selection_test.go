package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type fakeSourceSelectionRepository struct {
	decision  *db.SourceSelectionDecision
	createErr error
	getErr    error
	created   struct {
		userID      uuid.UUID
		sessionID   uuid.UUID
		candidateID string
		action      string
		reason      string
	}
}

func (r *fakeSourceSelectionRepository) CreateDiscoveryDecision(_ context.Context, userID, sessionID uuid.UUID, candidateID, action, reason string) (*db.SourceSelectionDecision, error) {
	r.created.userID = userID
	r.created.sessionID = sessionID
	r.created.candidateID = candidateID
	r.created.action = action
	r.created.reason = reason
	if r.createErr != nil {
		return nil, r.createErr
	}
	return r.decision, nil
}

func (r *fakeSourceSelectionRepository) GetDecisionForUser(_ context.Context, _ uuid.UUID, _ uuid.UUID) (*db.SourceSelectionDecision, error) {
	if r.getErr != nil {
		return nil, r.getErr
	}
	return r.decision, nil
}

func (r *fakeSourceSelectionRepository) ListDecisionsForUser(context.Context, uuid.UUID, int, int) ([]db.SourceSelectionDecision, error) {
	return nil, nil
}

func sourceSelectionTestDecision(action string) *db.SourceSelectionDecision {
	return &db.SourceSelectionDecision{
		ID:                     uuid.MustParse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
		SessionID:              uuid.NullUUID{UUID: uuid.MustParse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"), Valid: true},
		SelectedCandidateID:    "youtube:selected",
		RecommendedCandidateID: "youtube:recommended",
		Action:                 action,
		Origin:                 db.SourceSelectionOriginDiscovery,
		SelectedCandidate:      json.RawMessage(`{"candidateId":"youtube:selected"}`),
		SourceQuality:          json.RawMessage(`{}`),
		CreatedAt:              time.Unix(1, 0).UTC(),
	}
}

func sourceSelectionRequest(body string, authenticated bool) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/source-selections", strings.NewReader(body))
	if !authenticated {
		return req
	}
	return req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111")}))
}

func TestSourceSelectionCreateHTTPMappings(t *testing.T) {
	cases := []struct {
		name          string
		authenticated bool
		action        string
		err           error
		wantStatus    int
		wantCode      string
	}{
		{name: "authentication", authenticated: false, wantStatus: http.StatusUnauthorized, wantCode: "UNAUTHORIZED"},
		{name: "accepted", authenticated: true, action: db.SourceSelectionActionAccepted, wantStatus: http.StatusCreated},
		{name: "override", authenticated: true, action: db.SourceSelectionActionOverridden, wantStatus: http.StatusCreated},
		{name: "owner not found", authenticated: true, action: db.SourceSelectionActionAccepted, err: db.ErrSourceSelectionSessionNotFound, wantStatus: http.StatusNotFound, wantCode: "SOURCE_SELECTION_SESSION_NOT_FOUND"},
		{name: "conflict", authenticated: true, action: db.SourceSelectionActionAccepted, err: db.ErrSourceSelectionConflict, wantStatus: http.StatusConflict, wantCode: "SOURCE_SELECTION_CONFLICT"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := &fakeSourceSelectionRepository{decision: sourceSelectionTestDecision(tc.action), createErr: tc.err}
			h := NewSourceSelectionHandlers(repo)
			rec := httptest.NewRecorder()
			h.Create(rec, sourceSelectionRequest(`{"sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","candidateId":"youtube:selected","action":"`+tc.action+`"}`, tc.authenticated))
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if tc.wantCode != "" && !strings.Contains(rec.Body.String(), tc.wantCode) {
				t.Fatalf("response code = %s, want %s", rec.Body.String(), tc.wantCode)
			}
			if tc.wantStatus == http.StatusCreated && !strings.Contains(rec.Body.String(), `"action":"`+tc.action+`"`) {
				t.Fatalf("created response = %s", rec.Body.String())
			}
		})
	}
}

func TestSourceSelectionCreateStrictAndBoundedRequest(t *testing.T) {
	repo := &fakeSourceSelectionRepository{decision: sourceSelectionTestDecision(db.SourceSelectionActionAccepted)}
	h := NewSourceSelectionHandlers(repo)
	cases := []struct {
		name   string
		body   string
		code   string
		status int
	}{
		{name: "unknown field", body: `{"sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","candidateId":"youtube:selected","action":"accepted","sourceUrl":"https://attacker.test"}`, code: "INVALID_SOURCE_SELECTION", status: http.StatusBadRequest},
		{name: "trailing json", body: `{"sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","candidateId":"youtube:selected","action":"accepted"} {}`, code: "INVALID_SOURCE_SELECTION", status: http.StatusBadRequest},
		{name: "too large", body: `{"sessionId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","candidateId":"youtube:selected","action":"accepted","reason":"` + strings.Repeat("x", sourceSelectionMaxRequestBodyBytes) + `"}`, code: "SOURCE_SELECTION_TOO_LARGE", status: http.StatusRequestEntityTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			h.Create(rec, sourceSelectionRequest(tc.body, true))
			if rec.Code != tc.status || !strings.Contains(rec.Body.String(), tc.code) {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestSourceSelectionGetOwnerNotFoundMapping(t *testing.T) {
	h := NewSourceSelectionHandlers(&fakeSourceSelectionRepository{getErr: fmt.Errorf("wrapped: %w", db.ErrSourceSelectionDecisionNotFound)})
	rec := httptest.NewRecorder()
	req := sourceSelectionRequest("", true)
	req.Method = http.MethodGet
	req.SetPathValue("id", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
	h.Get(rec, req)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "SOURCE_SELECTION_NOT_FOUND") {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
}

var _ sourceSelectionRepository = (*fakeSourceSelectionRepository)(nil)
