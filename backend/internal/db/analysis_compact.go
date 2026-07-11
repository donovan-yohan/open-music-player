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
	BPM       *compactNumberValue `json:"bpm,omitempty"`
	BeatGrid  *compactBeatGrid    `json:"beat_grid,omitempty"`
	Downbeats *compactDownbeats   `json:"downbeats,omitempty"`
	Key       *compactStringValue `json:"key,omitempty"`
	Camelot   *compactStringValue `json:"camelot,omitempty"`
	Energy    *compactNumberValue `json:"energy,omitempty"`
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

func projectCompactAnalysis(summaryJSON, overridesJSON json.RawMessage) (json.RawMessage, json.RawMessage) {
	base := decodeCompactAnalysis(summaryJSON)
	overrides := normalizeManualCompactTimingOverrides(decodeCompactAnalysis(overridesJSON))
	return encodeCompactAnalysis(mergeCompactAnalysis(base, overrides)), encodeCompactAnalysis(overrides)
}

// Legacy rows can predate explicit manual confidence/provenance fields. The
// compact projection is the shared list/queue boundary, so normalize there as
// well as at the write API before merging with analyzer facts.
func normalizeManualCompactTimingOverrides(overrides compactAnalysisDocument) compactAnalysisDocument {
	overrides.BPM = trustedManualCompactNumberValue(overrides.BPM)
	overrides.BeatGrid = trustedManualCompactBeatGrid(overrides.BeatGrid)
	overrides.Downbeats = trustedManualCompactDownbeats(overrides.Downbeats)
	return overrides
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
		BPM:       decodeCompactNumberValue(fields["bpm"]),
		BeatGrid:  decodeCompactBeatGrid(fields["beat_grid"]),
		Downbeats: decodeCompactDownbeats(fields["downbeats"]),
		Key:       decodeCompactStringValue(fields["key"]),
		Camelot:   decodeCompactStringValue(fields["camelot"]),
		Energy:    decodeCompactNumberValue(fields["energy"]),
	}
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
		BPM:       mergeCompactNumberValue(base.BPM, overrides.BPM),
		BeatGrid:  mergeCompactBeatGrid(base.BeatGrid, overrides.BeatGrid),
		Downbeats: mergeCompactDownbeats(base.Downbeats, overrides.Downbeats),
		Key:       mergeCompactStringValue(base.Key, overrides.Key),
		Camelot:   mergeCompactStringValue(base.Camelot, overrides.Camelot),
		Energy:    mergeCompactNumberValue(base.Energy, overrides.Energy),
	}
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
