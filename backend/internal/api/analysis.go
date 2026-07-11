package api

import (
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type AnalysisHandlers struct {
	analysisRepo *db.AnalysisRepository
	libraryRepo  *db.LibraryRepository
}

func NewAnalysisHandlers(analysisRepo *db.AnalysisRepository, libraryRepo *db.LibraryRepository) *AnalysisHandlers {
	return &AnalysisHandlers{analysisRepo: analysisRepo, libraryRepo: libraryRepo}
}

type AnalysisResponse struct {
	TrackID       int64           `json:"track_id"`
	SchemaVersion int             `json:"schema_version"`
	Status        string          `json:"status"`
	Summary       json.RawMessage `json:"summary,omitempty"`
	Overrides     json.RawMessage `json:"overrides,omitempty"`
	Artifacts     json.RawMessage `json:"artifacts,omitempty"`
	Provenance    json.RawMessage `json:"provenance,omitempty"`
	Error         string          `json:"error,omitempty"`
	RequestedAt   string          `json:"requested_at"`
	StartedAt     string          `json:"started_at,omitempty"`
	CompletedAt   string          `json:"completed_at,omitempty"`
	UpdatedAt     string          `json:"updated_at"`
}

type AnalysisOverridesRequest struct {
	Overrides json.RawMessage `json:"overrides"`
}

const maxAnalysisOverridesRequestBytes = 1 << 20

const manualAnalysisOverrideProvenance = "manual_override"

func newAnalysisResponse(analysis *db.TrackAnalysis) AnalysisResponse {
	resp := AnalysisResponse{
		TrackID:       analysis.TrackID,
		SchemaVersion: analysis.SchemaVersion,
		Status:        analysis.Status,
		Summary:       analysis.SummaryJSON,
		Overrides:     analysis.OverridesJSON,
		Artifacts:     analysis.ArtifactsJSON,
		Provenance:    analysis.ProvenanceJSON,
		RequestedAt:   analysis.RequestedAt.Format("2006-01-02T15:04:05Z"),
		UpdatedAt:     analysis.UpdatedAt.UTC().Format(time.RFC3339Nano),
	}
	if analysis.Error.Valid {
		resp.Error = analysis.Error.String
	}
	if analysis.StartedAt.Valid {
		resp.StartedAt = analysis.StartedAt.Time.Format("2006-01-02T15:04:05Z")
	}
	if analysis.CompletedAt.Valid {
		resp.CompletedAt = analysis.CompletedAt.Time.Format("2006-01-02T15:04:05Z")
	}
	return resp
}

func (h *AnalysisHandlers) GetTrackAnalysis(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.analysisRepo == nil || h.libraryRepo == nil {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "track analysis is unavailable")
		return
	}
	trackID, err := strconv.ParseInt(r.PathValue("track_id"), 10, 64)
	if err != nil || trackID <= 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}
	inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library membership")
		return
	}
	if !inLibrary {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return
	}
	analysis, err := h.analysisRepo.GetByTrackID(r.Context(), trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackAnalysisNotFound) {
			writeLibraryError(w, http.StatusNotFound, "ANALYSIS_NOT_FOUND", "track analysis not found")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve track analysis")
		return
	}
	writeLibraryJSON(w, http.StatusOK, newAnalysisResponse(analysis))
}

func (h *AnalysisHandlers) UpdateTrackAnalysisOverrides(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.analysisRepo == nil || h.libraryRepo == nil {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "track analysis is unavailable")
		return
	}
	trackID, err := strconv.ParseInt(r.PathValue("track_id"), 10, 64)
	if err != nil || trackID <= 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}
	inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library membership")
		return
	}
	if !inLibrary {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return
	}

	req, err := decodeAnalysisOverridesRequest(w, r)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}
	normalized, err := normalizeAnalysisOverrides(req.Overrides)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}
	analysis, err := h.analysisRepo.SetOverrides(r.Context(), trackID, normalized)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to save analysis overrides")
		return
	}
	writeLibraryJSON(w, http.StatusOK, newAnalysisResponse(analysis))
}

func decodeAnalysisOverridesRequest(w http.ResponseWriter, r *http.Request) (AnalysisOverridesRequest, error) {
	var req AnalysisOverridesRequest
	r.Body = http.MaxBytesReader(w, r.Body, maxAnalysisOverridesRequestBytes)
	err := json.NewDecoder(r.Body).Decode(&req)
	return req, err
}

func normalizeAnalysisOverrides(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 {
		return nil, errors.New("overrides must be a JSON object")
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, errors.New("overrides must be a JSON object")
	}
	if obj == nil {
		return nil, errors.New("overrides must be a JSON object")
	}
	if err := normalizeManualBPMOverride(obj); err != nil {
		return nil, err
	}
	if err := normalizeManualBeatGridOverride(obj); err != nil {
		return nil, err
	}
	if err := normalizeManualDownbeatsOverride(obj); err != nil {
		return nil, err
	}
	normalized, err := json.Marshal(obj)
	if err != nil {
		return nil, errors.New("failed to normalize overrides")
	}
	return normalized, nil
}

