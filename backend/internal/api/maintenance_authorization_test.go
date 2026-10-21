package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
)

// Reuse the candidate-selection fake while recording every global/explicit read.
type maintenanceAdmissionStore struct {
	qualitySelectionStore
	calls int
}

func (s *maintenanceAdmissionStore) GetByID(_ context.Context, id int64) (*db.Track, error) {
	s.calls++
	return &db.Track{ID: id}, nil
}

func (s *maintenanceAdmissionStore) GetMaintenanceCandidates(ctx context.Context, metadata, analysis bool, stale time.Duration, limit int) ([]db.Track, error) {
	s.calls++
	return s.qualitySelectionStore.GetMaintenanceCandidates(ctx, metadata, analysis, stale, limit)
}

func (s *maintenanceAdmissionStore) GetAudioQualityMaintenanceCandidates(ctx context.Context, limit int) ([]db.Track, error) {
	s.calls++
	return s.qualitySelectionStore.GetAudioQualityMaintenanceCandidates(ctx, limit)
}

type maintenanceAdmissionProcessor struct {
	metadataCalls, analysisCalls, qualityCalls int
	metadataOptions                            processor.MetadataRepairOptions
	analysisOptions                            processor.AnalysisRepairOptions
}

func (p *maintenanceAdmissionProcessor) RepairMetadata(_ context.Context, track *db.Track, opts processor.MetadataRepairOptions) (processor.MetadataRepairResult, error) {
	p.metadataCalls++
	p.metadataOptions = opts
	return processor.MetadataRepairResult{TrackID: track.ID, Status: "processed"}, nil
}

func (p *maintenanceAdmissionProcessor) RequestAnalysisRepair(_ context.Context, track *db.Track, opts processor.AnalysisRepairOptions) (processor.AnalysisRepairResult, error) {
	p.analysisCalls++
	p.analysisOptions = opts
	return processor.AnalysisRepairResult{TrackID: track.ID, Queued: true}, nil
}

func (p *maintenanceAdmissionProcessor) RepairAudioQuality(_ context.Context, track *db.Track) (processor.AudioQualityRepairResult, error) {
	p.qualityCalls++
	return processor.AudioQualityRepairResult{Status: "processed"}, nil
}

type maintenanceObservedBody struct {
	io.Reader
	reads int
}

func (b *maintenanceObservedBody) Read(p []byte) (int, error) {
	b.reads++
	return b.Reader.Read(p)
}

func (b *maintenanceObservedBody) Close() error { return nil }

func maintenanceUserRequest(body string, user *auth.UserContext) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/maintenance/repair", strings.NewReader(body))
	if user != nil {
		req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, user))
	}
	return req
}

func assertNoMaintenanceWork(t *testing.T, store *maintenanceAdmissionStore, repairs *maintenanceAdmissionProcessor) {
	t.Helper()
	if store.calls != 0 || repairs.metadataCalls != 0 || repairs.analysisCalls != 0 || repairs.qualityCalls != 0 {
		t.Errorf("denied/invalid request performed work: store=%d metadata=%d analysis=%d quality=%d", store.calls, repairs.metadataCalls, repairs.analysisCalls, repairs.qualityCalls)
	}
}

