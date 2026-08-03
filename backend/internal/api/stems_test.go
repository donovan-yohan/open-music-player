package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/stems"
)

type fakeStemsRepo struct {
	row      db.TrackStems
	queued   bool
	reason   string
	err      error
	getRow   *db.TrackStems
	getErr   error
	requests int

	seenIdentity   db.StemsIdentity
	seenStorageKey string
	seenProvenance json.RawMessage
}

func (f *fakeStemsRepo) RequestSeparation(
	_ context.Context,
	trackID int64,
	identity db.StemsIdentity,
	sourceStorageKey string,
	_ string,
	provenance json.RawMessage,
) (db.TrackStems, bool, string, error) {
	f.requests++
	f.seenIdentity = identity
	f.seenStorageKey = sourceStorageKey
	f.seenProvenance = provenance
	if f.err != nil {
		return db.TrackStems{}, false, "", f.err
	}
	row := f.row
	row.TrackID = trackID
	if row.ChannelSet == "" {
		row.ChannelSet = identity.ChannelSet
	}
	if row.StemModelVersion == "" {
		row.StemModelVersion = identity.StemModelVersion
	}
	return row, f.queued, f.reason, nil
}

func (f *fakeStemsRepo) GetByTrackAndIdentity(_ context.Context, _ int64, _ db.StemsIdentity) (*db.TrackStems, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.getRow == nil {
		return nil, db.ErrTrackStemsNotFound
	}
	clone := *f.getRow
	return &clone, nil
}

type fakeStemsQueue struct {
	enqueueErr  error
	position    int64
	positionErr error
	enqueued    []stems.EnqueueRequest
}

func (f *fakeStemsQueue) Enqueue(_ context.Context, req stems.EnqueueRequest) (*stems.Job, bool, error) {
	if f.enqueueErr != nil {
		return nil, false, f.enqueueErr
	}
	f.enqueued = append(f.enqueued, req)
	return &stems.Job{ID: stems.JobID(req.TrackID, req.ChannelSet, req.StemModelVersion), Status: stems.JobStatusQueued}, true, nil
}

func (f *fakeStemsQueue) QueuePosition(_ context.Context, _ string) (int64, error) {
	if f.positionErr != nil {
		return -1, f.positionErr
	}
	return f.position, nil
}

type fakeStemsTrackRepo struct {
	track *db.Track
	err   error
}

func (f *fakeStemsTrackRepo) GetByID(_ context.Context, id int64) (*db.Track, error) {
	if f.err != nil {
		return nil, f.err
	}
	if f.track == nil {
		return nil, sql.ErrNoRows
	}
	clone := *f.track
	clone.ID = id
	return &clone, nil
}

type fakeStemsLibraryRepo struct {
	inLibrary bool
	err       error
}

func (f *fakeStemsLibraryRepo) IsTrackInLibrary(_ context.Context, _ uuid.UUID, _ int64) (bool, error) {
	return f.inLibrary, f.err
}

func stemsTestTrack() *db.Track {
	return &db.Track{StorageKey: sql.NullString{String: "tracks/youtube/x.mp3", Valid: true}}
}

func readyStemsRow() db.TrackStems {
	return db.TrackStems{
		TrackID:          42,
		ChannelSet:       stems.ChannelSetStems5Hybrid,
		StemModelVersion: stems.StemModelVersionStems5,
		SchemaVersion:    1,
		Status:           db.StemsStatusReady,
		SourceFileHash:   "sha256:deadbeef",
		ArtifactsJSON:    json.RawMessage(`{"objects":[],"energy":{"frame_hz":80}}`),
		ProvenanceJSON:   json.RawMessage(`{"worker":"stemsep-worker","worker_version":"2026-08-03-1"}`),
		RequestedAt:      time.Unix(1700000000, 0).UTC(),
		UpdatedAt:        time.Unix(1700000100, 0).UTC(),
		CompletedAt:      sql.NullTime{Time: time.Unix(1700000100, 0).UTC(), Valid: true},
	}
}

func newStemsRequest(t *testing.T, method, body string, authenticated bool) *http.Request {
	t.Helper()
	var reader *strings.Reader
	if body == "" {
		reader = strings.NewReader("")
	} else {
		reader = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, "/api/v1/tracks/42/stems", reader)
	req.SetPathValue("track_id", strconv.FormatInt(42, 10))
	if authenticated {
		ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New(), Email: "dj@example.com"})
		req = req.WithContext(ctx)
	}
	return req
}

func decodeStemsBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response %q: %v", recorder.Body.String(), err)
	}
	return payload
}

