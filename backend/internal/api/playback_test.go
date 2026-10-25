package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

type fakePlaybackTrackRepo struct {
	tracks map[int64]*db.Track
	err    error
	calls  int
}

func (f *fakePlaybackTrackRepo) GetByID(ctx context.Context, id int64) (*db.Track, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	track, ok := f.tracks[id]
	if !ok {
		return nil, db.ErrTrackNotFound
	}
	return track, nil
}

type fakePlaybackLibraryRepo struct {
	allowed map[int64]bool
	err     error
}

func (f *fakePlaybackLibraryRepo) IsTrackInLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	return f.allowed[trackID], nil
}

type fakePlaybackStorage struct {
	info        map[string]*storage.ObjectInfo
	statErr     error
	statErrs    map[string]error
	presignErr  error
	lastTTL     time.Duration
	statKeys    []string
	presignKeys []string
}

func (f *fakePlaybackStorage) StatObject(ctx context.Context, key string) (*storage.ObjectInfo, error) {
	f.statKeys = append(f.statKeys, key)
	if f.statErr != nil {
		return nil, f.statErr
	}
	if err := f.statErrs[key]; err != nil {
		return nil, err
	}
	info, ok := f.info[key]
	if !ok {
		return nil, fmt.Errorf("failed to stat object %s: %w", key, minio.ErrorResponse{Code: "NoSuchKey", StatusCode: http.StatusNotFound})
	}
	return info, nil
}

func (f *fakePlaybackStorage) PresignGetObject(ctx context.Context, key string, expires time.Duration) (string, error) {
	f.presignKeys = append(f.presignKeys, key)
	f.lastTTL = expires
	if f.presignErr != nil {
		return "", f.presignErr
	}
	return "https://objects.example.test/" + key + "?X-Amz-Signature=secret", nil
}

func playbackRequest(t *testing.T, handler http.HandlerFunc, body string) *httptest.ResponseRecorder {
	t.Helper()
	userID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	req := httptest.NewRequest(http.MethodPost, "/api/v1/playback/urls", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID, Email: "user@example.test"})
	rec := httptest.NewRecorder()
	handler(rec, req.WithContext(ctx))
	return rec
}

func newPlaybackHandlerForTrack(track *db.Track, allowed bool, fakeStorage *fakePlaybackStorage) (*PlaybackHandlers, *fakePlaybackTrackRepo) {
	trackRepo := &fakePlaybackTrackRepo{tracks: map[int64]*db.Track{}}
	if track != nil {
		trackRepo.tracks[track.ID] = track
	}
	handler := NewPlaybackHandlers(
		trackRepo,
		&fakePlaybackLibraryRepo{allowed: map[int64]bool{42: allowed}},
		fakeStorage,
	)
	return handler, trackRepo
}

func TestPlaybackURLRouteRequiresAuth(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/playback/urls", bytes.NewBufferString(`{"trackIds":[42]}`))
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("POST /api/v1/playback/urls without auth = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestPlaybackURLIssuanceHidesNonOwnedTrackExistence(t *testing.T) {
	track := &db.Track{ID: 42, StorageKey: sql.NullString{String: "audio/track-42.mp3", Valid: true}}
	nonOwnedHandler, nonOwnedTracks := newPlaybackHandlerForTrack(track, false, &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
		"audio/track-42.mp3": {Size: 100, ContentType: "audio/mpeg"},
	}})
	missingHandler, missingTracks := newPlaybackHandlerForTrack(nil, false, &fakePlaybackStorage{})

	nonOwned := playbackRequest(t, nonOwnedHandler.CreatePlaybackURLs, `{"trackIds":[42]}`)
	missing := playbackRequest(t, missingHandler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if nonOwned.Code != http.StatusNotFound || missing.Code != http.StatusNotFound {
		t.Fatalf("non-owned/missing statuses = %d/%d, want both 404", nonOwned.Code, missing.Code)
	}
	if nonOwned.Body.String() != missing.Body.String() {
		t.Fatalf("non-owned response leaked existence: %q != %q", nonOwned.Body.String(), missing.Body.String())
	}
	if nonOwnedTracks.calls != 0 || missingTracks.calls != 0 {
		t.Fatalf("track repo calls before ownership gate = %d/%d, want 0/0", nonOwnedTracks.calls, missingTracks.calls)
	}
}

