package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

type fakePlaybackTrackRepo struct {
	tracks map[int64]*db.Track
	err    error
}

func (f *fakePlaybackTrackRepo) GetByID(ctx context.Context, id int64) (*db.Track, error) {
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
	info       map[string]*storage.ObjectInfo
	statErr    error
	presignErr error
	lastTTL    time.Duration
}

func (f *fakePlaybackStorage) StatObject(ctx context.Context, key string) (*storage.ObjectInfo, error) {
	if f.statErr != nil {
		return nil, f.statErr
	}
	info, ok := f.info[key]
	if !ok {
		return nil, errors.New("not found")
	}
	return info, nil
}

func (f *fakePlaybackStorage) PresignGetObject(ctx context.Context, key string, expires time.Duration) (string, error) {
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

func TestPlaybackURLIssuanceRequiresLibraryOwnership(t *testing.T) {
	handler := NewPlaybackHandlers(
		&fakePlaybackTrackRepo{tracks: map[int64]*db.Track{
			42: {ID: 42, StorageKey: sql.NullString{String: "audio/track-42.mp3", Valid: true}},
		}},
		&fakePlaybackLibraryRepo{allowed: map[int64]bool{42: false}},
		&fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
			"audio/track-42.mp3": {Size: 100, ContentType: "audio/mpeg"},
		}},
	)

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("CreatePlaybackURLs for non-library track = %d, want %d", rec.Code, http.StatusForbidden)
	}
}

func TestPlaybackURLIssuanceReturnsSignedObjectMetadataAndClampsTTL(t *testing.T) {
	fakeStorage := &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
		"audio/track-42.mp3": {Size: 123456, ContentType: "audio/mpeg", ETag: "abc123"},
	}}
	handler := NewPlaybackHandlers(
		&fakePlaybackTrackRepo{tracks: map[int64]*db.Track{
			42: {
				ID:            42,
				StorageKey:    sql.NullString{String: "audio/track-42.mp3", Valid: true},
				FileSizeBytes: sql.NullInt64{Int64: 999, Valid: true},
				Version:       sql.NullString{String: "v7", Valid: true},
			},
		}},
		&fakePlaybackLibraryRepo{allowed: map[int64]bool{42: true}},
		fakeStorage,
	)

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42],"ttlSeconds":86400}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if fakeStorage.lastTTL != 15*time.Minute {
		t.Fatalf("presign ttl = %s, want 15m clamp", fakeStorage.lastTTL)
	}

	var got PlaybackURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.URLs) != 1 {
		t.Fatalf("len(urls) = %d, want 1", len(got.URLs))
	}
	item := got.URLs[0]
	if item.TrackID != 42 || item.URL == "" || item.ContentType != "audio/mpeg" || item.SizeBytes != 123456 || item.ETag != "abc123" || item.StorageVersion != "v7" {
		t.Fatalf("unexpected playback item: %+v", item)
	}
	if item.ExpiresAt.IsZero() {
		t.Fatalf("expiresAt was not set")
	}
}

func TestPlaybackURLIssuanceReportsUnavailableWithoutProxyFallback(t *testing.T) {
	handler := NewPlaybackHandlers(
		&fakePlaybackTrackRepo{tracks: map[int64]*db.Track{
			42: {ID: 42, StorageKey: sql.NullString{}},
		}},
		&fakePlaybackLibraryRepo{allowed: map[int64]bool{42: true}},
		&fakePlaybackStorage{},
	)

	rec := playbackRequest(t, handler.CreatePlaybackURLs, `{"trackIds":[42]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("CreatePlaybackURLs unavailable status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got PlaybackURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.Unavailable) != 1 || got.Unavailable[0].Code != "AUDIO_UNAVAILABLE" {
		t.Fatalf("unavailable response = %+v, want AUDIO_UNAVAILABLE", got.Unavailable)
	}
	if len(got.URLs) != 0 {
		t.Fatalf("urls = %+v, want no proxy fallback url", got.URLs)
	}
}