func TestRequestStemsStatusCodes(t *testing.T) {
	cases := []struct {
		name          string
		body          string
		authenticated bool
		repo          *fakeStemsRepo
		queue         *fakeStemsQueue
		trackRepo     *fakeStemsTrackRepo
		libraryRepo   *fakeStemsLibraryRepo
		wantStatus    int
		wantCode      string
		wantQueued    bool
		wantReason    string
	}{
		{
			name:          "newly queued returns 202",
			authenticated: true,
			repo:          &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusPending}, queued: true, reason: "missing_stems_row"},
			queue:         &fakeStemsQueue{position: 3},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusAccepted,
			wantQueued:    true,
			wantReason:    "missing_stems_row",
		},
		{
			name:          "already ready returns 200",
			authenticated: true,
			repo:          &fakeStemsRepo{row: readyStemsRow(), queued: false, reason: "already_ready"},
			queue:         &fakeStemsQueue{position: -1},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusOK,
			wantQueued:    false,
			wantReason:    "already_ready",
		},
		{
			name:          "active request returns 200",
			authenticated: true,
			repo:          &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusSeparating}, queued: false, reason: "active_request"},
			queue:         &fakeStemsQueue{position: 0},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusOK,
			wantQueued:    false,
			wantReason:    "active_request",
		},
		{
			name:          "explicit stems4 channel set is accepted",
			body:          `{"channelSet":"stems4-demucs-v1"}`,
			authenticated: true,
			repo:          &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusPending}, queued: true, reason: "missing_stems_row"},
			queue:         &fakeStemsQueue{position: 1},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusAccepted,
			wantQueued:    true,
			wantReason:    "missing_stems_row",
		},
		{
			name:          "unknown channel set returns 422",
			body:          `{"channelSet":"stems9-magic-v1"}`,
			authenticated: true,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusUnprocessableEntity,
			wantCode:      "UNKNOWN_CHANNEL_SET",
		},
		{
			name:          "queue full returns 429",
			authenticated: true,
			repo:          &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusPending}, queued: true, reason: "missing_stems_row"},
			queue:         &fakeStemsQueue{enqueueErr: stems.ErrQueueFull},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusTooManyRequests,
			wantCode:      "QUEUE_FULL",
		},
		{
			name:          "unauthenticated returns 401",
			authenticated: false,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusUnauthorized,
			wantCode:      "UNAUTHORIZED",
		},
		{
			name:          "track outside library returns 404",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: false},
			wantStatus:    http.StatusNotFound,
			wantCode:      "TRACK_NOT_FOUND",
		},
		{
			name:          "library lookup failure returns 500",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{err: errors.New("database down")},
			wantStatus:    http.StatusInternalServerError,
			wantCode:      "INTERNAL_ERROR",
		},
		{
			name:          "track without stored audio returns 422",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: &db.Track{}},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusUnprocessableEntity,
			wantCode:      "AUDIO_UNAVAILABLE",
		},
		{
			name:          "repository failure returns 500",
			authenticated: true,
			repo:          &fakeStemsRepo{err: errors.New("write failed")},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusInternalServerError,
			wantCode:      "INTERNAL_ERROR",
		},
		{
			name:          "malformed body returns 400",
			body:          `{"channelSet":`,
			authenticated: true,
			repo:          &fakeStemsRepo{},
			queue:         &fakeStemsQueue{},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusBadRequest,
			wantCode:      "INVALID_REQUEST",
		},
		{
			name:          "queue failure returns 500",
			authenticated: true,
			repo:          &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusPending}, queued: true, reason: "failed_retry"},
			queue:         &fakeStemsQueue{enqueueErr: errors.New("redis down")},
			trackRepo:     &fakeStemsTrackRepo{track: stemsTestTrack()},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusInternalServerError,
			wantCode:      "INTERNAL_ERROR",
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			handlers := NewStemsHandlers(testCase.repo, testCase.queue, testCase.trackRepo, testCase.libraryRepo)
			recorder := httptest.NewRecorder()
			handlers.RequestStems(recorder, newStemsRequest(t, http.MethodPost, testCase.body, testCase.authenticated))

			if recorder.Code != testCase.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", recorder.Code, testCase.wantStatus, recorder.Body.String())
			}
			payload := decodeStemsBody(t, recorder)
			if testCase.wantCode != "" {
				if payload["code"] != testCase.wantCode {
					t.Fatalf("code = %v, want %q", payload["code"], testCase.wantCode)
				}
				return
			}
			if payload["queued"] != testCase.wantQueued {
				t.Fatalf("queued = %v, want %v", payload["queued"], testCase.wantQueued)
			}
			if payload["reason"] != testCase.wantReason {
				t.Fatalf("reason = %v, want %q", payload["reason"], testCase.wantReason)
			}
			if payload["trackId"] != float64(42) {
				t.Fatalf("trackId = %v, want 42", payload["trackId"])
			}
			if payload["stemModelVersion"] == "" || payload["stemModelVersion"] == nil {
				t.Fatalf("stemModelVersion missing from %v", payload)
			}
		})
	}
}

