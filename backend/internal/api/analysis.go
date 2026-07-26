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
	TrackID           int64           `json:"track_id"`
	SchemaVersion     int             `json:"schema_version"`
	Status            string          `json:"status"`
	Summary           json.RawMessage `json:"summary,omitempty"`
	Overrides         json.RawMessage `json:"overrides,omitempty"`
	Artifacts         json.RawMessage `json:"artifacts,omitempty"`
	Provenance        json.RawMessage `json:"provenance,omitempty"`
	Error             string          `json:"error,omitempty"`
	RequestedAt       string          `json:"requested_at"`
	StartedAt         string          `json:"started_at,omitempty"`
	CompletedAt       string          `json:"completed_at,omitempty"`
	UpdatedAt         string          `json:"updated_at"`
	OverrideRevision  int64           `json:"override_revision"`
	OverrideUpdatedAt string          `json:"override_updated_at,omitempty"`
}

type AnalysisOverridesRequest struct {
	Overrides        json.RawMessage `json:"overrides"`
	ExpectedRevision *int64          `json:"expected_revision,omitempty"`
}

const maxAnalysisOverridesRequestBytes = 1 << 20

const manualAnalysisOverrideProvenance = "manual_override"

func newAnalysisResponse(analysis *db.TrackAnalysis) AnalysisResponse {
	resp := AnalysisResponse{
		TrackID:          analysis.TrackID,
		SchemaVersion:    analysis.SchemaVersion,
		Status:           analysis.Status,
		Summary:          analysis.SummaryJSON,
		Overrides:        analysis.OverridesJSON,
		Artifacts:        analysis.ArtifactsJSON,
		Provenance:       analysis.ProvenanceJSON,
		RequestedAt:      analysis.RequestedAt.Format("2006-01-02T15:04:05Z"),
		UpdatedAt:        analysis.UpdatedAt.UTC().Format(time.RFC3339Nano),
		OverrideRevision: analysis.ManualOverrideRevision,
	}
	if analysis.ManualOverrideUpdatedAt.Valid {
		resp.OverrideUpdatedAt = analysis.ManualOverrideUpdatedAt.Time.UTC().Format(time.RFC3339Nano)
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
	expectedRevision := int64(0)
	if req.ExpectedRevision != nil {
		expectedRevision = *req.ExpectedRevision
	}
	if expectedRevision < 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "expected_revision must be zero or greater")
		return
	}
	analysis, err := h.analysisRepo.SetOverrides(r.Context(), trackID, normalized, expectedRevision)
	if errors.Is(err, db.ErrAnalysisOverrideConflict) {
		writeLibraryError(w, http.StatusConflict, "ANALYSIS_OVERRIDE_CONFLICT", "analysis overrides changed; refresh and retry")
		return
	}
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
	_, hasCanonicalTiming := obj["manual_timing_override"]
	if err := normalizeManualTimingOverride(obj); err != nil {
		return nil, err
	}
	if !hasCanonicalTiming {
		if err := normalizeManualBPMOverride(obj); err != nil {
			return nil, err
		}
		if err := normalizeManualBeatGridOverride(obj); err != nil {
			return nil, err
		}
		if err := normalizeManualDownbeatsOverride(obj); err != nil {
			return nil, err
		}
	}
	normalized, err := json.Marshal(obj)
	if err != nil {
		return nil, errors.New("failed to normalize overrides")
	}
	return normalized, nil
}

func normalizeManualTimingOverride(overrides map[string]any) error {
	raw, present := overrides["manual_timing_override"]
	if !present {
		return nil
	}
	fields, ok := raw.(map[string]any)
	if !ok {
		return errors.New("manual_timing_override must be a JSON object")
	}
	for key := range fields {
		switch key {
		case "bpm", "beat_anchor_ms", "beats_per_bar", "downbeat_phase_index", "phrase_length_bars",
			"confidence", "provenance", "revision", "updated_at":
		default:
			return errors.New("manual_timing_override contains an unknown field")
		}
	}

	if bpm, present := fields["bpm"]; present && (!isFiniteJSONNumber(bpm) || bpm.(float64) < 30 || bpm.(float64) > 300) {
		return errors.New("manual_timing_override bpm must be between 30 and 300")
	}
	anchor, hasAnchor := fields["beat_anchor_ms"]
	if hasAnchor && (!isJSONInteger(anchor) || anchor.(float64) < 0) {
		return errors.New("manual_timing_override beat_anchor_ms must be a non-negative integer")
	}
	meter, hasMeter := fields["beats_per_bar"]
	if hasMeter && (!isJSONInteger(meter) || meter.(float64) < 1 || meter.(float64) > 32) {
		return errors.New("manual_timing_override beats_per_bar must be between 1 and 32")
	}
	phase, hasPhase := fields["downbeat_phase_index"]
	if hasPhase && (!isJSONInteger(phase) || phase.(float64) < 0) {
		return errors.New("manual_timing_override downbeat_phase_index must be a non-negative integer")
	}
	if hasPhase && !hasMeter {
		return errors.New("manual_timing_override downbeat_phase_index requires beats_per_bar")
	}
	if hasMeter && hasPhase && phase.(float64) >= meter.(float64) {
		return errors.New("manual_timing_override downbeat_phase_index must be less than beats_per_bar")
	}
	phrase, hasPhrase := fields["phrase_length_bars"]
	if hasPhrase && (!isJSONInteger(phrase) || phrase.(float64) < 1 || phrase.(float64) > 128) {
		return errors.New("manual_timing_override phrase_length_bars must be between 1 and 128")
	}
	// Revision and timestamp are server-owned. Legacy timing fields remain as a
	// fallback for facts the canonical document does not replace.
	delete(fields, "revision")
	delete(fields, "updated_at")
	stampManualTrust(fields)
	overrides["manual_timing_override"] = fields
	return nil
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
