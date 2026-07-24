package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
)

type maintenanceTrackStore interface {
	GetByID(ctx context.Context, id int64) (*db.Track, error)
	GetMaintenanceCandidates(ctx context.Context, includeMetadata, includeAnalysis bool, staleAfter time.Duration, limit int) ([]db.Track, error)
	GetAudioQualityMaintenanceCandidates(ctx context.Context, limit int) ([]db.Track, error)
}

type maintenanceProcessor interface {
	RepairMetadata(ctx context.Context, track *db.Track, opts processor.MetadataRepairOptions) (processor.MetadataRepairResult, error)
	RequestAnalysisRepair(ctx context.Context, track *db.Track, opts processor.AnalysisRepairOptions) (processor.AnalysisRepairResult, error)
	RepairAudioQuality(ctx context.Context, track *db.Track) (processor.AudioQualityRepairResult, error)
}

type MaintenanceHandlers struct {
	tracks    maintenanceTrackStore
	processor maintenanceProcessor
}

func NewMaintenanceHandlers(tracks maintenanceTrackStore, processor maintenanceProcessor) *MaintenanceHandlers {
	return &MaintenanceHandlers{tracks: tracks, processor: processor}
}

type maintenanceRepairRequest struct {
	TrackIDs          []int64 `json:"trackIds"`
	Metadata          *bool   `json:"metadata,omitempty"`
	Analysis          *bool   `json:"analysis,omitempty"`
	AudioQuality      *bool   `json:"audioQuality,omitempty"`
	ForceMetadata     bool    `json:"forceMetadata"`
	ForceAnalysis     bool    `json:"forceAnalysis"`
	StaleAfterMinutes int     `json:"staleAfterMinutes"`
	Limit             int     `json:"limit"`
}

type maintenanceRepairResponse struct {
	Tracks   []maintenanceTrackRepairResult `json:"tracks"`
	Summary  maintenanceRepairSummary       `json:"summary"`
	Criteria maintenanceRepairCriteria      `json:"criteria"`
}

type maintenanceTrackRepairResult struct {
	TrackID      int64                               `json:"trackId"`
	Title        string                              `json:"title"`
	Metadata     *processor.MetadataRepairResult     `json:"metadata,omitempty"`
	Analysis     *processor.AnalysisRepairResult     `json:"analysis,omitempty"`
	AudioQuality *processor.AudioQualityRepairResult `json:"audioQuality,omitempty"`
	Errors       []string                            `json:"errors,omitempty"`
}

type maintenanceRepairSummary struct {
	Selected            int `json:"selected"`
	MetadataDone        int `json:"metadataDone"`
	MetadataSkipped     int `json:"metadataSkipped"`
	AnalysisQueued      int `json:"analysisQueued"`
	AnalysisSkipped     int `json:"analysisSkipped"`
	AudioQualityDone    int `json:"audioQualityDone"`
	AudioQualitySkipped int `json:"audioQualitySkipped"`
	Errors              int `json:"errors"`
}

type maintenanceRepairCriteria struct {
	Metadata          bool    `json:"metadata"`
	Analysis          bool    `json:"analysis"`
	AudioQuality      bool    `json:"audioQuality"`
	ForceMetadata     bool    `json:"forceMetadata"`
	ForceAnalysis     bool    `json:"forceAnalysis"`
	StaleAfterMinutes int     `json:"staleAfterMinutes"`
	Limit             int     `json:"limit"`
	TrackIDs          []int64 `json:"trackIds,omitempty"`
}