func TestMaintenanceRequestLimitBoundaries(t *testing.T) {
	operator := uuid.New()
	ids := make([]int64, 200)
	for i := range ids {
		ids[i] = int64(i + 1)
	}
	for _, tc := range []struct {
		name                                                   string
		limit, stale, selected, effectiveLimit, effectiveStale int
	}{
		{"defaults", 0, 0, 50, 50, 30},
		{"maximums", 200, 10080, 200, 200, 10080},
		{"minimum_stale_and_clamped_limit", 201, 1, 200, 200, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, err := json.Marshal(map[string]any{"trackIds": ids, "limit": tc.limit, "staleAfterMinutes": tc.stale})
			if err != nil {
				t.Fatal(err)
			}
			store := &maintenanceAdmissionStore{}
			repairs := &maintenanceAdmissionProcessor{}
			handler := NewMaintenanceHandlers(store, repairs, MaintenanceConfig{AdminUserIDs: []uuid.UUID{operator}})
			response := httptest.NewRecorder()
			handler.RepairTracks(response, maintenanceUserRequest(string(body)+" \n", &auth.UserContext{UserID: operator}))
			var result maintenanceRepairResponse
			if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if response.Code != http.StatusOK || result.Summary.Selected != tc.selected || result.Criteria.Limit != tc.effectiveLimit || result.Criteria.StaleAfterMinutes != tc.effectiveStale {
				t.Fatalf("boundary status=%d summary=%+v criteria=%+v", response.Code, result.Summary, result.Criteria)
			}
			if store.calls != tc.selected || repairs.analysisOptions.StaleAfter != time.Duration(tc.effectiveStale)*time.Minute {
				t.Fatalf("boundary work store=%d stale=%s", store.calls, repairs.analysisOptions.StaleAfter)
			}
		})
	}
	// Exactly the byte cap is accepted; cap+1 is covered by the rejection test.
	body := `{}` + strings.Repeat(" ", 16*1024-2)
	handler := NewMaintenanceHandlers(&maintenanceAdmissionStore{}, &maintenanceAdmissionProcessor{}, MaintenanceConfig{AdminUserIDs: []uuid.UUID{operator}})
	response := httptest.NewRecorder()
	handler.RepairTracks(response, maintenanceUserRequest(body, &auth.UserContext{UserID: operator}))
	if response.Code != http.StatusOK {
		t.Fatalf("exact byte cap status=%d", response.Code)
	}
}

func TestMaintenanceRequestLimitsRejectBeforeWork(t *testing.T) {
	ids := make([]int64, 201)
	for i := range ids {
		ids[i] = int64(i + 1)
	}
	tooManyIDs, err := json.Marshal(map[string]any{"trackIds": ids})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"too_many_ids", string(tooManyIDs), http.StatusBadRequest},
		{"invalid_id_before_reads", `{"trackIds":[42,0]}`, http.StatusBadRequest},
		{"invalid_id_beyond_limit", `{"trackIds":[42,-1],"limit":1}`, http.StatusBadRequest},
		{"negative_limit", `{"limit":-1}`, http.StatusBadRequest},
		{"negative_stale", `{"staleAfterMinutes":-1}`, http.StatusBadRequest},
		{"stale_above_week", `{"staleAfterMinutes":10081}`, http.StatusBadRequest},
		{"stale_duration_overflow", `{"staleAfterMinutes":9223372036854775807}`, http.StatusBadRequest},
		{"trailing_json", `{} {}`, http.StatusBadRequest},
		{"trailing_garbage", `{} garbage`, http.StatusBadRequest},
		{"null", `null`, http.StatusBadRequest},
		{"unknown_field", `{"admin":true}`, http.StatusBadRequest},
		{"oversize_json", `{"padding":"` + strings.Repeat("x", 16*1024) + `"}`, http.StatusRequestEntityTooLarge},
		{"oversize_trailing_whitespace", `{}` + strings.Repeat(" ", 16*1024), http.StatusRequestEntityTooLarge},
	} {
		t.Run(tc.name, func(t *testing.T) {
			operator := uuid.New()
			store := &maintenanceAdmissionStore{}
			repairs := &maintenanceAdmissionProcessor{}
			handler := NewMaintenanceHandlers(store, repairs, MaintenanceConfig{AdminUserIDs: []uuid.UUID{operator}})
			response := httptest.NewRecorder()
			handler.RepairTracks(response, maintenanceUserRequest(tc.body, &auth.UserContext{UserID: operator}))
			if response.Code != tc.status {
				t.Errorf("status=%d, want %d body=%s", response.Code, tc.status, response.Body.String())
			}
			assertNoMaintenanceWork(t, store, repairs)
		})
	}
}