func TestPlaybackURLIssuanceRejectsInvalidRequestBodies(t *testing.T) {
	handler, _ := newPlaybackHandlerForTrack(nil, false, &fakePlaybackStorage{})

	cases := []struct {
		name string
		body string
	}{
		{name: "non-positive ID", body: `{"trackIds":[42,0]}`},
		{name: "trailing JSON", body: `{"trackIds":[42]} {}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := playbackRequest(t, handler.CreatePlaybackURLs, tc.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusBadRequest, rec.Body.String())
			}
		})
	}
}

func TestPlaybackURLIssuanceReturnsSignedObjectMetadataAndContractNames(t *testing.T) {
	fakeStorage := &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
		"audio/track-42.mp3": {Size: 123456, ContentType: "audio/mpeg", ETag: "abc123"},
	}}
	handler, _ := newPlaybackHandlerForTrack(&db.Track{
		ID:            42,
		StorageKey:    sql.NullString{String: "audio/track-42.mp3", Valid: true},
		FileSizeBytes: sql.NullInt64{Int64: 999, Valid: true},
		Version:       sql.NullString{String: "v7", Valid: true},
		Codec:         sql.NullString{String: "mp3", Valid: true},
		BitrateKbps:   sql.NullInt32{Int32: 137, Valid: true},
		SampleRateHz:  sql.NullInt32{Int32: 44100, Valid: true},
		Channels:      sql.NullInt32{Int32: 2, Valid: true},
		ContentType:   sql.NullString{String: "audio/mpeg", Valid: true},
	}, true, fakeStorage)
	fixedNow := time.Date(2026, 6, 3, 12, 0, 0, 0, time.UTC)
	handler.now = func() time.Time { return fixedNow }

	var logged bytes.Buffer
	oldLogWriter := log.Writer()
	log.SetOutput(&logged)
	defer log.SetOutput(oldLogWriter)

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if fakeStorage.lastTTL != 10*time.Minute {
		t.Fatalf("presign ttl = %s, want 10m default", fakeStorage.lastTTL)
	}
	if strings.Contains(rec.Body.String(), "storageVersion") || !strings.Contains(rec.Body.String(), "storageKeyVersion") {
		t.Fatalf("response used wrong storage version field: %s", rec.Body.String())
	}
	if strings.Contains(logged.String(), "X-Amz-Signature=secret") || strings.Contains(logged.String(), "objects.example.test") {
		t.Fatalf("signed playback URL leaked to logs: %q", logged.String())
	}

	var got PlaybackURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.URLs) != 1 {
		t.Fatalf("len(urls) = %d, want 1", len(got.URLs))
	}
	item := got.URLs[0]
	if item.TrackID != 42 || item.URL == "" || item.ContentType != "audio/mpeg" || item.SizeBytes != 123456 || item.ETag != "abc123" || item.StorageKeyVersion != "v7" {
		t.Fatalf("unexpected playback item: %+v", item)
	}
	if item.Codec != "mp3" || item.BitrateKbps != 137 || item.SampleRateHz != 44100 || item.Channels != 2 {
		t.Fatalf("playback item quality facts = %+v", item)
	}
	if !item.ExpiresAt.Equal(fixedNow.Add(10 * time.Minute)) {
		t.Fatalf("expiresAt = %s, want %s", item.ExpiresAt, fixedNow.Add(10*time.Minute))
	}
}

func TestPlaybackURLIssuanceClampsTTL(t *testing.T) {
	cases := []struct {
		name       string
		ttlSeconds int
		want       time.Duration
	}{
		{name: "minimum", ttlSeconds: 30, want: time.Minute},
		{name: "maximum", ttlSeconds: 86400, want: 30 * time.Minute},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fakeStorage := &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
				"audio/track-42.mp3": {Size: 123456, ContentType: "audio/mpeg", ETag: "abc123"},
			}}
			handler, _ := newPlaybackHandlerForTrack(&db.Track{
				ID:         42,
				StorageKey: sql.NullString{String: "audio/track-42.mp3", Valid: true},
			}, true, fakeStorage)

			rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42],"ttlSeconds":`+strconv.Itoa(tc.ttlSeconds)+`}`)
			if rec.Code != http.StatusOK {
				t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
			}
			if fakeStorage.lastTTL != tc.want {
				t.Fatalf("presign ttl = %s, want %s", fakeStorage.lastTTL, tc.want)
			}
		})
	}
}

