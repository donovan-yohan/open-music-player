package queue

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

type fakeQueueHandlerService struct {
	state         *QueueState
	addTrackCalls int
	removedIDs    []string
}

func (s *fakeQueueHandlerService) GetQueue(context.Context, string) (*QueueState, error) {
	return s.state, nil
}
func (s *fakeQueueHandlerService) AddToQueue(_ context.Context, _ string, trackID int64, _ string) (*QueueState, error) {
	s.addTrackCalls++
	s.state.Items = append(s.state.Items, QueueItem{ID: "track-item", Kind: "track", TrackID: &trackID, PlaybackState: "playable", AddedAt: time.Now(), UpdatedAt: time.Now()})
	return s.state, nil
}
func (s *fakeQueueHandlerService) ValidateInsertPosition(context.Context, string, string) error {
	return nil
}
func (s *fakeQueueHandlerService) AddSourceCandidate(_ context.Context, _ string, candidate SourceCandidate, jobID, _ string) (*QueueState, error) {
	s.state.Items = append(s.state.Items, QueueItem{ID: "source-item", Kind: "source", Source: &candidate, DownloadJobID: jobID, PlaybackState: "queued", AddedAt: time.Now(), UpdatedAt: time.Now()})
	return s.state, nil
}
func (s *fakeQueueHandlerService) EnsureSourceCandidateWithID(_ context.Context, _ string, itemID string, candidate SourceCandidate, jobID, _ string) (*QueueState, error) {
	for _, item := range s.state.Items {
		if item.ID == itemID || item.DownloadJobID == jobID {
			return s.state, nil
		}
	}
	s.state.Items = append(s.state.Items, QueueItem{ID: itemID, Kind: "source", Source: &candidate, DownloadJobID: jobID, PlaybackState: "queued", AddedAt: time.Now(), UpdatedAt: time.Now()})
	return s.state, nil
}
func (s *fakeQueueHandlerService) RemoveQueueItem(_ context.Context, _ string, itemID string) (*QueueState, error) {
	s.removedIDs = append(s.removedIDs, itemID)
	for i := range s.state.Items {
		if s.state.Items[i].ID == itemID {
			s.state.Items = append(s.state.Items[:i], s.state.Items[i+1:]...)
			break
		}
	}
	return s.state, nil
}
func (s *fakeQueueHandlerService) QueueItemDownloadJobID(context.Context, string, string) (string, error) {
	return "", ErrTrackNotFound
}
func (s *fakeQueueHandlerService) RetryQueueItem(context.Context, string, string) (*QueueState, string, error) {
	return nil, "", ErrTrackNotFound
}
func (s *fakeQueueHandlerService) ReorderQueueItem(context.Context, string, string, int) (*QueueState, error) {
	return nil, ErrTrackNotFound
}
func (s *fakeQueueHandlerService) ClearQueue(context.Context, string) error             { return nil }
func (s *fakeQueueHandlerService) saveQueue(context.Context, string, *QueueState) error { return nil }

type fakeQueueDownloadService struct {
	job        *download.DownloadJob
	getErr     error
	enqueueErr error
	enqueued   []download.SourceCandidate
	mbIDs      []*string
}

func (s *fakeQueueDownloadService) GetJob(context.Context, string) (*download.DownloadJob, error) {
	if s.getErr != nil {
		return nil, s.getErr
	}
	return s.job, nil
}
func (s *fakeQueueDownloadService) EnqueueSourceCandidateWithID(_ context.Context, jobID, userID string, candidate download.SourceCandidate, mbID *string) (*download.DownloadJob, error) {
	s.enqueued = append(s.enqueued, candidate)
	s.mbIDs = append(s.mbIDs, mbID)
	if s.enqueueErr != nil {
		return nil, s.enqueueErr
	}
	if s.job == nil {
		s.job = &download.DownloadJob{ID: jobID, UserID: userID, Status: download.StatusQueued, MBRecordingID: mbID}
	}
	return s.job, nil
}
func (s *fakeQueueDownloadService) EnsureSourceCandidateWithID(ctx context.Context, jobID, userID string, candidate download.SourceCandidate, mbID *string) (*download.DownloadJob, error) {
	if s.job != nil {
		return s.job, nil
	}
	return s.EnqueueSourceCandidateWithID(ctx, jobID, userID, candidate, mbID)
}
func (s *fakeQueueDownloadService) RetryJob(context.Context, string) error { return nil }

type fakeSourceDecisionRepository struct {
	decision  *db.SourceSelectionDecision
	attachErr error
	attached  []uuid.UUID
}