func TestMaintenanceAuthorizationAdmitsOnlyConfiguredUUIDs(t *testing.T) {
	operator := uuid.MustParse("53b676c8-7b11-4705-89a6-08dcebcbe674")
	ids := []uuid.UUID{operator, uuid.Nil}
	store := &maintenanceAdmissionStore{qualitySelectionStore: qualitySelectionStore{quality: []db.Track{{ID: 42}}, other: []db.Track{{ID: 42}}}}
	repairs := &maintenanceAdmissionProcessor{}
	handler := NewMaintenanceHandlers(store, repairs, MaintenanceConfig{AdminUserIDs: ids})
	ids[0] = uuid.New() // Configuration admission must be a constructor-time snapshot.
	for _, payload := range []string{
		`{"trackIds":[42],"forceMetadata":true,"forceAnalysis":true}`,
		`{}`,
		`{"metadata":false,"analysis":false,"audioQuality":true}`,
	} {
		response := httptest.NewRecorder()
		handler.RepairTracks(response, maintenanceUserRequest(payload, &auth.UserContext{UserID: operator}))
		if response.Code != http.StatusOK {
			t.Fatalf("configured operator status=%d body=%s", response.Code, response.Body.String())
		}
	}
	if store.calls != 3 || repairs.metadataCalls != 2 || repairs.analysisCalls != 2 || repairs.qualityCalls != 1 {
		t.Fatalf("operator work counts store=%d metadata=%d analysis=%d quality=%d", store.calls, repairs.metadataCalls, repairs.analysisCalls, repairs.qualityCalls)
	}
	store.calls, repairs.metadataCalls, repairs.analysisCalls, repairs.qualityCalls = 0, 0, 0, 0
	body := &maintenanceObservedBody{Reader: strings.NewReader(`{}`)}
	req := maintenanceUserRequest(`{}`, &auth.UserContext{UserID: uuid.New(), Email: "admin@example.test"})
	req.Body = body
	response := httptest.NewRecorder()
	handler.RepairTracks(response, req)
	if response.Code != http.StatusForbidden || body.reads != 0 {
		t.Errorf("nonoperator status=%d body reads=%d", response.Code, body.reads)
	}
	assertNoMaintenanceWork(t, store, repairs)
}

func TestMaintenanceAuthorizationDefaultDenyBeforeBodyOrWork(t *testing.T) {
	for _, identity := range []struct {
		name   string
		user   *auth.UserContext
		status int
	}{
		{"unauthenticated", nil, http.StatusUnauthorized},
		{"nil_identity", &auth.UserContext{}, http.StatusUnauthorized},
		{"default_deny_user", &auth.UserContext{UserID: uuid.New()}, http.StatusForbidden},
		{"ordinary_user", &auth.UserContext{UserID: uuid.New(), Email: "admin@example.test"}, http.StatusForbidden},
	} {
		for _, payload := range []struct{ name, body string }{
			{"explicit", `{"trackIds":[42]}`},
			{"global", `{}`},
			{"force", `{"trackIds":[42],"forceMetadata":true,"forceAnalysis":true}`},
			{"quality", `{"metadata":false,"analysis":false,"audioQuality":true}`},
			{"self_asserted_admin", `{"admin":true,"role":"admin","userId":"operator"}`},
			{"malformed", `not json`},
		} {
			t.Run(identity.name+"/"+payload.name, func(t *testing.T) {
				store := &maintenanceAdmissionStore{qualitySelectionStore: qualitySelectionStore{quality: []db.Track{{ID: 42}}, other: []db.Track{{ID: 42}}}}
				repairs := &maintenanceAdmissionProcessor{}
				handler := NewMaintenanceHandlers(store, repairs)
				if identity.name == "ordinary_user" {
					// Another configured operator must not admit this account.
					handler = NewMaintenanceHandlers(store, repairs, MaintenanceConfig{AdminUserIDs: []uuid.UUID{uuid.New()}})
				}
				req := maintenanceUserRequest(payload.body, identity.user)
				body := &maintenanceObservedBody{Reader: strings.NewReader(payload.body)}
				req.Body = body
				req.Header.Set("X-Admin", "true")
				req.Header.Set("X-User-ID", uuid.NewString())
				response := httptest.NewRecorder()
				handler.RepairTracks(response, req)
				if response.Code != identity.status {
					t.Errorf("status=%d, want %d; body=%s", response.Code, identity.status, response.Body.String())
				}
				if body.reads != 0 {
					t.Errorf("denied caller's body was read %d times", body.reads)
				}
				assertNoMaintenanceWork(t, store, repairs)
			})
		}
	}
}
