package db

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
)

const (
	maxCompactBeatPositions     = 8192
	maxCompactDownbeatPositions = 2048
	maxCompactLabelLength       = 128
	maxCompactProvenanceLength  = 256
	manualOverrideConfidence    = 1.0
	manualOverrideProvenance    = "manual_override"
)

type compactAnalysisDocument struct {
	BPM                  *compactNumberValue          `json:"bpm,omitempty"`
	BeatGrid             *compactBeatGrid             `json:"beat_grid,omitempty"`
	Downbeats            *compactDownbeats            `json:"downbeats,omitempty"`
	ManualTimingOverride *compactManualTimingOverride `json:"manual_timing_override,omitempty"`
	Key                  *compactStringValue          `json:"key,omitempty"`
	Camelot              *compactStringValue          `json:"camelot,omitempty"`
	Energy               *compactNumberValue          `json:"energy,omitempty"`
}

type compactNumberValue struct {
	Value      *float64 `json:"value,omitempty"`
	Confidence *float64 `json:"confidence,omitempty"`
	Provenance *string  `json:"provenance,omitempty"`
}

type compactStringValue struct {
	Value      *string  `json:"value,omitempty"`
	Confidence *float64 `json:"confidence,omitempty"`
	Provenance *string  `json:"provenance,omitempty"`
}

type compactBeatGrid struct {
	BPM        *float64 `json:"bpm,omitempty"`
	OffsetMS   *int64   `json:"offset_ms,omitempty"`
	BeatsMS    *[]int64 `json:"beats_ms,omitempty"`
	Confidence *float64 `json:"confidence,omitempty"`
	Provenance *string  `json:"provenance,omitempty"`
}

type compactDownbeats struct {
	PositionsMS *[]int64 `json:"positions_ms,omitempty"`
	Confidence  *float64 `json:"confidence,omitempty"`
	Provenance  *string  `json:"provenance,omitempty"`
}

// compactManualTimingOverride keeps the independent manual timing facts at
// every compact boundary. Beats themselves remain owned by the analysis grid.
type compactManualTimingOverride struct {
	BPM                *float64 `json:"bpm,omitempty"`
	BeatAnchorMS       *int64   `json:"beat_anchor_ms,omitempty"`
	BeatsPerBar        *int64   `json:"beats_per_bar,omitempty"`
	DownbeatPhaseIndex *int64   `json:"downbeat_phase_index,omitempty"`
	PhraseLengthBars   *int64   `json:"phrase_length_bars,omitempty"`
	Confidence         *float64 `json:"confidence,omitempty"`
	Provenance         *string  `json:"provenance,omitempty"`
	Revision           *int64   `json:"revision,omitempty"`
	UpdatedAt          *string  `json:"updated_at,omitempty"`
}

func projectCompactAnalysis(summaryJSON, overridesJSON json.RawMessage) (json.RawMessage, json.RawMessage) {
	base := decodeCompactAnalysis(summaryJSON)
	overrides := normalizeManualCompactTimingOverrides(decodeCompactAnalysis(overridesJSON))
	effective := mergeCompactAnalysis(base, overrides)
	applyCompactManualTimingOverride(&effective, overrides.ManualTimingOverride)
	compactOverrides := overrides
	applyCompactManualTimingOverride(&compactOverrides, overrides.ManualTimingOverride)
	return encodeCompactAnalysis(effective), encodeCompactAnalysis(compactOverrides)
}

// Legacy rows can predate explicit manual confidence/provenance fields. The
// compact projection is the shared list/queue boundary, so normalize there as
// well as at the write API before merging with analyzer facts.
func normalizeManualCompactTimingOverrides(overrides compactAnalysisDocument) compactAnalysisDocument {
	overrides.BPM = trustedManualCompactNumberValue(overrides.BPM)
	overrides.BeatGrid = trustedManualCompactBeatGrid(overrides.BeatGrid)
	overrides.Downbeats = trustedManualCompactDownbeats(overrides.Downbeats)
	overrides.ManualTimingOverride = trustedManualCompactTimingOverride(overrides.ManualTimingOverride)
	return overrides
}