func TestPlaybackURLIssuanceReportsAudioUnavailableWithoutProxyFallback(t *testing.T) {
	handler, _ := newPlaybackHandlerForTrack(&db.Track{ID: 42, StorageKey: sql.NullString{}}, true, &fakePlaybackStorage{})

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs unavailable status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got PlaybackURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.Unavailable) != 1 || got.Unavailable[0].Code != playbackUnavailableCodeAudioUnavailable {
		t.Fatalf("unavailable response = %+v, want %s", got.Unavailable, playbackUnavailableCodeAudioUnavailable)
	}
	if len(got.URLs) != 0 {
		t.Fatalf("urls = %+v, want no proxy fallback url", got.URLs)
	}
}

func TestPlaybackURLIssuanceReportsArtifactMissing(t *testing.T) {
	handler, _ := newPlaybackHandlerForTrack(&db.Track{
		ID:         42,
		StorageKey: sql.NullString{String: "audio/missing.mp3", Valid: true},
	}, true, &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{}})

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs missing artifact status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got PlaybackURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.Unavailable) != 1 || got.Unavailable[0].Code != playbackUnavailableCodeArtifactMissing {
		t.Fatalf("unavailable response = %+v, want %s", got.Unavailable, playbackUnavailableCodeArtifactMissing)
	}
	if len(got.URLs) != 0 {
		t.Fatalf("urls = %+v, want no signed URL for missing artifact", got.URLs)
	}
}

// Typed dependency-interface tests, separate from real-SDK loopback probes.
func TestPlaybackURLStatErrorClassification(t *testing.T) {
	cases := []struct {
		name    string
		err     error
		missing bool
	}{
		{"wrapped_object_404", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "NoSuchKey", StatusCode: 404}), true},
		{"wrapped_access_403", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "AccessDenied", StatusCode: 403, Message: "private upstream detail"}), false},
		{"wrapped_service_503", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "ServiceUnavailable", StatusCode: 503}), false},
		{"wrapped_network", fmt.Errorf("stat: %w", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("private upstream detail")}), false},
		{"wrapped_bucket_404", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "NoSuchBucket", StatusCode: 404}), false},
		{"unknown_404", fmt.Errorf("stat: %w", minio.ErrorResponse{Code: "UnknownError", StatusCode: 404}), false},
		{"unknown_error", errors.New("NoSuchKey not found 404 private upstream detail"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, mixed := range []bool{false, true} {
				t.Run(fmt.Sprintf("mixed_%t", mixed), func(t *testing.T) {
					store := &fakePlaybackStorage{
						info: map[string]*storage.ObjectInfo{
							"audio/1.mp3": {Size: 100, ContentType: "audio/mpeg"},
							"audio/3.mp3": {Size: 100, ContentType: "audio/mpeg"},
						},
						statErrs: map[string]error{"audio/2.mp3": tc.err},
					}
					tracks := &fakePlaybackTrackRepo{tracks: map[int64]*db.Track{}}
					for _, id := range []int64{1, 2, 3} {
						tracks.tracks[id] = &db.Track{ID: id, StorageKey: sql.NullString{String: fmt.Sprintf("audio/%d.mp3", id), Valid: true}}
					}
					h := NewPlaybackHandlers(tracks, &fakePlaybackLibraryRepo{allowed: map[int64]bool{1: true, 2: true, 3: true}}, store)
					body := `{"trackIds":[2]}`
					if mixed {
						body = `{"trackIds":[1,2,3]}`
					}
					r := playbackRequest(t, h.CreatePlaybackURLs, body)
					if r.Header().Get("Cache-Control") != "no-store" || r.Header().Get("Content-Type") != "application/json" {
						t.Fatalf("headers=%v", r.Header())
					}
					if tc.missing {
						var got PlaybackURLResponse
						if err := json.Unmarshal(r.Body.Bytes(), &got); err != nil || r.Code != 200 {
							t.Fatalf("status=%d decode=%v body=%s", r.Code, err, r.Body)
						}
						wantURLs := 0
						if mixed {
							wantURLs = 2
						}
						if len(got.URLs) != wantURLs || len(got.Unavailable) != 1 || got.Unavailable[0] != (PlaybackUnavailableItem{TrackID: 2, Code: "artifact_missing", Message: "stored audio object is unavailable"}) {
							t.Fatalf("unexpected missing-object response: %+v", got)
						}
						if mixed && (got.URLs[0].TrackID != 1 || got.URLs[1].TrackID != 3) {
							t.Fatal("available order changed")
						}
						if !mixed && r.Body.String() != "{\"urls\":[],\"unavailable\":[{\"trackId\":2,\"code\":\"artifact_missing\",\"message\":\"stored audio object is unavailable\"}]}\n" {
							t.Fatal("missing-object bytes changed")
						}
					} else {
						want := "{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"playback URL issuance is unavailable\"}\n"
						if r.Code != 503 || r.Body.String() != want {
							t.Fatalf("status=%d want=503 generic envelope; body=%s", r.Code, r.Body)
						}
						wantCalls, wantSigns := 1, 0
						if mixed {
							wantCalls, wantSigns = 2, 1
						}
						if tracks.calls != wantCalls || len(store.statKeys) != wantCalls || len(store.presignKeys) != wantSigns {
							t.Fatalf("tracks=%d stat=%v sign=%v", tracks.calls, store.statKeys, store.presignKeys)
						}
					}
				})
			}
		})
	}
}