func TestRequestStemsDefaultsToStems5AndStampsExpectedWorker(t *testing.T) {
	repo := &fakeStemsRepo{row: db.TrackStems{Status: db.StemsStatusPending}, queued: true, reason: "missing_stems_row"}
	queue := &fakeStemsQueue{position: 0}
	handlers := NewStemsHandlers(repo, queue, &fakeStemsTrackRepo{track: stemsTestTrack()}, &fakeStemsLibraryRepo{inLibrary: true})

	recorder := httptest.NewRecorder()
	handlers.RequestStems(recorder, newStemsRequest(t, http.MethodPost, "", true))

	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202 (body %s)", recorder.Code, recorder.Body.String())
	}
	if repo.seenIdentity.ChannelSet != stems.ChannelSetStems5Hybrid {
		t.Fatalf("channel set = %q, want the default %q", repo.seenIdentity.ChannelSet, stems.ChannelSetStems5Hybrid)
	}
	if repo.seenIdentity.StemModelVersion != stems.StemModelVersionStems5 {
		t.Fatalf("stem model version = %q, want %q", repo.seenIdentity.StemModelVersion, stems.StemModelVersionStems5)
	}
	if repo.seenStorageKey != "tracks/youtube/x.mp3" {
		t.Fatalf("storage key = %q, want the track's stored object", repo.seenStorageKey)
	}
	var provenance map[string]any
	if err := json.Unmarshal(repo.seenProvenance, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	if provenance["expected_worker"] != stems.WorkerName || provenance["expected_worker_version"] != stems.WorkerVersion {
		t.Fatalf("provenance = %v, want the expected worker identity stamped", provenance)
	}
	if len(queue.enqueued) != 1 {
		t.Fatalf("enqueued %d jobs, want 1", len(queue.enqueued))
	}
	if queue.enqueued[0].ChannelSet != stems.ChannelSetStems5Hybrid || queue.enqueued[0].StorageKey != "tracks/youtube/x.mp3" {
		t.Fatalf("enqueued job = %+v, want the resolved identity and storage key", queue.enqueued[0])
	}
}

func TestRequestStemsDoesNotEnqueueWhenNotQueued(t *testing.T) {
	// A ready row must never re-enter the queue: separation is minutes of CPU
	// and ~20 MB of artifacts, so an idempotent poll has to stay free.
	repo := &fakeStemsRepo{row: readyStemsRow(), queued: false, reason: "already_ready"}
	queue := &fakeStemsQueue{position: -1}
	handlers := NewStemsHandlers(repo, queue, &fakeStemsTrackRepo{track: stemsTestTrack()}, &fakeStemsLibraryRepo{inLibrary: true})

	recorder := httptest.NewRecorder()
	handlers.RequestStems(recorder, newStemsRequest(t, http.MethodPost, "", true))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	if len(queue.enqueued) != 0 {
		t.Fatalf("enqueued %d jobs for a ready row, want 0", len(queue.enqueued))
	}
}

func TestRequestStemsRejectsInvalidTrackID(t *testing.T) {
	handlers := NewStemsHandlers(&fakeStemsRepo{}, &fakeStemsQueue{}, &fakeStemsTrackRepo{track: stemsTestTrack()}, &fakeStemsLibraryRepo{inLibrary: true})
	for _, raw := range []string{"", "abc", "0", "-1"} {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/tracks/x/stems", strings.NewReader(""))
		req.SetPathValue("track_id", raw)
		req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
		recorder := httptest.NewRecorder()
		handlers.RequestStems(recorder, req)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("track_id %q status = %d, want 400", raw, recorder.Code)
		}
	}
}

func TestGetStemsReturnsRowWithArtifactsAndQueuePosition(t *testing.T) {
	row := readyStemsRow()
	repo := &fakeStemsRepo{getRow: &row}
	handlers := NewStemsHandlers(repo, &fakeStemsQueue{position: 2}, &fakeStemsTrackRepo{track: stemsTestTrack()}, &fakeStemsLibraryRepo{inLibrary: true})

	recorder := httptest.NewRecorder()
	handlers.GetStems(recorder, newStemsRequest(t, http.MethodGet, "", true))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", recorder.Code, recorder.Body.String())
	}
	payload := decodeStemsBody(t, recorder)
	if payload["status"] != db.StemsStatusReady {
		t.Fatalf("status = %v, want %q", payload["status"], db.StemsStatusReady)
	}
	if payload["channelSet"] != stems.ChannelSetStems5Hybrid || payload["stemModelVersion"] != stems.StemModelVersionStems5 {
		t.Fatalf("identity = %v/%v", payload["channelSet"], payload["stemModelVersion"])
	}
	if payload["queuePosition"] != float64(2) {
		t.Fatalf("queuePosition = %v, want 2", payload["queuePosition"])
	}
	// Per-stem energy curves are delivered here, from track_stems.artifacts_json.
	artifacts, ok := payload["artifacts"].(map[string]any)
	if !ok {
		t.Fatalf("artifacts = %v, want an object", payload["artifacts"])
	}
	if _, ok := artifacts["energy"]; !ok {
		t.Fatalf("artifacts = %v, want the energy curves", artifacts)
	}
	if payload["sourceFileHash"] != "sha256:deadbeef" {
		t.Fatalf("sourceFileHash = %v", payload["sourceFileHash"])
	}
	if payload["completedAt"] == nil || payload["requestedAt"] == nil || payload["updatedAt"] == nil {
		t.Fatalf("timestamps missing from %v", payload)
	}
}