func trustedManualCompactTimingOverride(value *compactManualTimingOverride) *compactManualTimingOverride {
	if value == nil {
		return nil
	}
	confidence := manualOverrideConfidence
	provenance := manualOverrideProvenance
	return &compactManualTimingOverride{
		BPM: value.BPM, BeatAnchorMS: value.BeatAnchorMS, BeatsPerBar: value.BeatsPerBar,
		DownbeatPhaseIndex: value.DownbeatPhaseIndex, PhraseLengthBars: value.PhraseLengthBars,
		Confidence: &confidence, Provenance: &provenance, Revision: value.Revision, UpdatedAt: value.UpdatedAt,
	}
}

func trustedManualCompactNumberValue(value *compactNumberValue) *compactNumberValue {
	if value == nil || value.Value == nil {
		return value
	}
	confidence := manualOverrideConfidence
	provenance := manualOverrideProvenance
	return &compactNumberValue{
		Value:      value.Value,
		Confidence: &confidence,
		Provenance: &provenance,
	}
}

func trustedManualCompactBeatGrid(value *compactBeatGrid) *compactBeatGrid {
	if value == nil || (value.BPM == nil && value.OffsetMS == nil && value.BeatsMS == nil) {
		return value
	}
	if value.BPM == nil && value.BeatsMS == nil {
		return &compactBeatGrid{
			OffsetMS: value.OffsetMS,
		}
	}
	confidence := manualOverrideConfidence
	provenance := manualOverrideProvenance
	return &compactBeatGrid{
		BPM:        value.BPM,
		OffsetMS:   value.OffsetMS,
		BeatsMS:    value.BeatsMS,
		Confidence: &confidence,
		Provenance: &provenance,
	}
}

func trustedManualCompactDownbeats(value *compactDownbeats) *compactDownbeats {
	if value == nil || value.PositionsMS == nil {
		return value
	}
	confidence := manualOverrideConfidence
	provenance := manualOverrideProvenance
	return &compactDownbeats{
		PositionsMS: value.PositionsMS,
		Confidence:  &confidence,
		Provenance:  &provenance,
	}
}

func decodeCompactAnalysis(payload json.RawMessage) compactAnalysisDocument {
	var fields map[string]json.RawMessage
	if len(payload) == 0 || json.Unmarshal(payload, &fields) != nil {
		return compactAnalysisDocument{}
	}
	return compactAnalysisDocument{
		BPM:                  decodeCompactNumberValue(fields["bpm"]),
		BeatGrid:             decodeCompactBeatGrid(fields["beat_grid"]),
		Downbeats:            decodeCompactDownbeats(fields["downbeats"]),
		ManualTimingOverride: decodeCompactManualTimingOverride(fields["manual_timing_override"]),
		Key:                  decodeCompactStringValue(fields["key"]),
		Camelot:              decodeCompactStringValue(fields["camelot"]),
		Energy:               decodeCompactNumberValue(fields["energy"]),
	}
}

func decodeCompactManualTimingOverride(raw json.RawMessage) *compactManualTimingOverride {
	fields := decodeCompactObject(raw)
	if len(fields) == 0 {
		return nil
	}
	timing := &compactManualTimingOverride{
		BPM: decodeFiniteFloat(fields["bpm"]), BeatAnchorMS: decodeInt64(fields["beat_anchor_ms"]),
		BeatsPerBar:        decodePositiveInt64(fields["beats_per_bar"]),
		DownbeatPhaseIndex: decodeNonNegativeInt64(fields["downbeat_phase_index"]),
		PhraseLengthBars:   decodePositiveInt64(fields["phrase_length_bars"]),
		Confidence:         decodeFiniteFloat(fields["confidence"]),
		Provenance:         decodeBoundedString(fields["provenance"], maxCompactProvenanceLength),
		Revision:           decodeNonNegativeInt64(fields["revision"]),
		UpdatedAt:          decodeBoundedString(fields["updated_at"], 64),
	}
	if timing.BPM == nil && timing.BeatAnchorMS == nil && timing.BeatsPerBar == nil && timing.DownbeatPhaseIndex == nil && timing.PhraseLengthBars == nil && timing.Revision == nil {
		return nil
	}
	if !validCompactManualTiming(timing) {
		return nil
	}
	return timing
}

func validCompactManualTiming(timing *compactManualTimingOverride) bool {
	if timing.BPM != nil && (*timing.BPM < 30 || *timing.BPM > 300) {
		return false
	}
	if timing.BeatAnchorMS != nil && *timing.BeatAnchorMS < 0 {
		return false
	}
	if timing.BeatsPerBar != nil && *timing.BeatsPerBar > 32 {
		return false
	}
	if timing.PhraseLengthBars != nil && *timing.PhraseLengthBars > 128 {
		return false
	}
	if timing.DownbeatPhaseIndex == nil {
		return true
	}
	return timing.BeatsPerBar != nil && *timing.DownbeatPhaseIndex < *timing.BeatsPerBar
}

