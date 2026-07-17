package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"gopkg.in/yaml.v3"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/research"
)

const researchTestJobID = "36ba7264-6717-4fe5-bccd-6a94edf24a10"

func TestResearchCreateBuildsBaselineAndLeavesHashToService(t *testing.T) {
	service := &fakeResearchService{snapshot: researchSnapshot(researchTestJobID)}
	baseline := &fakeResearchBaseline{}
	handlers := NewResearchHandlers(service, baseline, 3)
	userID := uuid.New()

	req := newResearchAuthedRequest(userID, http.MethodPost, "/api/v1/research-jobs", []byte(`{"query":"Night drive","providers":["youtube","soundcloud"],"limit":5}`))
	req.Header.Set("Idempotency-Key", "create-1")
	recorder := httptest.NewRecorder()

	handlers.Create(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if baseline.query != "Night drive" || baseline.limit != 5 || len(baseline.providers) != 2 {
		t.Fatalf("baseline call = %#v", baseline)
	}
	if service.createInput.OwnerID != userID.String() || service.createInput.IdempotencyKey != "create-1" || !service.createInput.RetrySafe || service.createInput.MaxAttempts != 3 {
		t.Fatalf("create input = %#v", service.createInput)
	}
	if service.createInput.RequestHash != "" {
		t.Fatalf("handler passed client request hash %q; the service must canonicalize it", service.createInput.RequestHash)
	}
	if !bytes.Equal(service.createInput.Request, []byte(`{"query":"Night drive","providers":["youtube","soundcloud"],"limit":5}`)) {
		t.Fatalf("request = %s", service.createInput.Request)
	}
	var response map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	job, ok := response["job"].(map[string]any)
	if !ok || job["id"] != researchTestJobID || job["status"] != string(research.JobQueued) {
		t.Fatalf("response job = %#v", response["job"])
	}
	if _, leaked := job["ownerId"]; leaked {
		t.Fatalf("response leaked owner: %#v", job)
	}
	if _, leaked := job["requestHash"]; leaked {
		t.Fatalf("response leaked request hash: %#v", job)
	}
}

func TestResearchCreateRequiresIdempotencyAndStrictBoundedRequest(t *testing.T) {
	service := &fakeResearchService{snapshot: researchSnapshot(researchTestJobID)}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	userID := uuid.New()

	for name, body := range map[string][]byte{
		"missing key":        []byte(`{"query":"x","providers":["youtube"],"limit":1}`),
		"unknown property":   []byte(`{"query":"x","providers":["youtube"],"limit":1,"requestHash":"client"}`),
		"invalid provider":   []byte(`{"query":"x","providers":["spotify"],"limit":1}`),
		"duplicate provider": []byte(`{"query":"x","providers":["youtube","youtube"],"limit":1}`),
		"invalid limit":      []byte(`{"query":"x","providers":["youtube"],"limit":26}`),
	} {
		t.Run(name, func(t *testing.T) {
			req := newResearchAuthedRequest(userID, http.MethodPost, "/api/v1/research-jobs", body)
			if name != "missing key" {
				req.Header.Set("Idempotency-Key", "key")
			}
			recorder := httptest.NewRecorder()
			handlers.Create(recorder, req)
			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestResearchServiceErrorsAreOwnershipSafeAndTyped(t *testing.T) {
	userID := uuid.New()
	for name, testCase := range map[string]struct {
		err  error
		want int
	}{
		"foreign job":        {research.ErrForbidden, http.StatusNotFound},
		"missing job":        {research.ErrNotFound, http.StatusNotFound},
		"idempotency":        {research.ErrIdempotencyConflict, http.StatusConflict},
		"invalid transition": {research.ErrInvalidTransition, http.StatusConflict},
		"invalid review":     {research.ErrInvalidReview, http.StatusBadRequest},
		"capacity":           {research.ErrNoJobAvailable, http.StatusTooManyRequests},
		"unavailable":        {context.DeadlineExceeded, http.StatusServiceUnavailable},
	} {
		t.Run(name, func(t *testing.T) {
			service := &fakeResearchService{getErr: testCase.err, snapshot: researchSnapshot(researchTestJobID)}
			handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
			req := newResearchAuthedRequest(userID, http.MethodGet, "/api/v1/research-jobs/"+researchTestJobID, nil)
			req.SetPathValue("id", researchTestJobID)
			recorder := httptest.NewRecorder()
			handlers.Get(recorder, req)
			if recorder.Code != testCase.want {
				t.Fatalf("status = %d, want %d; body = %s", recorder.Code, testCase.want, recorder.Body.String())
			}
		})
	}
}

func TestResearchEventsAreOrderedAndStrictlyBounded(t *testing.T) {
	userID := uuid.New()
	service := &fakeResearchService{events: []research.Event{{JobID: researchTestJobID, Sequence: 8, Kind: research.EventCreated}, {JobID: researchTestJobID, Sequence: 9, Kind: research.EventRevisionAppended}}}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	req := newResearchAuthedRequest(userID, http.MethodGet, "/api/v1/research-jobs/"+researchTestJobID+"/events?afterSequence=7&limit=2", nil)
	req.SetPathValue("id", researchTestJobID)
	recorder := httptest.NewRecorder()

	handlers.Events(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if service.after != 7 || service.eventsLimit != 2 {
		t.Fatalf("events page = after %d limit %d", service.after, service.eventsLimit)
	}
	for _, rawQuery := range []string{"afterSequence=-1", "limit=101", "afterSequence=1&afterSequence=2", "cursor=unexpected"} {
		req := newResearchAuthedRequest(userID, http.MethodGet, "/api/v1/research-jobs/"+researchTestJobID+"/events?"+rawQuery, nil)
		req.SetPathValue("id", researchTestJobID)
		recorder := httptest.NewRecorder()
		handlers.Events(recorder, req)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("query %q status = %d, body = %s", rawQuery, recorder.Code, recorder.Body.String())
		}
	}
}

func TestResearchCancelAndRetryRejectBodies(t *testing.T) {
	service := &fakeResearchService{snapshot: researchSnapshot(researchTestJobID)}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	for _, operation := range []struct {
		name    string
		handler func(http.ResponseWriter, *http.Request)
	}{
		{name: "cancel", handler: handlers.Cancel},
		{name: "retry", handler: handlers.Retry},
	} {
		t.Run(operation.name, func(t *testing.T) {
			req := newResearchAuthedRequest(uuid.New(), http.MethodPost, "/api/v1/research-jobs/"+researchTestJobID+"/"+operation.name, []byte(`{}`))
			req.SetPathValue("id", researchTestJobID)
			recorder := httptest.NewRecorder()
			operation.handler(recorder, req)
			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestResearchRejectsMalformedJobIDBeforeServiceLookup(t *testing.T) {
	service := &fakeResearchService{snapshot: researchSnapshot(researchTestJobID)}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	req := newResearchAuthedRequest(uuid.New(), http.MethodGet, "/api/v1/research-jobs/not-a-uuid", nil)
	req.SetPathValue("id", "not-a-uuid")
	recorder := httptest.NewRecorder()

	handlers.Get(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
}

func TestResearchReviewReturnsSourceSelectionDecisionAndRejectsForbiddenPayload(t *testing.T) {
	userID := uuid.New()
	snapshot := researchSnapshot(researchTestJobID)
	snapshot.Job.LatestRevisionID = "revision-2"
	snapshot.Job.LatestRevision = 2
	service := &fakeResearchService{snapshot: snapshot}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	req := newResearchAuthedRequest(userID, http.MethodPost, "/api/v1/research-jobs/"+researchTestJobID+"/reviews", []byte(`{"candidateId":"youtube:abc","action":"accepted","reason":"best match"}`))
	req.SetPathValue("id", researchTestJobID)
	req.Header.Set("Idempotency-Key", "review-1")
	recorder := httptest.NewRecorder()

	handlers.Review(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if service.review.CandidateID != "youtube:abc" || service.review.Action != research.ReviewAccepted {
		t.Fatalf("review = %#v", service.review)
	}
	var response sourceSelectionResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.Origin != db.SourceSelectionOriginResearch || response.SessionID != nil || response.SelectedCandidateID != "youtube:abc" {
		t.Fatalf("review response = %#v err=%v", response, err)
	}
	for _, body := range [][]byte{
		[]byte(`{"candidateId":"youtube:abc","action":"accepted","revisionId":"client-selected"}`),
		[]byte(`{"candidateId":"youtube:abc","action":"accepted","sessionId":"client-session"}`),
		[]byte(`{"candidateId":"youtube:abc","action":"accepted","provider":"youtube"}`),
		[]byte(`{"candidateId":"https://example.test","action":"accepted"}`),
		[]byte(`{"candidateId":"youtube:abc","action":"accepted","reason":"https://example.test"}`),
	} {
		req := newResearchAuthedRequest(userID, http.MethodPost, "/api/v1/research-jobs/"+researchTestJobID+"/reviews", body)
		req.SetPathValue("id", researchTestJobID)
		req.Header.Set("Idempotency-Key", "review-invalid")
		recorder := httptest.NewRecorder()
		handlers.Review(recorder, req)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("body %s status = %d, response = %s", body, recorder.Code, recorder.Body.String())
		}
	}
}

func TestResearchReviewMapsNondownloadableCandidateRejection(t *testing.T) {
	service := &fakeResearchService{reviewErr: research.ErrInvalidReview}
	handlers := NewResearchHandlers(service, &fakeResearchBaseline{}, 3)
	req := newResearchAuthedRequest(uuid.New(), http.MethodPost, "/api/v1/research-jobs/"+researchTestJobID+"/reviews", []byte(`{"candidateId":"youtube:not-downloadable","action":"accepted"}`))
	req.SetPathValue("id", researchTestJobID)
	req.Header.Set("Idempotency-Key", "review-not-downloadable")
	recorder := httptest.NewRecorder()

	handlers.Review(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response map[string]string
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response["code"] != "INVALID_RESEARCH_REVIEW" {
		t.Fatalf("response = %#v, err = %v", response, err)
	}
}

func TestResearchCandidateSourceQualityRecommendationOpenAPIContract(t *testing.T) {
	document, err := os.ReadFile("../../api/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	type schema struct {
		Properties map[string]schema `yaml:"properties"`
		Enum       []string          `yaml:"enum"`
	}
	var specification struct {
		Components struct {
			Schemas map[string]schema `yaml:"schemas"`
		} `yaml:"components"`
	}
	if err := yaml.Unmarshal(document, &specification); err != nil {
		t.Fatalf("decode OpenAPI: %v", err)
	}

	got := specification.Components.Schemas["ResearchCandidate"].Properties["sourceQuality"].Properties["recommendation"].Enum
	want := []string{
		discovery.SourceQualityPreferred,
		discovery.SourceQualityAcceptable,
		discovery.SourceQualityReview,
		discovery.SourceQualityAvoid,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ResearchCandidate sourceQuality recommendation enum = %v, want production constants %v", got, want)
	}
}

func TestResearchRoutesRequireAuthBeforeDisabledAvailability(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(nil)})
	for _, endpoint := range []struct {
		method string
		path   string
	}{
		{http.MethodPost, "/api/v1/research-jobs"},
		{http.MethodGet, "/api/v1/research-jobs/job-1"},
		{http.MethodGet, "/api/v1/research-jobs/job-1/events"},
		{http.MethodPost, "/api/v1/research-jobs/job-1/cancel"},
		{http.MethodPost, "/api/v1/research-jobs/job-1/retry"},
		{http.MethodPost, "/api/v1/research-jobs/job-1/reviews"},
	} {
		req := httptest.NewRequest(endpoint.method, endpoint.path, nil)
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, req)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s = %d, want %d", endpoint.method, endpoint.path, recorder.Code, http.StatusUnauthorized)
		}
	}
}

type fakeResearchBaseline struct {
	query     string
	providers []string
	limit     int
	err       error
}

func (b *fakeResearchBaseline) Build(_ context.Context, query string, providers []string, limit int) (research.RevisionInput, error) {
	b.query = query
	b.providers = append([]string(nil), providers...)
	b.limit = limit
	if b.err != nil {
		return research.RevisionInput{}, b.err
	}
	return research.RevisionInput{ID: "baseline-1", Payload: json.RawMessage(`{"schemaVersion":"omp.research.revision.v1","stage":"baseline","query":"Night drive","candidates":[],"recommendations":[],"provenance":{"source":"test"},"timing":{}}`)}, nil
}

type fakeResearchService struct {
	createInput research.CreateInput
	snapshot    *research.Snapshot
	createErr   error
	getErr      error
	eventsErr   error
	mutateErr   error
	reviewErr   error
	events      []research.Event
	after       int64
	eventsLimit int
	review      research.ReviewInput
}

func (s *fakeResearchService) Create(_ context.Context, input research.CreateInput) (*research.Snapshot, error) {
	s.createInput = input
	return s.snapshot, s.createErr
}
func (s *fakeResearchService) Get(_ context.Context, _, _ string) (*research.Snapshot, error) {
	return s.snapshot, s.getErr
}
func (s *fakeResearchService) Events(_ context.Context, _, _ string, after int64, limit int) ([]research.Event, error) {
	s.after, s.eventsLimit = after, limit
	return append([]research.Event(nil), s.events...), s.eventsErr
}
func (s *fakeResearchService) Cancel(_ context.Context, _, _ string) (*research.Snapshot, error) {
	return s.snapshot, s.mutateErr
}
func (s *fakeResearchService) Retry(_ context.Context, _, _ string) (*research.Snapshot, error) {
	return s.snapshot, s.mutateErr
}
func (s *fakeResearchService) Review(_ context.Context, _, _ string, input research.ReviewInput) (*db.SourceSelectionDecision, error) {
	s.review = input
	if s.reviewErr != nil {
		return nil, s.reviewErr
	}
	return &db.SourceSelectionDecision{ID: uuid.New(), SelectedCandidateID: input.CandidateID, RecommendedCandidateID: input.CandidateID, Action: string(input.Action), Origin: db.SourceSelectionOriginResearch, SelectedCandidate: json.RawMessage(`{"candidateId":"youtube:abc"}`), SourceQuality: json.RawMessage(`{}`), CreatedAt: time.Now().UTC()}, nil
}

func newResearchAuthedRequest(userID uuid.UUID, method, target string, body []byte) *http.Request {
	request := httptest.NewRequest(method, target, bytes.NewReader(body))
	return request.WithContext(context.WithValue(request.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID}))
}

func researchSnapshot(id string) *research.Snapshot {
	now := time.Date(2026, 7, 17, 1, 2, 3, 0, time.UTC)
	return &research.Snapshot{
		Job:       research.Job{ID: id, OwnerID: "owner", RequestHash: "secret-hash", IdempotencyKey: "secret-key", Status: research.JobQueued, RetrySafe: true, MaxAttempts: 3, AvailableAt: now, LatestRevision: 1, LatestRevisionID: "baseline-1", CreatedAt: now, UpdatedAt: now},
		Revisions: []research.Revision{{ID: "baseline-1", JobID: id, Number: 1, Kind: research.RevisionBaseline, Payload: json.RawMessage(`{"schemaVersion":"omp.research.revision.v1"}`), ValidatedAt: now}},
	}
}
