package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type fakeMixPlanStore struct {
	missingTrackIDs []int64
	created         *db.MixPlan
	updated         *db.MixPlan
	updatedVersion  int
	getPlan         *db.MixPlan
	getErr          error
	updateErr       error
}

func (s *fakeMixPlanStore) Create(ctx context.Context, plan *db.MixPlan) error {
	plan.ID = uuid.New()
	plan.Version = 1
	plan.CreatedAt = time.Date(2026, 6, 3, 1, 2, 3, 0, time.UTC)
	plan.UpdatedAt = plan.CreatedAt
	s.created = cloneMixPlan(plan)
	return nil
}

func (s *fakeMixPlanStore) GetByIDForUser(ctx context.Context, userID, id uuid.UUID) (*db.MixPlan, error) {
	if s.getErr != nil {
		return nil, s.getErr
	}
	if s.getPlan == nil {
		return nil, db.ErrMixPlanNotFound
	}
	return cloneMixPlan(s.getPlan), nil
}

func (s *fakeMixPlanStore) GetByUserID(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.MixPlan, int, error) {
	if s.getPlan == nil {
		return nil, 0, nil
	}
	return []db.MixPlan{*cloneMixPlan(s.getPlan)}, 1, nil
}

func (s *fakeMixPlanStore) Update(ctx context.Context, plan *db.MixPlan, expectedVersion int) error {
	if s.updateErr != nil {
		return s.updateErr
	}
	plan.Version = expectedVersion + 1
	plan.UpdatedAt = time.Date(2026, 6, 3, 2, 3, 4, 0, time.UTC)
	s.updated = cloneMixPlan(plan)
	s.updatedVersion = expectedVersion
	return nil
}

func (s *fakeMixPlanStore) FindMissingTrackIDs(ctx context.Context, userID uuid.UUID, trackIDs []int64) ([]int64, error) {
	return s.missingTrackIDs, nil
}

func cloneMixPlan(plan *db.MixPlan) *db.MixPlan {
	clone := *plan
	clone.Payload = append(json.RawMessage(nil), plan.Payload...)
	clone.Summary = append(json.RawMessage(nil), plan.Summary...)
	return &clone
}

func TestCreateMixPlanAcceptsDuplicateTrackClipsAndStoresDerivedSummary(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)
	userID := uuid.New()

	body := []byte(`{
		"schemaVersion":1,
		"name":"Road trip mix",
		"clips":[
			{"clipId":"intro","queueItemId":"queue-intro","trackId":42,"sourceStartMs":1000,"sourceEndMs":5000,"timelineStartMs":0,"gainDb":-3.5,"fadeInMs":250},
			{"clipId":"drop","queueItemId":"queue-drop","trackId":42,"sourceStartMs":6000,"sourceEndMs":9000,"timelineStartMs":4500,"gainDb":1.25,"fadeOutMs":500}
		]
	}`)
	req := authedRequest(userID, http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created == nil {
		t.Fatal("expected mix plan to be persisted")
	}
	if store.created.UserID != userID {
		t.Fatalf("stored user id = %s, want %s", store.created.UserID, userID)
	}

	var storedPayload MixPlanPayload
	if err := json.Unmarshal(store.created.Payload, &storedPayload); err != nil {
		t.Fatalf("stored payload is invalid json: %v", err)
	}
	if len(storedPayload.Clips) != 2 || storedPayload.Clips[0].TrackID != 42 || storedPayload.Clips[1].TrackID != 42 {
		t.Fatalf("stored clips = %+v, want duplicate track refs preserved", storedPayload.Clips)
	}
	if storedPayload.Clips[0].QueueItemID != "queue-intro" || storedPayload.Clips[1].QueueItemID != "queue-drop" {
		t.Fatalf("stored queue item ids = %+v, want queue ids preserved", storedPayload.Clips)
	}
	if storedPayload.Clips[0].FadeInMs == nil || *storedPayload.Clips[0].FadeInMs != 250 {
		t.Fatalf("stored fadeInMs = %+v, want 250", storedPayload.Clips[0].FadeInMs)
	}

	var storedSummary MixPlanSummary
	if err := json.Unmarshal(store.created.Summary, &storedSummary); err != nil {
		t.Fatalf("stored summary is invalid json: %v", err)
	}
	if storedSummary.ClipCount != 2 {
		t.Fatalf("summary clipCount = %d, want 2", storedSummary.ClipCount)
	}
	if storedSummary.DurationMs != 7500 {
		t.Fatalf("summary durationMs = %d, want 7500", storedSummary.DurationMs)
	}
	if len(storedSummary.TrackIDs) != 1 || storedSummary.TrackIDs[0] != 42 {
		t.Fatalf("summary trackIds = %v, want [42]", storedSummary.TrackIDs)
	}

	var resp MixPlanResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.SchemaVersion != 1 || resp.Name != "Road trip mix" || resp.Version != 1 {
		t.Fatalf("response = %+v, want schemaVersion/name/version", resp)
	}
	if resp.Clips[0].QueueItemID != "queue-intro" || resp.Clips[0].TimelineEndMs != 4000 {
		t.Fatalf("response first clip = %+v, want queueItemId and derived timelineEndMs", resp.Clips[0])
	}
	if resp.Clips[1].TimelineEndMs != 7500 {
		t.Fatalf("response second timelineEndMs = %d, want 7500", resp.Clips[1].TimelineEndMs)
	}
}