func decodeCompactNumberValue(raw json.RawMessage) *compactNumberValue {
	if value := decodeFiniteFloat(raw); value != nil {
		return &compactNumberValue{Value: value}
	}
	fields := decodeCompactObject(raw)
	value := decodeFiniteFloat(firstCompactField(fields, "value", "nativeBpm"))
	if value == nil {
		return nil
	}
	return &compactNumberValue{
		Value:      value,
		Confidence: decodeFiniteFloat(fields["confidence"]),
		Provenance: decodeBoundedString(fields["provenance"], maxCompactProvenanceLength),
	}
}

func decodeCompactStringValue(raw json.RawMessage) *compactStringValue {
	if value := decodeBoundedString(raw, maxCompactLabelLength); value != nil {
		return &compactStringValue{Value: value}
	}
	fields := decodeCompactObject(raw)
	value := decodeBoundedString(fields["value"], maxCompactLabelLength)
	if value == nil {
		return nil
	}
	return &compactStringValue{
		Value:      value,
		Confidence: decodeFiniteFloat(fields["confidence"]),
		Provenance: decodeBoundedString(fields["provenance"], maxCompactProvenanceLength),
	}
}

func decodeCompactBeatGrid(raw json.RawMessage) *compactBeatGrid {
	fields := decodeCompactObject(raw)
	if len(fields) == 0 {
		return nil
	}
	grid := &compactBeatGrid{
		BPM:        decodeFiniteFloat(fields["bpm"]),
		OffsetMS:   decodeInt64(firstCompactField(fields, "offset_ms", "offsetMs")),
		BeatsMS:    decodeBoundedIntArray(firstCompactField(fields, "beats_ms", "beatsMs"), maxCompactBeatPositions),
		Confidence: decodeFiniteFloat(fields["confidence"]),
		Provenance: decodeBoundedString(fields["provenance"], maxCompactProvenanceLength),
	}
	if grid.BPM == nil && grid.OffsetMS == nil && grid.BeatsMS == nil && grid.Confidence == nil && grid.Provenance == nil {
		return nil
	}
	return grid
}

func decodeCompactDownbeats(raw json.RawMessage) *compactDownbeats {
	if positions := decodeBoundedIntArray(raw, maxCompactDownbeatPositions); positions != nil {
		return &compactDownbeats{PositionsMS: positions}
	}
	fields := decodeCompactObject(raw)
	if len(fields) == 0 {
		return nil
	}
	downbeats := &compactDownbeats{
		PositionsMS: decodeBoundedIntArray(firstCompactField(fields, "positions_ms", "positionsMs"), maxCompactDownbeatPositions),
		Confidence:  decodeFiniteFloat(fields["confidence"]),
		Provenance:  decodeBoundedString(fields["provenance"], maxCompactProvenanceLength),
	}
	if downbeats.PositionsMS == nil && downbeats.Confidence == nil && downbeats.Provenance == nil {
		return nil
	}
	return downbeats
}

func decodeCompactObject(raw json.RawMessage) map[string]json.RawMessage {
	var fields map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &fields) != nil {
		return nil
	}
	return fields
}

func firstCompactField(fields map[string]json.RawMessage, names ...string) json.RawMessage {
	for _, name := range names {
		if value, ok := fields[name]; ok {
			return value
		}
	}
	return nil
}

func decodeFiniteFloat(raw json.RawMessage) *float64 {
	if len(raw) == 0 {
		return nil
	}
	var value float64
	if json.Unmarshal(raw, &value) != nil || math.IsNaN(value) || math.IsInf(value, 0) {
		return nil
	}
	return &value
}

func decodeInt64(raw json.RawMessage) *int64 {
	if len(raw) == 0 {
		return nil
	}
	var value int64
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	return &value
}

func decodePositiveInt64(raw json.RawMessage) *int64 {
	value := decodeInt64(raw)
	if value == nil || *value <= 0 {
		return nil
	}
	return value
}

func decodeNonNegativeInt64(raw json.RawMessage) *int64 {
	value := decodeInt64(raw)
	if value == nil || *value < 0 {
		return nil
	}
	return value
}