func normalizeManualBPMOverride(overrides map[string]any) error {
	raw, present := overrides["bpm"]
	if !present {
		return nil
	}
	fields, ok := raw.(map[string]any)
	if !ok {
		if !isFiniteJSONNumber(raw) {
			return errors.New("bpm override value must be a finite number")
		}
		fields = map[string]any{"value": raw}
	} else if _, hasValue := fields["value"]; !hasValue {
		if legacyValue, hasLegacyValue := fields["nativeBpm"]; hasLegacyValue {
			fields["value"] = legacyValue
		}
	}
	delete(fields, "nativeBpm")

	value, hasValue := fields["value"]
	if !hasValue {
		clearManualTrust(fields)
		overrides["bpm"] = fields
		return nil
	}
	if !isFiniteJSONNumber(value) {
		return errors.New("bpm override value must be a finite number")
	}
	stampManualTrust(fields)
	overrides["bpm"] = fields
	return nil
}

func normalizeManualBeatGridOverride(overrides map[string]any) error {
	raw, present := overrides["beat_grid"]
	if !present {
		return nil
	}
	fields, ok := raw.(map[string]any)
	if !ok {
		return errors.New("beat_grid override must be a JSON object")
	}

	bpm, hasBPM := preferCanonicalOverrideField(fields, "bpm")
	if hasBPM && !isFiniteJSONNumber(bpm) {
		return errors.New("beat_grid bpm must be a finite number")
	}
	offset, hasOffset := preferCanonicalOverrideField(fields, "offset_ms", "offsetMs")
	if hasOffset && !isJSONInteger(offset) {
		return errors.New("beat_grid offset must be an integer")
	}
	beats, hasBeats := preferCanonicalOverrideField(fields, "beats_ms", "beatsMs")
	if hasBeats && !isJSONIntegerList(beats) {
		return errors.New("beat_grid beats must be an integer array")
	}

	// Compact beat-grid confidence is also the fallback BPM confidence. An
	// offset-only correction must therefore retain analyzer confidence instead
	// of marking inherited BPM/beat facts as manually trusted.
	if hasBPM || hasBeats {
		stampManualTrust(fields)
	} else {
		clearManualTrust(fields)
	}
	overrides["beat_grid"] = fields
	return nil
}

func normalizeManualDownbeatsOverride(overrides map[string]any) error {
	raw, present := overrides["downbeats"]
	if !present {
		return nil
	}
	fields, ok := raw.(map[string]any)
	if !ok {
		if !isJSONIntegerList(raw) {
			return errors.New("downbeats override must be an integer array or JSON object")
		}
		fields = map[string]any{"positions_ms": raw}
	} else {
		preferCanonicalOverrideField(fields, "positions_ms", "positionsMs")
	}

	positions, hasPositions := fields["positions_ms"]
	if !hasPositions {
		clearManualTrust(fields)
		overrides["downbeats"] = fields
		return nil
	}
	if !isJSONIntegerList(positions) {
		return errors.New("downbeats positions must be an integer array")
	}
	stampManualTrust(fields)
	overrides["downbeats"] = fields
	return nil
}

// preferCanonicalOverrideField returns the canonical value when both forms
// exist, otherwise moves the first accepted legacy alias into canonical form.
func preferCanonicalOverrideField(fields map[string]any, canonical string, aliases ...string) (any, bool) {
	value, present := fields[canonical]
	for _, alias := range aliases {
		legacyValue, hasLegacyValue := fields[alias]
		if !present && hasLegacyValue {
			value, present = legacyValue, true
			fields[canonical] = legacyValue
		}
		delete(fields, alias)
	}
	return value, present
}

func stampManualTrust(fields map[string]any) {
	fields["confidence"] = 1.0
	fields["provenance"] = manualAnalysisOverrideProvenance
}

func clearManualTrust(fields map[string]any) {
	delete(fields, "confidence")
	delete(fields, "provenance")
}

func isFiniteJSONNumber(value any) bool {
	number, ok := value.(float64)
	return ok && !math.IsNaN(number) && !math.IsInf(number, 0)
}

func isJSONInteger(value any) bool {
	number, ok := value.(float64)
	return ok && !math.IsNaN(number) && !math.IsInf(number, 0) && math.Trunc(number) == number
}

func isJSONIntegerList(value any) bool {
	values, ok := value.([]any)
	if !ok {
		return false
	}
	for _, item := range values {
		if !isJSONInteger(item) {
			return false
		}
	}
	return true
}