func (r *fakeSourceDecisionRepository) GetDecisionForUser(context.Context, uuid.UUID, uuid.UUID) (*db.SourceSelectionDecision, error) {
	return r.decision, nil
}
func (r *fakeSourceDecisionRepository) AttachDownloadJobForUser(_ context.Context, _ uuid.UUID, _ uuid.UUID, jobID uuid.UUID) error {
	r.attached = append(r.attached, jobID)
	return r.attachErr
}
func (r *fakeSourceDecisionRepository) AttachDownloadJobWithQueueIntent(_ context.Context, _ uuid.UUID, decisionID, jobID uuid.UUID, queueItemID, position string) (*db.SourceSelectionQueueIntent, error) {
	if r.attachErr != nil {
		return nil, r.attachErr
	}
	r.attached = append(r.attached, jobID)
	if r.decision != nil {
		r.decision.DownloadJobID = uuid.NullUUID{UUID: jobID, Valid: true}
	}
	return &db.SourceSelectionQueueIntent{DecisionID: decisionID, DownloadJobID: jobID, QueueItemID: queueItemID, InsertPosition: position}, nil
}

type fakeSQLResult struct{}

func (fakeSQLResult) LastInsertId() (int64, error) { return 0, nil }
func (fakeSQLResult) RowsAffected() (int64, error) { return 1, nil }

type fakeDurableDownloadJobStore struct {
	calls [][]any
}

func (s *fakeDurableDownloadJobStore) ExecContext(_ context.Context, query string, args ...any) (sql.Result, error) {
	s.calls = append(s.calls, append([]any{query}, args...))
	return fakeSQLResult{}, nil
}

func queueDecisionRequest(body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/queue/items", strings.NewReader(body))
	return req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111")}))
}

func sourceDecisionSnapshot(t *testing.T, sourceURL, mbID string) json.RawMessage {
	t.Helper()
	metadata := map[string]any{}
	if mbID != "" {
		metadata["mbRecordingId"] = mbID
	}
	raw, err := json.Marshal(SourceCandidate{CandidateID: "youtube:owned", Provider: "youtube", SourceID: "owned", SourceURL: sourceURL, Title: "Owned source", Downloadable: true, Metadata: metadata})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func sourceDecisionForQueue(t *testing.T, snapshot json.RawMessage) *db.SourceSelectionDecision {
	return &db.SourceSelectionDecision{ID: uuid.MustParse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111"), Action: db.SourceSelectionActionAccepted, SelectedCandidate: snapshot}
}

func TestAddQueueItemStrictlyRejectsLegacySourceFields(t *testing.T) {
	for _, body := range []string{
		`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","mbRecordingId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}`,
		`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","sourceUrl":"https://attacker.example/audio"}`,
		`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","sourceCandidate":{"sourceUrl":"https://attacker.example/audio"}}`,
	} {
		rec := httptest.NewRecorder()
		NewHandlers(nil).AddQueueItem(rec, queueDecisionRequest(body))
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "INVALID_REQUEST") {
			t.Fatalf("legacy body status=%d body=%s", rec.Code, rec.Body.String())
		}
	}
}

func TestAddQueueItemRejectsOversizedRequestBody(t *testing.T) {
	rec := httptest.NewRecorder()
	NewHandlers(nil).AddQueueItem(rec, queueDecisionRequest(`{"trackId":1,"padding":"`+strings.Repeat("x", maxAddQueueItemRequestBytes)+`"}`))
	if rec.Code != http.StatusRequestEntityTooLarge || !strings.Contains(rec.Body.String(), "QUEUE_ITEM_TOO_LARGE") {
		t.Fatalf("oversized request status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestSourceCandidateFromDecisionUsesOnlyOwnedSnapshotAndValidatesMusicBrainzID(t *testing.T) {
	mbID := "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	candidate, derived, err := sourceCandidateFromDecision(sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", mbID))
	if err != nil || candidate.SourceURL != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" || derived == nil || *derived != mbID {
		t.Fatalf("candidate=%#v derived=%v err=%v", candidate, derived, err)
	}
	if _, _, err := sourceCandidateFromDecision(sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "not-a-uuid")); err == nil {
		t.Fatal("malformed snapshot MusicBrainz ID was accepted")
	}
	_, absent, err := sourceCandidateFromDecision(sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", ""))
	if err != nil || absent != nil {
		t.Fatalf("absent MusicBrainz ID = %v, err=%v", absent, err)
	}
}