func TestPlaybackURLStatCancellationDoesNotPublish(t *testing.T) {
	for _, cause := range []error{context.Canceled, minio.ErrorResponse{Code: "NoSuchKey", StatusCode: 404}, minio.ErrorResponse{Code: "AccessDenied", StatusCode: 403}} {
		t.Run(cause.Error(), func(t *testing.T) {
			store := &fakePlaybackStorage{statErr: fmt.Errorf("stat: %w", cause)}
			h, tracks := newPlaybackHandlerForTrack(&db.Track{ID: 42, StorageKey: sql.NullString{String: "audio/42.mp3", Valid: true}}, true, store)
			r := playbackRequest(t, func(w http.ResponseWriter, r *http.Request) {
				ctx, cancel := context.WithCancel(r.Context())
				cancel()
				h.CreatePlaybackURLs(w, r.WithContext(ctx))
			}, `{"trackIds":[42,43]}`)
			if r.Body.Len() != 0 || len(r.Header()) != 0 || len(store.presignKeys) != 0 || len(store.statKeys) != 1 || tracks.calls != 1 {
				t.Fatalf("cancellation published response or continued work: body=%s headers=%v", r.Body, r.Header())
			}
		})
	}
}

func TestPlaybackURLIssuanceUsesTrimmedStorageKey(t *testing.T) {
	fakeStorage := &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
		"audio/track-42.mp3": {Size: 123456, ContentType: "audio/mpeg", ETag: "abc123"},
	}}
	handler, _ := newPlaybackHandlerForTrack(&db.Track{
		ID:         42,
		StorageKey: sql.NullString{String: "  audio/track-42.mp3  ", Valid: true},
	}, true, fakeStorage)

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if len(fakeStorage.statKeys) != 1 || fakeStorage.statKeys[0] != "audio/track-42.mp3" {
		t.Fatalf("stat keys = %+v, want trimmed storage key", fakeStorage.statKeys)
	}
	if len(fakeStorage.presignKeys) != 1 || fakeStorage.presignKeys[0] != "audio/track-42.mp3" {
		t.Fatalf("presign keys = %+v, want trimmed storage key", fakeStorage.presignKeys)
	}
}

func TestPlaybackURLIssuanceReportsPresignFailureAsInternalError(t *testing.T) {
	handler, _ := newPlaybackHandlerForTrack(&db.Track{
		ID:         42,
		StorageKey: sql.NullString{String: "audio/track-42.mp3", Valid: true},
	}, true, &fakePlaybackStorage{
		info: map[string]*storage.ObjectInfo{
			"audio/track-42.mp3": {Size: 123456, ContentType: "audio/mpeg", ETag: "abc123"},
		},
		presignErr: errors.New("presign failed"),
	})

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusInternalServerError, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "objects.example.test") || strings.Contains(rec.Body.String(), "X-Amz-Signature") {
		t.Fatalf("error response leaked signed URL: %s", rec.Body.String())
	}
}
