package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strings"

	"github.com/openmusicplayer/backend/internal/stems"
)

const (
	mixStemMaxEventsPerClip = 2048
	mixStemMaxEventsPerPlan = 4096
	// Keep authoritative integer milliseconds exact in the Flutter web client.
	mixStemMaxSafeInteger int64 = 9007199254740991
)

// MixPlanStemEdits is the client StemEdits v1 change-point document. Times are
// source-file milliseconds, never clip-local or timeline-relative. This is
// persistence only; accepting an edit does not imply it is audibly applied.
type MixPlanStemEdits struct {
	SchemaVersion    int                     `json:"schemaVersion"`
	ChannelSet       string                  `json:"channelSet"`
	StemModelVersion string                  `json:"stemModelVersion"`
	SourceFileHash   string                  `json:"sourceFileHash"`
	BeatGridRef      *MixPlanStemBeatGridRef `json:"beatGridRef,omitempty"`
	Events           []MixPlanStemGainEvent  `json:"events"`
}

type MixPlanStemBeatGridRef struct {
	AnalysisRef     string `json:"analysisRef"`
	AnalysisVersion string `json:"analysisVersion"`
}

type MixPlanStemGainEvent struct {
	Channel   string  `json:"channel"`
	AtMs      int64   `json:"atMs"`
	Gain      float64 `json:"gain"`
	RampMs    int64   `json:"rampMs"`
	BeatIndex *int64  `json:"beatIndex,omitempty"`
}

// Unknown fields are rejected, not silently dropped. Unlike the client's
// forward-compatible decoder this server only accepts the known v1 boundary.
// Null, duplicate object keys and omitted required fields are not defaults.
func decodeMixStemObject(data []byte, target any, required ...string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return fmt.Errorf("stemEdits must contain an object")
	}
	seen := make(map[string]bool)
	allowed := make(map[string]bool)
	wireType := reflect.TypeOf(target).Elem()
	for i := 0; i < wireType.NumField(); i++ {
		allowed[strings.Split(wireType.Field(i).Tag.Get("json"), ",")[0]] = true
	}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return fmt.Errorf("stemEdits: %w", err)
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return fmt.Errorf("stemEdits duplicate field %q", key)
		}
		if !allowed[key] {
			return fmt.Errorf("stemEdits unknown field %q", key)
		}
		seen[key] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return fmt.Errorf("stemEdits.%s: %w", key, err)
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("stemEdits.%s must not be null", key)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return fmt.Errorf("stemEdits: %w", err)
	}
	for _, key := range required {
		if !seen[key] {
			return fmt.Errorf("stemEdits.%s is required", key)
		}
	}
	decoder = json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("stemEdits: %w", err)
	}
	return nil
}

func (edits *MixPlanStemEdits) UnmarshalJSON(data []byte) error {
	type wire MixPlanStemEdits
	var value wire
	if err := decodeMixStemObject(data, &value, "schemaVersion", "channelSet", "stemModelVersion", "sourceFileHash", "events"); err != nil {
		return err
	}
	*edits = MixPlanStemEdits(value)
	return nil
}

func (event *MixPlanStemGainEvent) UnmarshalJSON(data []byte) error {
	type wire MixPlanStemGainEvent
	var value wire
	if err := decodeMixStemObject(data, &value, "channel", "atMs", "gain", "rampMs"); err != nil {
		return err
	}
	*event = MixPlanStemGainEvent(value)
	return nil
}

func (grid *MixPlanStemBeatGridRef) UnmarshalJSON(data []byte) error {
	type wire MixPlanStemBeatGridRef
	var value wire
	if err := decodeMixStemObject(data, &value, "analysisRef", "analysisVersion"); err != nil {
		return err
	}
	*grid = MixPlanStemBeatGridRef(value)
	return nil
}

func (clip *MixPlanClip) UnmarshalJSON(data []byte) error {
	// A nil pointer alone cannot distinguish omitted stemEdits from explicit
	// null. Only omission means no document; never acknowledge and erase null.
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if raw, ok := fields["stemEdits"]; ok && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return fmt.Errorf("stemEdits must be an object, not null")
	}
	type wire MixPlanClip
	var value wire
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	*clip = MixPlanClip(value)
	return nil
}

func validateMixStemEdits(edits *MixPlanStemEdits) error {
	if edits.SchemaVersion != 1 {
		return fmt.Errorf("stemEdits.schemaVersion must be 1")
	}
	channels, ok := stems.Channels(edits.ChannelSet)
	if !ok {
		return fmt.Errorf("stemEdits.channelSet is unsupported")
	}
	model, _ := stems.StemModelVersionFor(edits.ChannelSet)
	if edits.StemModelVersion != model {
		return fmt.Errorf("stemEdits.stemModelVersion must match the canonical channel-set model")
	}
	if !stems.ValidSourceHash(edits.SourceFileHash) {
		return fmt.Errorf("stemEdits.sourceFileHash must be sha256: followed by 64 lowercase hex characters")
	}
	if edits.Events == nil {
		return fmt.Errorf("stemEdits.events is required")
	}
	if len(edits.Events) > mixStemMaxEventsPerClip {
		return fmt.Errorf("stemEdits.events must contain at most %d events per clip", mixStemMaxEventsPerClip)
	}
	if grid := edits.BeatGridRef; grid != nil {
		if strings.TrimSpace(grid.AnalysisRef) == "" || strings.TrimSpace(grid.AnalysisVersion) == "" {
			return fmt.Errorf("stemEdits.beatGridRef requires nonblank analysisRef and analysisVersion")
		}
	}
	for i, event := range edits.Events {
		known := false
		for _, channel := range channels {
			if event.Channel == channel {
				known = true
				break
			}
		}
		if !known {
			return fmt.Errorf("stemEdits.events[%d].channel does not belong to channelSet", i)
		}
		if event.AtMs < 0 || event.AtMs > mixStemMaxSafeInteger {
			return fmt.Errorf("stemEdits.events[%d].atMs must be a non-negative safe integer", i)
		}
		if math.IsNaN(event.Gain) || math.IsInf(event.Gain, 0) || event.Gain < 0 || event.Gain > 1 {
			return fmt.Errorf("stemEdits.events[%d].gain must be finite in [0,1]", i)
		}
		if event.RampMs < 1 || event.RampMs > 250 {
			return fmt.Errorf("stemEdits.events[%d].rampMs must be in [1,250]", i)
		}
		if event.BeatIndex != nil && (*event.BeatIndex < 0 || *event.BeatIndex > mixStemMaxSafeInteger) {
			return fmt.Errorf("stemEdits.events[%d].beatIndex must be a non-negative safe integer", i)
		}
		// Client toJson emits strictly increasing (atMs, channel) after its
		// last-write-wins canonicalization. Reject duplicates/unsorted input
		// rather than silently discarding or rewriting accepted authoring data.
		if i > 0 {
			previous := edits.Events[i-1]
			if event.AtMs < previous.AtMs || (event.AtMs == previous.AtMs && event.Channel <= previous.Channel) {
				return fmt.Errorf("stemEdits.events must be canonical (atMs, channel) order with unique change points")
			}
		}
	}
	return nil
}
