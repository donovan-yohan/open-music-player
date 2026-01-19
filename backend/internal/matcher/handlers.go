package matcher

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// Handler handles HTTP requests for auto-matching
type Handler struct {
	matcher   *Matcher
	trackRepo *db.TrackRepository
}

// NewHandler creates a new matcher Handler
func NewHandler(matcher *Matcher, trackRepo *db.TrackRepository) *Handler {
	return &Handler{
		matcher:   matcher,
		trackRepo: trackRepo,
	}
}

// MatchRequest is the request body for matching a track
type MatchRequest struct {
	Title      string `json:"title"`
	Uploader   string `json:"uploader,omitempty"`
	DurationMs int    `json:"durationMs,omitempty"`
	SourceURL  string `json:"sourceUrl,omitempty"`
}

// MatchResponse is the response for a match request
type MatchResponse struct {
	TrackID     int64         `json:"track_id,omitempty"`
	Verified    bool          `json:"verified"`
	BestMatch   *MatchResult  `json:"best_match,omitempty"`
	Suggestions []MatchResult `json:"suggestions,omitempty"`
	ParsedTitle *ParsedTitle  `json:"parsed_title"`
}

// HandleMatch handles POST /api/v1/match - matches metadata to MusicBrainz
func (h *Handler) HandleMatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req MatchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	if req.Title == "" {
		writeError(w, http.StatusBadRequest, "Title is required")
		return
	}

	metadata := TrackMetadata{
		Title:      req.Title,
		Uploader:   req.Uploader,
		DurationMs: req.DurationMs,
	}

	// Check if this looks like non-music content
	if h.matcher.MatchNonMusic(metadata) {
		writeJSON(w, http.StatusOK, MatchResponse{
			Verified: false,
			ParsedTitle: &ParsedTitle{
				Raw:   req.Title,
				Track: req.Title,
			},
		})
		return
	}

	output, err := h.matcher.Match(r.Context(), metadata)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Matching failed: "+err.Error())
		return
	}

	resp := MatchResponse{
		Verified:    output.Verified,
		BestMatch:   output.BestMatch,
		Suggestions: output.Suggestions,
		ParsedTitle: output.ParsedTitle,
	}

	writeJSON(w, http.StatusOK, resp)
}

// HandleMatchTrack handles POST /api/v1/tracks/{id}/match - matches an existing track
func (h *Handler) HandleMatchTrack(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract track ID from path
	idStr := r.PathValue("id")
	if idStr == "" {
		writeError(w, http.StatusBadRequest, "Track ID is required")
		return
	}

	trackID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid track ID")
		return
	}

	// Get the track
	track, err := h.trackRepo.GetByID(r.Context(), trackID)
	if err != nil {
		if err == db.ErrTrackNotFound {
			writeError(w, http.StatusNotFound, "Track not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "Failed to get track")
		return
	}

	// Build metadata from track
	metadata := TrackMetadata{
		Title: track.Title,
	}
	if track.Artist.Valid {
		metadata.Uploader = track.Artist.String
	}
	if track.DurationMs.Valid {
		metadata.DurationMs = int(track.DurationMs.Int32)
	}

	// Run matching
	output, err := h.matcher.Match(r.Context(), metadata)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Matching failed: "+err.Error())
		return
	}

	// Update the track with match results
	if output.BestMatch != nil {
		update := &db.MBMatchUpdate{
			MBVerified: output.Verified,
		}

		// Parse MBIDs
		if output.BestMatch.MBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.MBID); err == nil {
				update.MBRecordingID = &mbid
			}
		}
		if output.BestMatch.ArtistMBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.ArtistMBID); err == nil {
				update.MBArtistID = &mbid
			}
		}
		if output.BestMatch.AlbumMBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.AlbumMBID); err == nil {
				update.MBReleaseID = &mbid
			}
		}

		// Store suggestions in metadata_json if not verified
		if !output.Verified && len(output.Suggestions) > 0 {
			suggestions := BuildSuggestionsJSON(output.Suggestions)
			if suggestionsJSON, err := json.Marshal(suggestions); err == nil {
				update.MetadataJSON = suggestionsJSON
			}
		}

		if err := h.trackRepo.UpdateMBMatch(r.Context(), trackID, update); err != nil {
			writeError(w, http.StatusInternalServerError, "Failed to update track")
			return
		}
	}

	resp := MatchResponse{
		TrackID:     trackID,
		Verified:    output.Verified,
		BestMatch:   output.BestMatch,
		Suggestions: output.Suggestions,
		ParsedTitle: output.ParsedTitle,
	}

	writeJSON(w, http.StatusOK, resp)
}