func TestGetStemsStatusCodes(t *testing.T) {
	cases := []struct {
		name          string
		query         string
		authenticated bool
		repo          *fakeStemsRepo
		libraryRepo   *fakeStemsLibraryRepo
		wantStatus    int
		wantCode      string
	}{
		{
			name:          "missing row returns 404",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusNotFound,
			wantCode:      "STEMS_NOT_FOUND",
		},
		{
			name:          "unknown channel set returns 422",
			query:         "?channelSet=stems9-magic-v1",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusUnprocessableEntity,
			wantCode:      "UNKNOWN_CHANNEL_SET",
		},
		{
			name:          "unauthenticated returns 401",
			authenticated: false,
			repo:          &fakeStemsRepo{},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusUnauthorized,
			wantCode:      "UNAUTHORIZED",
		},
		{
			name:          "track outside library returns 404",
			authenticated: true,
			repo:          &fakeStemsRepo{},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: false},
			wantStatus:    http.StatusNotFound,
			wantCode:      "TRACK_NOT_FOUND",
		},
		{
			name:          "repository failure returns 500",
			authenticated: true,
			repo:          &fakeStemsRepo{getErr: errors.New("database down")},
			libraryRepo:   &fakeStemsLibraryRepo{inLibrary: true},
			wantStatus:    http.StatusInternalServerError,
			wantCode:      "INTERNAL_ERROR",
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			handlers := NewStemsHandlers(testCase.repo, &fakeStemsQueue{position: -1}, &fakeStemsTrackRepo{track: stemsTestTrack()}, testCase.libraryRepo)
			req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/42/stems"+testCase.query, nil)
			req.SetPathValue("track_id", "42")
			if testCase.authenticated {
				req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
			}
			recorder := httptest.NewRecorder()
			handlers.GetStems(recorder, req)

			if recorder.Code != testCase.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", recorder.Code, testCase.wantStatus, recorder.Body.String())
			}
			if payload := decodeStemsBody(t, recorder); payload["code"] != testCase.wantCode {
				t.Fatalf("code = %v, want %q", payload["code"], testCase.wantCode)
			}
		})
	}
}

func TestStemsHandlersReturnServiceDisabledWhenPartiallyWired(t *testing.T) {
	handlers := NewStemsHandlers(nil, nil, nil, nil)
	for name, handler := range map[string]http.HandlerFunc{
		"POST": handlers.RequestStems,
		"GET":  handlers.GetStems,
	} {
		recorder := httptest.NewRecorder()
		handler(recorder, newStemsRequest(t, http.MethodPost, "", true))
		if recorder.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status = %d, want 503", name, recorder.Code)
		}
		if payload := decodeStemsBody(t, recorder); payload["code"] != "SERVICE_DISABLED" {
			t.Fatalf("%s code = %v, want SERVICE_DISABLED", name, payload["code"])
		}
	}
}

func TestRouterServesUnavailableStemsRoutesWhenHandlersAreNil(t *testing.T) {
	router := &Router{mux: http.NewServeMux()}
	router.mux.HandleFunc("POST /api/v1/tracks/{track_id}/stems", unavailableHandler("Stem separation is unavailable"))
	router.mux.HandleFunc("GET /api/v1/tracks/{track_id}/stems", unavailableHandler("Stem separation is unavailable"))

	for _, method := range []string{http.MethodPost, http.MethodGet} {
		recorder := httptest.NewRecorder()
		router.mux.ServeHTTP(recorder, httptest.NewRequest(method, "/api/v1/tracks/42/stems", nil))
		if recorder.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status = %d, want 503", method, recorder.Code)
		}
		if payload := decodeStemsBody(t, recorder); payload["code"] != "SERVICE_DISABLED" {
			t.Fatalf("%s code = %v, want SERVICE_DISABLED", method, payload["code"])
		}
	}
}