func (h *MaintenanceHandlers) RepairTracks(w http.ResponseWriter, r *http.Request) {
	if h == nil || h.tracks == nil || h.processor == nil {
		writeMaintenanceError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "maintenance repair is unavailable")
		return
	}
	var req maintenanceRepairRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeMaintenanceError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid repair request JSON")
		return
	}
	includeMetadata := boolDefault(req.Metadata, true)
	includeAnalysis := boolDefault(req.Analysis, true)
	includeAudioQuality := boolDefault(req.AudioQuality, false)
	if !includeMetadata && !includeAnalysis && !includeAudioQuality {
		writeMaintenanceError(w, http.StatusBadRequest, "VALIDATION_ERROR", "metadata, analysis, or audio quality repair must be enabled")
		return
	}
	limit := req.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	staleMinutes := req.StaleAfterMinutes
	if staleMinutes <= 0 {
		staleMinutes = 30
	}
	staleAfter := time.Duration(staleMinutes) * time.Minute

	tracks, err := h.selectRepairTracks(r.Context(), req.TrackIDs, includeMetadata, includeAnalysis, includeAudioQuality, staleAfter, limit)
	if err != nil {
		if errors.Is(err, errInvalidMaintenanceRequest) {
			writeMaintenanceError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
			return
		}
		if errors.Is(err, db.ErrTrackNotFound) {
			writeMaintenanceError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
			return
		}
		writeMaintenanceError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to select maintenance tracks")
		return
	}

	resp := maintenanceRepairResponse{
		Tracks: make([]maintenanceTrackRepairResult, 0, len(tracks)),
		Criteria: maintenanceRepairCriteria{
			Metadata:          includeMetadata,
			Analysis:          includeAnalysis,
			AudioQuality:      includeAudioQuality,
			ForceMetadata:     req.ForceMetadata,
			ForceAnalysis:     req.ForceAnalysis,
			StaleAfterMinutes: staleMinutes,
			Limit:             limit,
			TrackIDs:          req.TrackIDs,
		},
	}
	resp.Summary.Selected = len(tracks)
	for i := range tracks {
		track := tracks[i]
		item := maintenanceTrackRepairResult{TrackID: track.ID, Title: track.Title}
		if includeMetadata {
			metadata, err := h.processor.RepairMetadata(r.Context(), &track, processor.MetadataRepairOptions{Force: req.ForceMetadata})
			item.Metadata = &metadata
			if err != nil {
				item.Errors = append(item.Errors, err.Error())
				resp.Summary.Errors++
			} else if metadata.Status == "processed" {
				resp.Summary.MetadataDone++
			} else {
				resp.Summary.MetadataSkipped++
			}
		}
		if includeAnalysis {
			analysis, err := h.processor.RequestAnalysisRepair(r.Context(), &track, processor.AnalysisRepairOptions{Force: req.ForceAnalysis, StaleAfter: staleAfter})
			item.Analysis = &analysis
			if err != nil {
				item.Errors = append(item.Errors, err.Error())
				resp.Summary.Errors++
			} else if analysis.Queued {
				resp.Summary.AnalysisQueued++
			} else {
				resp.Summary.AnalysisSkipped++
			}
		}
		if includeAudioQuality {
			audioQuality, err := h.processor.RepairAudioQuality(r.Context(), &track)
			if err != nil {
				log.Printf("Warning: audio quality backfill failed for track %d: %v", track.ID, err)
				item.Errors = append(item.Errors, err.Error())
				resp.Summary.Errors++
			} else {
				item.AudioQuality = &audioQuality
				if audioQuality.Status == "processed" {
					resp.Summary.AudioQualityDone++
				} else {
					resp.Summary.AudioQualitySkipped++
				}
			}
		}
		resp.Tracks = append(resp.Tracks, item)
	}
	writeMaintenanceJSON(w, http.StatusOK, resp)
}

var errInvalidMaintenanceRequest = errors.New("invalid maintenance repair request")

func (h *MaintenanceHandlers) selectRepairTracks(ctx context.Context, ids []int64, includeMetadata, includeAnalysis, includeAudioQuality bool, staleAfter time.Duration, limit int) ([]db.Track, error) {
	if len(ids) == 0 {
		if includeAudioQuality && (includeMetadata || includeAnalysis) && limit < 2 {
			return nil, fmt.Errorf("%w: combined maintenance requires limit of at least 2", errInvalidMaintenanceRequest)
		}
		tracks := make([]db.Track, 0, limit)
		seen := make(map[int64]struct{}, limit)
		qualityLimit := limit
		if includeAudioQuality && (includeMetadata || includeAnalysis) && limit > 1 {
			// Reserve bounded capacity for both candidate classes so a long
			// quality backlog cannot starve metadata/analysis maintenance.
			qualityLimit = (limit + 1) / 2
		}
		if includeAudioQuality {
			qualityTracks, err := h.tracks.GetAudioQualityMaintenanceCandidates(ctx, qualityLimit)
			if err != nil {
				return nil, err
			}
			for _, track := range qualityTracks {
				tracks = append(tracks, track)
				seen[track.ID] = struct{}{}
			}
		}
		if len(tracks) < limit && (includeMetadata || includeAnalysis) {
			// Fetch up to the overall cap because candidates can overlap the
			// reserved quality slice; dedupe below must still reach later rows.
			otherLimit := limit
			otherTracks, err := h.tracks.GetMaintenanceCandidates(ctx, includeMetadata, includeAnalysis, staleAfter, otherLimit)
			if err != nil {
				return nil, err
			}
			for _, track := range otherTracks {
				if _, ok := seen[track.ID]; ok {
					continue
				}
				tracks = append(tracks, track)
				if len(tracks) == limit {
					break
				}
			}
		}
		return tracks, nil
	}
	seen := make(map[int64]struct{}, len(ids))
	tracks := make([]db.Track, 0, len(ids))
	for _, id := range ids {
		if id <= 0 {
			return nil, errInvalidMaintenanceRequest
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		track, err := h.tracks.GetByID(ctx, id)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, *track)
		if len(tracks) >= limit {
			break
		}
	}
	return tracks, nil
}

func boolDefault(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}
	return *value
}

func writeMaintenanceJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func writeMaintenanceError(w http.ResponseWriter, status int, code, message string) {
	writeMaintenanceJSON(w, status, ErrorResponse{Code: code, Message: message})
}
