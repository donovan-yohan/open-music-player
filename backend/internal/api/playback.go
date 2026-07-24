package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

const (
	defaultPlaybackURLTTL = 10 * time.Minute
	minPlaybackURLTTL     = 1 * time.Minute
	maxPlaybackURLTTL     = 30 * time.Minute
	maxPlaybackURLBatch   = 50

	playbackUnavailableCodeAudioUnavailable = "audio_unavailable"
	playbackUnavailableCodeArtifactMissing  = "artifact_missing"
)

type playbackTrackRepository interface {
	GetByID(ctx context.Context, id int64) (*db.Track, error)
}

type playbackLibraryRepository interface {
	IsTrackInLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (bool, error)
}

type playbackURLStorage interface {
	StatObject(ctx context.Context, key string) (*storage.ObjectInfo, error)
	PresignGetObject(ctx context.Context, key string, expires time.Duration) (string, error)
}

// PlaybackHandlers issues short-lived direct object URLs for authorized playback/download.
type PlaybackHandlers struct {
	trackRepo   playbackTrackRepository
	libraryRepo playbackLibraryRepository
	storage     playbackURLStorage
	now         func() time.Time
}

func NewPlaybackHandlers(trackRepo playbackTrackRepository, libraryRepo playbackLibraryRepository, storageClient playbackURLStorage) *PlaybackHandlers {
	return &PlaybackHandlers{
		trackRepo:   trackRepo,
		libraryRepo: libraryRepo,
		storage:     storageClient,
		now:         time.Now,
	}
}

type PlaybackURLRequest struct {
	TrackIDs   []int64 `json:"trackIds"`
	TTLSeconds int     `json:"ttlSeconds,omitempty"`
}

type PlaybackURLResponse struct {
	URLs        []PlaybackURLItem         `json:"urls"`
	Unavailable []PlaybackUnavailableItem `json:"unavailable,omitempty"`
}

type PlaybackURLItem struct {
	TrackID           int64     `json:"trackId"`
	URL               string    `json:"url"`
	ExpiresAt         time.Time `json:"expiresAt"`
	ContentType       string    `json:"contentType"`
	SizeBytes         int64     `json:"sizeBytes"`
	Codec             string    `json:"codec,omitempty"`
	BitrateKbps       int       `json:"bitrateKbps,omitempty"`
	SampleRateHz      int       `json:"sampleRateHz,omitempty"`
	Channels          int       `json:"channels,omitempty"`
	ETag              string    `json:"etag,omitempty"`
	StorageKeyVersion string    `json:"storageKeyVersion,omitempty"`
}