func TestCreateMixPlanRejectsMissingQueueItemIDBeforePersisting(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Missing queue item",
		"clips":[{"clipId":"clip-a","trackId":42,"sourceStartMs":0,"sourceEndMs":1000,"timelineStartMs":0,"gainDb":0}]
	}`)
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("clip without queueItemId should not be persisted")
	}
}

func TestCreateMixPlanRejectsInvalidClipRangeBeforePersisting(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Broken mix",
		"clips":[{"clipId":"bad","queueItemId":"queue-bad","trackId":42,"sourceStartMs":5000,"sourceEndMs":5000,"timelineStartMs":0,"gainDb":0}]
	}`)
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("invalid clip range should not be persisted")
	}
}

func TestCreateMixPlanRejectsClipTimelineEndOverflowBeforePersisting(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Overflow mix",
		"clips":[{"clipId":"overflow","queueItemId":"queue-overflow","trackId":42,"sourceStartMs":0,"sourceEndMs":2,"timelineStartMs":` + strconv.FormatInt(math.MaxInt64, 10) + `,"gainDb":0}]
	}`)
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("overflowing timeline end should not be persisted")
	}
}

func TestCreateMixPlanRejectsOversizedBodyBeforePersisting(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Huge mix",
		"clips":[{"clipId":"clip-a","queueItemId":"queue-huge","trackId":42,"sourceStartMs":0,"sourceEndMs":1000,"timelineStartMs":0,"gainDb":0}],
		"padding":"` + strings.Repeat("a", 1024*1024+1) + `"
	}`)
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body length = %d", w.Code, len(body))
	}
	if store.created != nil {
		t.Fatal("oversized request body should not be persisted")
	}
}

func TestCreateMixPlanRejectsTooManyClipsBeforePersisting(t *testing.T) {
	store := &fakeMixPlanStore{}
	h := NewMixPlanHandlers(store)

	clips := make([]MixPlanClip, mixPlanMaxClips+1)
	for i := range clips {
		clips[i] = MixPlanClip{
			ClipID:          "clip-" + strconv.Itoa(i),
			QueueItemID:     "queue-" + strconv.Itoa(i),
			TrackID:         int64(i + 1),
			SourceStartMs:   0,
			SourceEndMs:     1000,
			TimelineStartMs: int64(i) * 1000,
			GainDB:          0,
		}
	}
	body, err := json.Marshal(SaveMixPlanRequest{SchemaVersion: 1, Name: "Too many clips", Clips: clips})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("too many clips should not be persisted")
	}
}

func TestCreateMixPlanRejectsTracksOutsideUserLibrary(t *testing.T) {
	store := &fakeMixPlanStore{missingTrackIDs: []int64{99}}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Missing track mix",
		"clips":[{"clipId":"missing","queueItemId":"queue-missing","trackId":99,"sourceStartMs":0,"sourceEndMs":1000,"timelineStartMs":0,"gainDb":0}]
	}`)
	req := authedRequest(uuid.New(), http.MethodPost, "/api/v1/mix-plans", body)
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("plan with non-owned tracks should not be persisted")
	}
}

func TestUpdateMixPlanUsesOptimisticVersion(t *testing.T) {
	planID := uuid.New()
	userID := uuid.New()
	store := &fakeMixPlanStore{
		getPlan: &db.MixPlan{ID: planID, UserID: userID, Version: 3},
	}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Updated mix",
		"version":3,
		"clips":[{"clipId":"clip-a","queueItemId":"queue-clip-a","trackId":7,"sourceStartMs":100,"sourceEndMs":200,"timelineStartMs":50,"gainDb":0}]
	}`)
	req := authedRequest(userID, http.MethodPut, "/api/v1/mix-plans/"+planID.String(), body)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.UpdateMixPlan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.updated == nil {
		t.Fatal("expected update")
	}
	if store.updatedVersion != 3 {
		t.Fatalf("expectedVersion = %d, want 3", store.updatedVersion)
	}
	if store.updated.Version != 4 {
		t.Fatalf("updated version = %d, want 4", store.updated.Version)
	}
}