// HandleConfirmMatch handles POST /api/v1/tracks/{id}/confirm-match - confirms a suggested match
func (h *Handler) HandleConfirmMatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	idStr := r.PathValue("id")
	if idStr == "" {
		writeError(w, http.StatusBadRequest, "Track ID is required")
		return
	}

	trackID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid track ID")
		return
	}

	var req struct {
		RecordingMBID string `json:"recordingMbid"`
		ArtistMBID    string `json:"artistMbid,omitempty"`
		ReleaseMBID   string `json:"releaseMbid,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	if req.RecordingMBID == "" {
		writeError(w, http.StatusBadRequest, "Recording MBID is required")
		return
	}

	// Verify track exists
	if _, err := h.trackRepo.GetByID(r.Context(), trackID); err != nil {
		if err == db.ErrTrackNotFound {
			writeError(w, http.StatusNotFound, "Track not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "Failed to get track")
		return
	}

	update := &db.MBMatchUpdate{
		MBVerified: true,
	}

	// Parse and set MBIDs
	if mbid, err := uuid.Parse(req.RecordingMBID); err == nil {
		update.MBRecordingID = &mbid
	} else {
		writeError(w, http.StatusBadRequest, "Invalid recording MBID")
		return
	}

	if req.ArtistMBID != "" {
		if mbid, err := uuid.Parse(req.ArtistMBID); err == nil {
			update.MBArtistID = &mbid
		}
	}

	if req.ReleaseMBID != "" {
		if mbid, err := uuid.Parse(req.ReleaseMBID); err == nil {
			update.MBReleaseID = &mbid
		}
	}

	if err := h.trackRepo.UpdateMBMatch(r.Context(), trackID, update); err != nil {
		writeError(w, http.StatusInternalServerError, "Failed to update track")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":  true,
		"trackId":  trackID,
		"verified": true,
	})
}

// LinkMBRequest is the request body for linking a track to MusicBrainz
type LinkMBRequest struct {
	MBRecordingID  string `json:"mb_recording_id"`
	UpdateMetadata bool   `json:"update_metadata,omitempty"`
}

// LinkMBResponse is the response for a link-mb request
type LinkMBResponse struct {
	TrackID         int64      `json:"track_id"`
	MBRecordingID   string     `json:"mb_recording_id"`
	MBArtistID      string     `json:"mb_artist_id,omitempty"`
	MBReleaseID     string     `json:"mb_release_id,omitempty"`
	Verified        bool       `json:"verified"`
	MetadataUpdated bool       `json:"metadata_updated"`
	Track           *TrackInfo `json:"track,omitempty"`
}

// TrackInfo contains basic track information for the response
type TrackInfo struct {
	Title    string `json:"title"`
	Artist   string `json:"artist,omitempty"`
	Album    string `json:"album,omitempty"`
	Duration int    `json:"duration,omitempty"`
}

// HandleLinkMB handles POST /api/v1/tracks/{id}/link-mb - links a track to a MusicBrainz recording
func (h *Handler) HandleLinkMB(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract track ID from path
	idStr := r.PathValue("id")
	if idStr == "" {
		writeError(w, http.StatusBadRequest, "Track ID is required")
		return
	}

	trackID, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid track ID")
		return
	}

	// Parse request body
	var req LinkMBRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	if req.MBRecordingID == "" {
		writeError(w, http.StatusBadRequest, "mb_recording_id is required")
		return
	}

	// Validate MBID format
	recordingID, err := uuid.Parse(req.MBRecordingID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid mb_recording_id format")
		return
	}

	// Verify track exists
	track, err := h.trackRepo.GetByID(r.Context(), trackID)
	if err != nil {
		if err == db.ErrTrackNotFound {
			writeError(w, http.StatusNotFound, "Track not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "Failed to get track")
		return
	}

	// Fetch recording details from MusicBrainz
	mbRecording, err := h.matcher.MBClient().GetRecording(r.Context(), req.MBRecordingID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "Failed to fetch recording from MusicBrainz: "+err.Error())
		return
	}

	// Build update with MB IDs
	update := &db.MBMatchUpdate{
		MBRecordingID: &recordingID,
		MBVerified:    true,
	}

	// Extract artist and release IDs from MB response
	var artistIDStr, releaseIDStr string
	if mbRecording.ArtistID != "" {
		if artistID, err := uuid.Parse(mbRecording.ArtistID); err == nil {
			update.MBArtistID = &artistID
			artistIDStr = mbRecording.ArtistID
		}
	}
	if mbRecording.AlbumID != "" {
		if releaseID, err := uuid.Parse(mbRecording.AlbumID); err == nil {
			update.MBReleaseID = &releaseID
			releaseIDStr = mbRecording.AlbumID
		}
	}

	// Update the track with MB match data
	if err := h.trackRepo.UpdateMBMatch(r.Context(), trackID, update); err != nil {
		writeError(w, http.StatusInternalServerError, "Failed to update track")
		return
	}

	// Optionally update metadata from MusicBrainz
	metadataUpdated := false
	if req.UpdateMetadata {
		metadataUpdate := &db.MetadataUpdate{
			Title:  mbRecording.Title,
			Artist: mbRecording.Artist,
			Album:  mbRecording.Album,
		}
		if mbRecording.Duration > 0 {
			metadataUpdate.DurationMs = mbRecording.Duration
		}

		if err := h.trackRepo.UpdateMetadata(r.Context(), trackID, metadataUpdate); err != nil {
			// Log but don't fail - the MB link was successful
			// The metadata update is optional
		} else {
			metadataUpdated = true
		}
	}

	// Build response
	resp := LinkMBResponse{
		TrackID:         trackID,
		MBRecordingID:   req.MBRecordingID,
		MBArtistID:      artistIDStr,
		MBReleaseID:     releaseIDStr,
		Verified:        true,
		MetadataUpdated: metadataUpdated,
		Track: &TrackInfo{
			Title:    track.Title,
			Duration: int(track.DurationMs.Int32),
		},
	}

	if track.Artist.Valid {
		resp.Track.Artist = track.Artist.String
	}
	if track.Album.Valid {
		resp.Track.Album = track.Album.String
	}

	// If metadata was updated, use the new values in response
	if metadataUpdated {
		resp.Track.Title = mbRecording.Title
		resp.Track.Artist = mbRecording.Artist
		resp.Track.Album = mbRecording.Album
		if mbRecording.Duration > 0 {
			resp.Track.Duration = mbRecording.Duration
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{
		"error": message,
	})
}