type PlaybackUnavailableItem struct {
	TrackID int64  `json:"trackId"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type playbackErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// CreatePlaybackURLs handles POST /api/v1/playback/urls.
func (h *PlaybackHandlers) CreatePlaybackURLs(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.trackRepo == nil || h.libraryRepo == nil || h.storage == nil {
		writePlaybackError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "playback URL issuance is unavailable")
		return
	}

	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaybackError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req PlaybackURLRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writePlaybackError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid JSON request body")
		return
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writePlaybackError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid JSON request body")
		return
	}

	trackIDs, err := validateAndDedupeTrackIDs(req.TrackIDs)
	if err != nil {
		writePlaybackError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	if len(trackIDs) == 0 {
		writePlaybackError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackIds must contain at least one track ID")
		return
	}
	if len(trackIDs) > maxPlaybackURLBatch {
		writePlaybackError(w, http.StatusBadRequest, "INVALID_REQUEST", "too many track IDs requested")
		return
	}

	ttl := clampPlaybackTTL(req.TTLSeconds)
	expiresAt := h.now().Add(ttl).UTC()
	resp := PlaybackURLResponse{
		URLs: make([]PlaybackURLItem, 0, len(trackIDs)),
	}

	for _, trackID := range trackIDs {
		inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
		if err != nil {
			writePlaybackError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library ownership")
			return
		}
		if !inLibrary {
			writePlaybackError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
			return
		}

		track, err := h.trackRepo.GetByID(r.Context(), trackID)
		if err != nil {
			if errors.Is(err, db.ErrTrackNotFound) {
				writePlaybackError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
				return
			}
			writePlaybackError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to load track")
			return
		}

		storageKey := strings.TrimSpace(track.StorageKey.String)
		if !track.StorageKey.Valid || storageKey == "" {
			resp.Unavailable = append(resp.Unavailable, PlaybackUnavailableItem{
				TrackID: trackID,
				Code:    playbackUnavailableCodeAudioUnavailable,
				Message: "track has no stored audio object",
			})
			continue
		}

		objInfo, err := h.storage.StatObject(r.Context(), storageKey)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			resp.Unavailable = append(resp.Unavailable, PlaybackUnavailableItem{
				TrackID: trackID,
				Code:    playbackUnavailableCodeArtifactMissing,
				Message: "stored audio object is unavailable",
			})
			continue
		}

		url, err := h.storage.PresignGetObject(r.Context(), storageKey, ttl)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			writePlaybackError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to issue playback URL")
			return
		}

		item := PlaybackURLItem{
			TrackID:     trackID,
			URL:         url,
			ExpiresAt:   expiresAt,
			ContentType: playbackContentType(storageKey, objInfo.ContentType),
			SizeBytes:   objInfo.Size,
			ETag:        objInfo.ETag,
		}
		if track.Version.Valid {
			item.StorageKeyVersion = track.Version.String
		}
		if track.Codec.Valid {
			item.Codec = track.Codec.String
		}
		if track.BitrateKbps.Valid {
			item.BitrateKbps = int(track.BitrateKbps.Int32)
		}
		if track.SampleRateHz.Valid {
			item.SampleRateHz = int(track.SampleRateHz.Int32)
		}
		if track.Channels.Valid {
			item.Channels = int(track.Channels.Int32)
		}
		if track.ContentType.Valid {
			item.ContentType = track.ContentType.String
		}
		resp.URLs = append(resp.URLs, item)
	}

	writePlaybackJSON(w, http.StatusOK, resp)
}

func validateAndDedupeTrackIDs(ids []int64) ([]int64, error) {
	seen := make(map[int64]struct{}, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if id <= 0 {
			return nil, errors.New("trackIds must contain only positive track IDs")
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out, nil
}

func clampPlaybackTTL(ttlSeconds int) time.Duration {
	if ttlSeconds <= 0 {
		return defaultPlaybackURLTTL
	}
	ttl := time.Duration(ttlSeconds) * time.Second
	if ttl < minPlaybackURLTTL {
		return minPlaybackURLTTL
	}
	if ttl > maxPlaybackURLTTL {
		return maxPlaybackURLTTL
	}
	return ttl
}

func playbackContentType(storageKey string, storageContentType string) string {
	if storageContentType != "" && storageContentType != "application/octet-stream" {
		return storageContentType
	}

	key := strings.ToLower(storageKey)
	switch {
	case strings.HasSuffix(key, ".mp3"):
		return "audio/mpeg"
	case strings.HasSuffix(key, ".m4a"), strings.HasSuffix(key, ".aac"):
		return "audio/mp4"
	case strings.HasSuffix(key, ".ogg"), strings.HasSuffix(key, ".oga"):
		return "audio/ogg"
	case strings.HasSuffix(key, ".opus"):
		return "audio/opus"
	case strings.HasSuffix(key, ".flac"):
		return "audio/flac"
	case strings.HasSuffix(key, ".wav"):
		return "audio/wav"
	case strings.HasSuffix(key, ".webm"):
		return "audio/webm"
	default:
		return "audio/mpeg"
	}
}

func writePlaybackJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writePlaybackError(w http.ResponseWriter, status int, code, message string) {
	writePlaybackJSON(w, status, playbackErrorResponse{Code: code, Message: message})
}
