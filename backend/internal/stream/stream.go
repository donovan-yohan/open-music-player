package stream

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

// Handler handles audio streaming requests.
type Handler struct {
	trackRepo *db.TrackRepository
	storage   *storage.Client
}

// NewHandler creates a new streaming handler.
func NewHandler(trackRepo *db.TrackRepository, storage *storage.Client) *Handler {
	return &Handler{
		trackRepo: trackRepo,
		storage:   storage,
	}
}

// rangeSpec represents a parsed HTTP Range header.
type rangeSpec struct {
	start int64
	end   int64
}

// parseRange parses an HTTP Range header value.
// Supports formats: "bytes=0-499", "bytes=500-", "bytes=-500"
func parseRange(rangeHeader string, totalSize int64) (*rangeSpec, error) {
	if rangeHeader == "" {
		return nil, nil
	}

	if !strings.HasPrefix(rangeHeader, "bytes=") {
		return nil, errors.New("invalid range unit")
	}

	rangeSpec := &rangeSpec{}
	spec := strings.TrimPrefix(rangeHeader, "bytes=")

	// Handle multiple ranges (not supported - just use first one)
	if strings.Contains(spec, ",") {
		spec = strings.Split(spec, ",")[0]
	}

	// Parse range format: start-end, start-, -suffix
	re := regexp.MustCompile(`^(\d*)-(\d*)$`)
	matches := re.FindStringSubmatch(strings.TrimSpace(spec))
	if matches == nil {
		return nil, errors.New("invalid range format")
	}

	startStr, endStr := matches[1], matches[2]

	switch {
	case startStr == "" && endStr == "":
		return nil, errors.New("invalid range: both start and end are empty")

	case startStr == "":
		// Suffix range: -500 means last 500 bytes
		suffix, err := strconv.ParseInt(endStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid suffix length: %w", err)
		}
		rangeSpec.start = totalSize - suffix
		if rangeSpec.start < 0 {
			rangeSpec.start = 0
		}
		rangeSpec.end = totalSize - 1

	case endStr == "":
		// Open-ended range: 500- means from byte 500 to end
		start, err := strconv.ParseInt(startStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid start position: %w", err)
		}
		rangeSpec.start = start
		rangeSpec.end = totalSize - 1

	default:
		// Explicit range: 0-499
		start, err := strconv.ParseInt(startStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid start position: %w", err)
		}
		end, err := strconv.ParseInt(endStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid end position: %w", err)
		}
		rangeSpec.start = start
		rangeSpec.end = end
	}

	// Validate range
	if rangeSpec.start < 0 || rangeSpec.start >= totalSize {
		return nil, errors.New("range start out of bounds")
	}
	if rangeSpec.end >= totalSize {
		rangeSpec.end = totalSize - 1
	}
	if rangeSpec.start > rangeSpec.end {
		return nil, errors.New("invalid range: start > end")
	}

	return rangeSpec, nil
}

// getContentType returns the MIME type based on file extension or storage metadata.
func getContentType(storageKey string, storageContentType string) string {
	// Prefer storage content type if set
	if storageContentType != "" && storageContentType != "application/octet-stream" {
		return storageContentType
	}

	// Fallback to extension-based detection
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
		return "audio/mpeg" // Default to MP3
	}
}

// Stream handles GET /api/v1/stream/{track_id}
// Supports HTTP Range requests for seeking in audio players.
func (h *Handler) Stream(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Parse track_id from URL path
	trackIDStr := r.PathValue("track_id")
	if trackIDStr == "" {
		writeJSONError(w, http.StatusBadRequest, "track_id is required")
		return
	}

	trackID, err := strconv.ParseInt(trackIDStr, 10, 64)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid track_id")
		return
	}

	// Get track from database
	track, err := h.trackRepo.GetByID(ctx, trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackNotFound) {
			writeJSONError(w, http.StatusNotFound, "track not found")
			return
		}
		log.Printf("Error fetching track %d: %v", trackID, err)
		writeJSONError(w, http.StatusInternalServerError, "failed to fetch track")
		return
	}

	// Check if track has storage key
	if !track.StorageKey.Valid || track.StorageKey.String == "" {
		writeJSONError(w, http.StatusNotFound, "track audio not available")
		return
	}

	storageKey := track.StorageKey.String

	// Get object metadata from storage
	objInfo, err := h.storage.StatObject(ctx, storageKey)
	if err != nil {
		log.Printf("Error getting object info for %s: %v", storageKey, err)
		writeJSONError(w, http.StatusNotFound, "audio file not found in storage")
		return
	}

	totalSize := objInfo.Size
	contentType := getContentType(storageKey, objInfo.ContentType)

	// Parse Range header
	rangeHeader := r.Header.Get("Range")
	rangeSpec, err := parseRange(rangeHeader, totalSize)
	if err != nil {
		log.Printf("Invalid range header %q: %v", rangeHeader, err)
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", totalSize))
		writeJSONError(w, http.StatusRequestedRangeNotSatisfiable, "invalid range")
		return
	}

	// Set common headers
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "public, max-age=86400") // Cache for 24 hours

	// Handle range request (HTTP 206) or full request (HTTP 200)
	if rangeSpec != nil {
		// Partial content response
		contentLength := rangeSpec.end - rangeSpec.start + 1
		w.Header().Set("Content-Length", strconv.FormatInt(contentLength, 10))
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rangeSpec.start, rangeSpec.end, totalSize))
		w.WriteHeader(http.StatusPartialContent)

		// Stream partial content from storage
		reader, err := h.storage.GetObjectRange(ctx, storageKey, rangeSpec.start, rangeSpec.end)
		if err != nil {
			log.Printf("Error getting object range for %s: %v", storageKey, err)
			return // Headers already sent
		}
		defer reader.Close()

		if _, err := io.Copy(w, reader); err != nil {
			log.Printf("Error streaming range for %s: %v", storageKey, err)
		}
	} else {
		// Full content response
		w.Header().Set("Content-Length", strconv.FormatInt(totalSize, 10))
		w.WriteHeader(http.StatusOK)

		// Stream full content from storage
		reader, _, err := h.storage.GetObject(ctx, storageKey)
		if err != nil {
			log.Printf("Error getting object %s: %v", storageKey, err)
			return // Headers already sent
		}
		defer reader.Close()

		if _, err := io.Copy(w, reader); err != nil {
			log.Printf("Error streaming full content for %s: %v", storageKey, err)
		}
	}
}

// writeJSONError writes a JSON error response.
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{
		"error": message,
	})
}