func decodeBoundedString(raw json.RawMessage, maxLength int) *string {
	if len(raw) == 0 {
		return nil
	}
	var value string
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	value = strings.TrimSpace(value)
	if value == "" || len(value) > maxLength {
		return nil
	}
	return &value
}

func decodeBoundedIntArray(raw json.RawMessage, limit int) *[]int64 {
	if len(raw) == 0 {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('[') {
		return nil
	}
	values := make([]int64, 0, min(limit, 64))
	seen := 0
	valid := 0
	for decoder.More() {
		var item json.RawMessage
		if decoder.Decode(&item) != nil {
			return nil
		}
		seen++
		value := decodeInt64(item)
		if value == nil {
			continue
		}
		valid++
		if len(values) < limit {
			values = append(values, *value)
		}
	}
	if _, err := decoder.Token(); err != nil || (seen > 0 && valid == 0) {
		return nil
	}
	return &values
}

func mergeCompactAnalysis(base, overrides compactAnalysisDocument) compactAnalysisDocument {
	return compactAnalysisDocument{
		BPM:                  mergeCompactNumberValue(base.BPM, overrides.BPM),
		BeatGrid:             mergeCompactBeatGrid(base.BeatGrid, overrides.BeatGrid),
		Downbeats:            mergeCompactDownbeats(base.Downbeats, overrides.Downbeats),
		ManualTimingOverride: firstCompactManualTimingOverride(overrides.ManualTimingOverride, base.ManualTimingOverride),
		Key:                  mergeCompactStringValue(base.Key, overrides.Key),
		Camelot:              mergeCompactStringValue(base.Camelot, overrides.Camelot),
		Energy:               mergeCompactNumberValue(base.Energy, overrides.Energy),
	}
}

func firstCompactManualTimingOverride(values ...*compactManualTimingOverride) *compactManualTimingOverride {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

// applyCompactManualTimingOverride projects manual facts over the effective
// grid. BPM/anchor corrections deterministically rebuild the grid over the
// analyzer's existing span; phase-only corrections never touch beat timestamps.
func applyCompactManualTimingOverride(document *compactAnalysisDocument, timing *compactManualTimingOverride) {
	if document == nil || timing == nil {
		return
	}
	document.ManualTimingOverride = timing
	confidence := manualOverrideConfidence
	provenance := manualOverrideProvenance
	var baseBeats []int64
	if document.BeatGrid != nil && document.BeatGrid.BeatsMS != nil {
		baseBeats = *document.BeatGrid.BeatsMS
	}
	if timing.BPM != nil {
		document.BPM = &compactNumberValue{Value: timing.BPM, Confidence: &confidence, Provenance: &provenance}
		ensureCompactBeatGrid(document)
		document.BeatGrid.BPM = timing.BPM
		document.BeatGrid.Confidence = &confidence
		document.BeatGrid.Provenance = &provenance
	}
	if timing.BeatAnchorMS != nil {
		ensureCompactBeatGrid(document)
		document.BeatGrid.OffsetMS = timing.BeatAnchorMS
		document.BeatGrid.Confidence = &confidence
		document.BeatGrid.Provenance = &provenance
	}
	if (timing.BPM != nil || timing.BeatAnchorMS != nil) && len(baseBeats) > 0 {
		bpm := effectiveCompactBPM(document)
		anchor := effectiveCompactBeatAnchor(document)
		if bpm != nil && *bpm >= 30 && *bpm <= 300 && anchor != nil && *anchor >= 0 {
			derived := regenerateCompactBeatGrid(*bpm, *anchor, baseBeats)
			document.BeatGrid.BeatsMS = &derived
		}
	}
	if timing.BPM != nil || timing.BeatAnchorMS != nil || timing.BeatsPerBar != nil || timing.DownbeatPhaseIndex != nil {
		// Existing downbeats describe the old grid/meter. Do not carry that stale
		// projection forward unless both meter and phase can reselect it below.
		document.Downbeats = nil
	}
	if timing.BeatsPerBar == nil || timing.DownbeatPhaseIndex == nil || document.BeatGrid == nil || document.BeatGrid.BeatsMS == nil {
		return
	}
	beats := *document.BeatGrid.BeatsMS
	selected := make([]int64, 0, (len(beats)+int(*timing.BeatsPerBar)-1)/int(*timing.BeatsPerBar))
	for index, beat := range beats {
		if int64(index)%*timing.BeatsPerBar == *timing.DownbeatPhaseIndex {
			selected = append(selected, beat)
		}
	}
	document.Downbeats = &compactDownbeats{PositionsMS: &selected, Confidence: &confidence, Provenance: &provenance}
}

func ensureCompactBeatGrid(document *compactAnalysisDocument) {
	if document.BeatGrid == nil {
		document.BeatGrid = &compactBeatGrid{}
	}
}

func effectiveCompactBPM(document *compactAnalysisDocument) *float64 {
	if document.BeatGrid != nil && document.BeatGrid.BPM != nil {
		return document.BeatGrid.BPM
	}
	if document.BPM != nil {
		return document.BPM.Value
	}
	return nil
}

func effectiveCompactBeatAnchor(document *compactAnalysisDocument) *int64 {
	if document.BeatGrid == nil {
		return nil
	}
	if document.BeatGrid.OffsetMS != nil {
		return document.BeatGrid.OffsetMS
	}
	if document.BeatGrid.BeatsMS != nil && len(*document.BeatGrid.BeatsMS) > 0 {
		anchor := (*document.BeatGrid.BeatsMS)[0]
		return &anchor
	}
	return nil
}

func regenerateCompactBeatGrid(bpm float64, anchor int64, baseBeats []int64) []int64 {
	if bpm < 30 || bpm > 300 || anchor < 0 || len(baseBeats) == 0 {
		return baseBeats
	}
	maxBeat := int64(-1)
	for _, beat := range baseBeats {
		if beat > maxBeat {
			maxBeat = beat
		}
	}
	if maxBeat < 0 {
		return []int64{}
	}
	interval := 60000 / bpm
	startIndex := int64(math.Ceil(-float64(anchor) / interval))
	beats := make([]int64, 0, min(len(baseBeats), maxCompactBeatPositions))
	var previous int64 = -1
	for index := startIndex; len(beats) < maxCompactBeatPositions; index++ {
		beat := int64(math.Round(float64(anchor) + float64(index)*interval))
		if beat > maxBeat {
			break
		}
		if beat < 0 || beat == previous {
			continue
		}
		beats = append(beats, beat)
		previous = beat
	}
	return beats
}

func mergeCompactNumberValue(base, override *compactNumberValue) *compactNumberValue {
	if override == nil {
		return base
	}
	if base == nil {
		return override
	}
	return &compactNumberValue{
		Value:      firstFloat(override.Value, base.Value),
		Confidence: firstFloat(override.Confidence, base.Confidence),
		Provenance: firstString(override.Provenance, base.Provenance),
	}
}

func mergeCompactStringValue(base, override *compactStringValue) *compactStringValue {
	if override == nil {
		return base
	}
	if base == nil {
		return override
	}
	return &compactStringValue{
		Value:      firstString(override.Value, base.Value),
		Confidence: firstFloat(override.Confidence, base.Confidence),
		Provenance: firstString(override.Provenance, base.Provenance),
	}
}

func mergeCompactBeatGrid(base, override *compactBeatGrid) *compactBeatGrid {
	if override == nil {
		return base
	}
	if base == nil {
		return override
	}
	return &compactBeatGrid{
		BPM:        firstFloat(override.BPM, base.BPM),
		OffsetMS:   firstInt64(override.OffsetMS, base.OffsetMS),
		BeatsMS:    firstInt64Slice(override.BeatsMS, base.BeatsMS),
		Confidence: firstFloat(override.Confidence, base.Confidence),
		Provenance: firstString(override.Provenance, base.Provenance),
	}
}

func mergeCompactDownbeats(base, override *compactDownbeats) *compactDownbeats {
	if override == nil {
		return base
	}
	if base == nil {
		return override
	}
	return &compactDownbeats{
		PositionsMS: firstInt64Slice(override.PositionsMS, base.PositionsMS),
		Confidence:  firstFloat(override.Confidence, base.Confidence),
		Provenance:  firstString(override.Provenance, base.Provenance),
	}
}

func firstFloat(values ...*float64) *float64 {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func firstInt64(values ...*int64) *int64 {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func firstString(values ...*string) *string {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func firstInt64Slice(values ...*[]int64) *[]int64 {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func encodeCompactAnalysis(document compactAnalysisDocument) json.RawMessage {
	payload, err := json.Marshal(document)
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return payload
}