func TestUpdateMixPlanReturnsConflictOnStaleVersion(t *testing.T) {
	planID := uuid.New()
	userID := uuid.New()
	store := &fakeMixPlanStore{
		getPlan:   &db.MixPlan{ID: planID, UserID: userID, Version: 4},
		updateErr: db.ErrMixPlanVersionConflict,
	}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Stale mix",
		"version":3,
		"clips":[{"clipId":"clip-a","queueItemId":"queue-clip-a","trackId":7,"sourceStartMs":100,"sourceEndMs":200,"timelineStartMs":50,"gainDb":0}]
	}`)
	req := authedRequest(userID, http.MethodPut, "/api/v1/mix-plans/"+planID.String(), body)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.UpdateMixPlan(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestGetMixPlanReturnsUserScopedPlan(t *testing.T) {
	planID := uuid.New()
	userID := uuid.New()
	payload := json.RawMessage(`{"schemaVersion":1,"name":"Saved mix","clips":[]}`)
	summary := json.RawMessage(`{"clipCount":0,"trackIds":[],"durationMs":0}`)
	store := &fakeMixPlanStore{
		getPlan: &db.MixPlan{
			ID:            planID,
			UserID:        userID,
			Name:          "Saved mix",
			SchemaVersion: 1,
			Payload:       payload,
			Summary:       summary,
			Version:       2,
			CreatedAt:     time.Date(2026, 6, 1, 1, 0, 0, 0, time.UTC),
			UpdatedAt:     time.Date(2026, 6, 2, 1, 0, 0, 0, time.UTC),
		},
	}
	h := NewMixPlanHandlers(store)

	req := authedRequest(userID, http.MethodGet, "/api/v1/mix-plans/"+planID.String(), nil)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.GetMixPlan(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	var resp MixPlanResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.ID != planID || resp.Name != "Saved mix" || resp.Version != 2 {
		t.Fatalf("response = %+v", resp)
	}
}

func TestGetMixPlanReturnsNotFound(t *testing.T) {
	store := &fakeMixPlanStore{getErr: db.ErrMixPlanNotFound}
	h := NewMixPlanHandlers(store)
	planID := uuid.New()
	req := authedRequest(uuid.New(), http.MethodGet, "/api/v1/mix-plans/"+planID.String(), nil)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.GetMixPlan(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateMixPlanRequiresAuthentication(t *testing.T) {
	h := NewMixPlanHandlers(&fakeMixPlanStore{})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/mix-plans", bytes.NewReader([]byte(`{}`)))
	w := httptest.NewRecorder()

	h.CreateMixPlan(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestUpdateMixPlanRejectsMissingVersion(t *testing.T) {
	planID := uuid.New()
	userID := uuid.New()
	store := &fakeMixPlanStore{getPlan: &db.MixPlan{ID: planID, UserID: userID, Version: 3}}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"No version mix",
		"clips":[{"clipId":"clip-a","queueItemId":"queue-clip-a","trackId":7,"sourceStartMs":100,"sourceEndMs":200,"timelineStartMs":50,"gainDb":0}]
	}`)
	req := authedRequest(userID, http.MethodPut, "/api/v1/mix-plans/"+planID.String(), body)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.UpdateMixPlan(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestUpdateMixPlanUnexpectedStoreError(t *testing.T) {
	planID := uuid.New()
	userID := uuid.New()
	store := &fakeMixPlanStore{
		getPlan:   &db.MixPlan{ID: planID, UserID: userID, Version: 3},
		updateErr: errors.New("db exploded"),
	}
	h := NewMixPlanHandlers(store)

	body := []byte(`{
		"schemaVersion":1,
		"name":"Updated mix",
		"version":3,
		"clips":[{"clipId":"clip-a","queueItemId":"queue-clip-a","trackId":7,"sourceStartMs":100,"sourceEndMs":200,"timelineStartMs":50,"gainDb":0}]
	}`)
	req := authedRequest(userID, http.MethodPut, "/api/v1/mix-plans/"+planID.String(), body)
	req.SetPathValue("id", planID.String())
	w := httptest.NewRecorder()

	h.UpdateMixPlan(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func authedRequest(userID uuid.UUID, method, path string, body []byte) *http.Request {
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		reader = bytes.NewReader(body)
	}
	req := httptest.NewRequest(method, path, reader)
	ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID, Email: "test@example.com"})
	return req.WithContext(ctx)
}