func TestSourceDecisionQueueUsesOwnedSnapshotAndStableResponse(t *testing.T) {
	mbID := "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{}}}
	downloads := &fakeQueueDownloadService{}
	store := &fakeDurableDownloadJobStore{}
	repo := &fakeSourceDecisionRepository{decision: sourceDecisionForQueue(t, sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", mbID))}
	h := NewHandlersWithSourceSelections(service, downloads, nil, repo, store)
	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","position":"last"}`))

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var response SourceDecisionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.DownloadJobID == "" || response.Idempotent || len(response.Queue.Items) != 1 || response.Queue.Items[0].SourceCandidate == nil || response.Queue.Items[0].SourceCandidate.SourceURL != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" {
		t.Fatalf("response=%#v", response)
	}
	if len(downloads.enqueued) != 1 || downloads.enqueued[0].SourceURL != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" || downloads.mbIDs[0] == nil || *downloads.mbIDs[0] != mbID {
		t.Fatalf("enqueue candidates=%#v mbIDs=%#v", downloads.enqueued, downloads.mbIDs)
	}
	if len(store.calls) != 1 || store.calls[0][3] != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" {
		t.Fatalf("durable job calls=%#v", store.calls)
	}
	durableMBID, ok := store.calls[0][14].(*string)
	if !ok || durableMBID == nil || *durableMBID != mbID {
		t.Fatalf("durable MusicBrainz ID=%#v", store.calls[0][14])
	}
}

func TestSourceDecisionRetryReusesSnapshotMusicBrainzIDAndProjectsLiveJob(t *testing.T) {
	mbID := "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	jobID := uuid.MustParse("cccccccc-cccc-cccc-cccc-cccccccccccc")
	trackID := int64(42)
	service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{{ID: "source-item", DownloadJobID: jobID.String(), PlaybackState: "queued"}}}}
	decision := sourceDecisionForQueue(t, sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", mbID))
	decision.DownloadJobID = uuid.NullUUID{UUID: jobID, Valid: true}
	liveDownloads := &fakeQueueDownloadService{job: &download.DownloadJob{ID: jobID.String(), UserID: decision.UserID.String(), Status: download.StatusComplete, Progress: 100, TrackID: &trackID}}
	h := NewHandlersWithSourceSelections(service, liveDownloads, nil, &fakeSourceDecisionRepository{decision: decision}, &fakeDurableDownloadJobStore{})
	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var response SourceDecisionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Idempotent || len(liveDownloads.enqueued) != 0 || len(response.Queue.Items) != 1 || response.Queue.Items[0].PlaybackState != "playable" || response.Queue.Items[0].TrackID == nil || *response.Queue.Items[0].TrackID != trackID {
		t.Fatalf("response=%#v enqueued=%#v", response, liveDownloads.enqueued)
	}

	queuedAgain := &fakeQueueDownloadService{getErr: errors.New("missing redis job")}
	h.downloadService = queuedAgain
	rec = httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}`))
	if rec.Code != http.StatusAccepted || len(queuedAgain.mbIDs) != 1 || queuedAgain.mbIDs[0] == nil || *queuedAgain.mbIDs[0] != mbID {
		t.Fatalf("retry status=%d mbIDs=%#v body=%s", rec.Code, queuedAgain.mbIDs, rec.Body.String())
	}
}

func TestSourceDecisionAttachFailureRollsBackButEnqueueFailureKeepsDurableIntent(t *testing.T) {
	decision := sourceDecisionForQueue(t, sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", ""))
	for _, tc := range []struct {
		name        string
		attachErr   error
		enqueueErr  error
		wantDeleted bool
	}{
		{name: "attach", attachErr: db.ErrSourceSelectionConflict, wantDeleted: true},
		{name: "enqueue", enqueueErr: errors.New("redis unavailable")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{}}}
			store := &fakeDurableDownloadJobStore{}
			h := NewHandlersWithSourceSelections(service, &fakeQueueDownloadService{enqueueErr: tc.enqueueErr}, nil, &fakeSourceDecisionRepository{decision: decision, attachErr: tc.attachErr}, store)
			rec := httptest.NewRecorder()
			h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}`))
			if rec.Code != http.StatusInternalServerError && rec.Code != http.StatusConflict {
				t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
			}
			if tc.wantDeleted {
				if len(store.calls) != 2 || !strings.Contains(store.calls[1][0].(string), "DELETE FROM download_jobs") {
					t.Fatalf("durable rollback calls=%#v", store.calls)
				}
			} else if len(store.calls) != 1 || len(service.removedIDs) != 0 {
				t.Fatalf("enqueue failure should retain durable intent: store=%#v removed=%#v", store.calls, service.removedIDs)
			}
		})
	}
}

func TestExistingTrackQueueResponseIsUnchanged(t *testing.T) {
	service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{}}}
	h := NewHandlers(service)
	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"trackId":7,"position":"last"}`))
	var response map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &response)
	if rec.Code != http.StatusOK || service.addTrackCalls != 1 || response["idempotent"] != nil || response["queue"] != nil {
		t.Fatalf("status=%d addTrackCalls=%d body=%s", rec.Code, service.addTrackCalls, rec.Body.String())
	}
}

var _ queueHandlerService = (*fakeQueueHandlerService)(nil)
var _ queueDownloadService = (*fakeQueueDownloadService)(nil)
var _ sourceDecisionRepository = (*fakeSourceDecisionRepository)(nil)
var _ durableDownloadJobStore = (*fakeDurableDownloadJobStore)(nil)
