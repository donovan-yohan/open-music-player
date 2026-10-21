package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/stems"
)

// A portable performance is metadata, not a capability to stream source audio.
// No server IDs, object paths or credentials are part of this whitelist.
type MixExchangeDocument struct {
	Format  string            `json:"format"`
	Version int               `json:"version"`
	Name    string            `json:"name"`
	Clips   []MixExchangeClip `json:"clips"`
}

type MixExchangeClip struct {
	ClipID          string            `json:"clipId"`
	QueueItemID     string            `json:"queueItemId"`
	SourceFileHash  string            `json:"sourceFileHash"`
	SourceStartMs   int64             `json:"sourceStartMs"`
	SourceEndMs     int64             `json:"sourceEndMs"`
	TimelineStartMs int64             `json:"timelineStartMs"`
	GainDB          float64           `json:"gainDb"`
	FadeInMs        *int64            `json:"fadeInMs,omitempty"`
	FadeOutMs       *int64            `json:"fadeOutMs,omitempty"`
	PitchMode       string            `json:"pitchMode"`
	TempoPolicy     MixTempoPolicy    `json:"tempoPolicy"`
	StemEdits       *MixPlanStemEdits `json:"stemEdits,omitempty"`
}

type MixExchangePlanStore interface {
	GetByIDForUser(context.Context, uuid.UUID, uuid.UUID) (*db.MixPlan, error)
}

// Import always uses the atomic verification/create port. A plain plan Create
// is deliberately not available here, even when a source store is a test fake.
type MixExchangeSourceStore interface {
	CreateVerified(context.Context, *db.MixPlan, []db.MixExchangeSourceExpectation) error
	FindSourcesByTrackIDs(context.Context, uuid.UUID, []int64) ([]db.MixExchangeSource, error)
	FindSourcesByHashes(context.Context, uuid.UUID, []string) ([]db.MixExchangeSource, error)
}

type MixExchangeHandlers struct {
	plans   MixExchangePlanStore
	sources MixExchangeSourceStore
}

func NewMixExchangeHandlers(plans MixExchangePlanStore, sources MixExchangeSourceStore) *MixExchangeHandlers {
	return &MixExchangeHandlers{plans: plans, sources: sources}
}

// Go's ordinary decoder accepts duplicate keys, case aliases, missing scalar
// values and null-as-zero. At this authoring boundary none are safe defaults.
// Nested stem objects use the same strict stem decoder as ordinary mix saves.
func decodeMixExchangeObject(data []byte, target any, required ...string) error {
	if !utf8.Valid(data) {
		return errors.New("metadata must be valid UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return errors.New("metadata must contain an object")
	}
	allowed := make(map[string]bool)
	typ := reflect.TypeOf(target).Elem()
	for i := 0; i < typ.NumField(); i++ {
		allowed[strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]] = true
	}
	seen := make(map[string]bool)
	for decoder.More() {
		token, err = decoder.Token()
		if err != nil {
			return err
		}
		key, ok := token.(string)
		if !ok || !allowed[key] || seen[key] {
			return errors.New("metadata contains an unknown, noncanonical or duplicate field")
		}
		seen[key] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("%s must not be null", key)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	if err := decoder.Decode(new(json.RawMessage)); !errors.Is(err, io.EOF) {
		return errors.New("metadata must contain a single JSON value")
	}
	for _, key := range required {
		if !seen[key] {
			return fmt.Errorf("%s is required", key)
		}
	}
	decoder = json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func (document *MixExchangeDocument) UnmarshalJSON(data []byte) error {
	type wire MixExchangeDocument
	var value wire
	if err := decodeMixExchangeObject(data, &value, "format", "version", "name", "clips"); err != nil {
		return err
	}
	*document = MixExchangeDocument(value)
	return nil
}

func (clip *MixExchangeClip) UnmarshalJSON(data []byte) error {
	type wire MixExchangeClip
	var value wire
	if err := decodeMixExchangeObject(data, &value, "clipId", "queueItemId", "sourceFileHash", "sourceStartMs", "sourceEndMs", "timelineStartMs", "gainDb", "pitchMode", "tempoPolicy"); err != nil {
		return err
	}
	*clip = MixExchangeClip(value)
	return nil
}

func exchangeClipFromPlan(clip MixPlanClip, hash string) MixExchangeClip {
	return MixExchangeClip{ClipID: clip.ClipID, QueueItemID: clip.QueueItemID, SourceFileHash: hash, SourceStartMs: clip.SourceStartMs, SourceEndMs: clip.SourceEndMs, TimelineStartMs: clip.TimelineStartMs, GainDB: clip.GainDB, FadeInMs: clip.FadeInMs, FadeOutMs: clip.FadeOutMs, PitchMode: clip.PitchMode, TempoPolicy: clip.TempoPolicy, StemEdits: clip.StemEdits}
}

func (clip MixExchangeClip) planClip(trackID int64) MixPlanClip {
	return MixPlanClip{ClipID: clip.ClipID, QueueItemID: clip.QueueItemID, TrackID: trackID, SourceStartMs: clip.SourceStartMs, SourceEndMs: clip.SourceEndMs, TimelineStartMs: clip.TimelineStartMs, GainDB: clip.GainDB, FadeInMs: clip.FadeInMs, FadeOutMs: clip.FadeOutMs, PitchMode: clip.PitchMode, TempoPolicy: clip.TempoPolicy, StemEdits: clip.StemEdits}
}

func validateMixExchangeClip(clip MixExchangeClip) error {
	if clip.ClipID != strings.TrimSpace(clip.ClipID) || clip.QueueItemID != strings.TrimSpace(clip.QueueItemID) {
		return errors.New("clip and queue IDs must not contain surrounding whitespace")
	}
	if !stems.ValidSourceHash(clip.SourceFileHash) {
		return errors.New("sourceFileHash must be a canonical sha256 hash")
	}
	if clip.StemEdits != nil && clip.StemEdits.SourceFileHash != clip.SourceFileHash {
		return errors.New("stemEdits sourceFileHash does not match the canonical source")
	}
	if clip.PitchMode != "preserve" && clip.PitchMode != "followTempo" {
		return errors.New("pitchMode is unsupported")
	}
	return nil
}

// Guard already-saved fields before projecting onto the portable whitelist.
// Unknown extensions must cause refusal, never an apparently lossless export.
func decodeMixExchangeSavedPayload(data []byte) (*SaveMixPlanRequest, error) {
	if len(data) > mixPlanMaxRequestBodyBytes {
		return nil, errors.New("saved metadata exceeds exchange size limit")
	}
	var document struct {
		SchemaVersion int               `json:"schemaVersion"`
		Name          string            `json:"name"`
		Clips         []json.RawMessage `json:"clips"`
	}
	if err := decodeMixExchangeObject(data, &document, "schemaVersion", "name", "clips"); err != nil {
		return nil, err
	}
	clips := make([]MixPlanClip, 0, len(document.Clips))
	for _, raw := range document.Clips {
		type wire MixPlanClip
		var clip wire
		if err := decodeMixExchangeObject(raw, &clip, "clipId", "queueItemId", "trackId", "sourceStartMs", "sourceEndMs", "timelineStartMs", "gainDb"); err != nil {
			return nil, err
		}
		if clip.PitchMode != "" && clip.PitchMode != "preserve" && clip.PitchMode != "followTempo" {
			return nil, errors.New("saved pitchMode is unsupported")
		}
		if clip.ClipID != strings.TrimSpace(clip.ClipID) || clip.QueueItemID != strings.TrimSpace(clip.QueueItemID) {
			return nil, errors.New("saved instance IDs are noncanonical")
		}
		clips = append(clips, MixPlanClip(clip))
	}
	return &SaveMixPlanRequest{SchemaVersion: document.SchemaVersion, Name: document.Name, Clips: clips}, nil
}

func validateMixExchangeDuration(clip MixPlanClip, source db.MixExchangeSource) error {
	if source.DurationMs.Valid && source.DurationMs.Int64 > 0 && clip.SourceEndMs > source.DurationMs.Int64 {
		return errors.New("sourceEndMs exceeds the known source duration")
	}
	return nil
}

func (h *MixExchangeHandlers) ExportMixPlan(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeMixPlanError(w, 401, "UNAUTHORIZED", "not authenticated")
		return
	}
	id, err := parseMixPlanID(r)
	if err != nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "invalid mix plan ID")
		return
	}
	plan, err := h.plans.GetByIDForUser(r.Context(), user.UserID, id)
	if err != nil {
		if errors.Is(err, db.ErrMixPlanNotFound) {
			writeMixPlanError(w, 404, "NOT_FOUND", "mix plan not found")
		} else {
			writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to read mix plan")
		}
		return
	}
	req, err := decodeMixExchangeSavedPayload(plan.Payload)
	if err != nil {
		writeMixPlanError(w, 422, "UNSUPPORTED_METADATA", "saved mix metadata cannot be exported losslessly")
		return
	}
	payload, _, ids, err := buildMixPlanPayload(req)
	if err != nil {
		writeMixPlanError(w, 422, "UNSUPPORTED_METADATA", "saved mix metadata is invalid")
		return
	}
	sources, err := h.sources.FindSourcesByTrackIDs(r.Context(), user.UserID, ids)
	if err != nil {
		writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to resolve owned sources")
		return
	}
	byID := make(map[int64]db.MixExchangeSource, len(sources))
	for _, source := range sources {
		byID[source.TrackID] = source
	}
	document := MixExchangeDocument{Format: "soundq-mix", Version: 1, Name: payload.Name, Clips: make([]MixExchangeClip, 0, len(payload.Clips))}
	queues := make(map[string]bool)
	for _, clip := range payload.Clips {
		source, ok := byID[clip.TrackID]
		portable := exchangeClipFromPlan(clip, source.SourceFileHash)
		if !ok || validateMixExchangeClip(portable) != nil || validateMixExchangeDuration(clip, source) != nil || queues[clip.QueueItemID] {
			writeMixPlanError(w, 422, "UNSUPPORTED_METADATA", "mix requires unique instances and known matching owned source identities and durations")
			return
		}
		queues[clip.QueueItemID] = true
		document.Clips = append(document.Clips, portable)
	}
	encoded, err := json.Marshal(document)
	if err != nil || len(encoded) > mixPlanMaxRequestBodyBytes {
		writeMixPlanError(w, 422, "UNSUPPORTED_METADATA", "portable metadata exceeds exchange size limit")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", `attachment; filename="soundq-mix.json"`)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(200)
	_, _ = w.Write(encoded)
}

func (h *MixExchangeHandlers) ImportMixPlan(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writeMixPlanError(w, 401, "UNAUTHORIZED", "not authenticated")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, mixPlanMaxRequestBodyBytes))
	if err != nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "invalid or oversized metadata body")
		return
	}
	var document MixExchangeDocument
	if !utf8.Valid(body) {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "metadata must be valid UTF-8")
		return
	}
	if err := json.Unmarshal(body, &document); err != nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "invalid mix exchange metadata: "+err.Error())
		return
	}
	if document.Format != "soundq-mix" || document.Version != 1 {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "format must be soundq-mix version 1")
		return
	}
	req := &SaveMixPlanRequest{SchemaVersion: 1, Name: document.Name, Clips: make([]MixPlanClip, 0, len(document.Clips))}
	if document.Clips == nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "clips is required")
		return
	}
	hashes := make([]string, 0, len(document.Clips))
	seen := make(map[string]bool)
	queues := make(map[string]bool)
	for _, clip := range document.Clips {
		if err := validateMixExchangeClip(clip); err != nil {
			writeMixPlanError(w, 400, "VALIDATION_ERROR", err.Error())
			return
		}
		if queues[clip.QueueItemID] {
			writeMixPlanError(w, 400, "VALIDATION_ERROR", "queueItemId must be unique")
			return
		}
		queues[clip.QueueItemID] = true
		req.Clips = append(req.Clips, clip.planClip(1)) // geometry admission before any repository work
		if !seen[clip.SourceFileHash] {
			hashes = append(hashes, clip.SourceFileHash)
			seen[clip.SourceFileHash] = true
		}
	}
	if _, _, _, err := buildMixPlanPayload(req); err != nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", err.Error())
		return
	}
	sources, err := h.sources.FindSourcesByHashes(r.Context(), user.UserID, hashes)
	if err != nil {
		writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to resolve owned sources")
		return
	}
	byHash := make(map[string][]db.MixExchangeSource)
	for _, source := range sources {
		byHash[source.SourceFileHash] = append(byHash[source.SourceFileHash], source)
	}
	missing := make([]string, 0)
	ambiguous := false
	for _, hash := range hashes {
		if len(byHash[hash]) == 0 {
			missing = append(missing, hash)
		}
		if len(byHash[hash]) > 1 {
			ambiguous = true
		}
	}
	if len(missing) > 0 {
		// Echo only supplied hashes, never global catalog information. At most 1000.
		writeMixPlanJSON(w, 422, struct {
			Code                string   `json:"code"`
			Message             string   `json:"message"`
			MissingSourceHashes []string `json:"missingSourceHashes"`
		}{"MISSING_SOURCES", "recipient library is missing required audio sources", missing})
		return
	}
	if ambiguous {
		writeMixPlanError(w, 422, "AMBIGUOUS_SOURCE", "multiple recipient-library tracks match a required source hash")
		return
	}
	expected := make([]db.MixExchangeSourceExpectation, 0, len(document.Clips))
	for i, clip := range document.Clips {
		source := byHash[clip.SourceFileHash][0]
		if source.TrackID <= 0 || source.SourceFileHash != clip.SourceFileHash || validateMixExchangeDuration(req.Clips[i], source) != nil {
			writeMixPlanError(w, 422, "SOURCE_MISMATCH", "source does not match the authored window")
			return
		}
		req.Clips[i].TrackID = source.TrackID
		expected = append(expected, db.MixExchangeSourceExpectation{TrackID: source.TrackID, SourceFileHash: clip.SourceFileHash, SourceEndMs: clip.SourceEndMs})
	}
	payload, summary, _, err := buildMixPlanPayload(req)
	if err != nil {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", err.Error())
		return
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil || len(payloadJSON) > mixPlanMaxRequestBodyBytes {
		writeMixPlanError(w, 400, "VALIDATION_ERROR", "resolved metadata exceeds mix plan size limit")
		return
	}
	summaryJSON, err := json.Marshal(summary)
	if err != nil {
		writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	plan := &db.MixPlan{UserID: user.UserID, SchemaVersion: 1, Name: payload.Name, Payload: payloadJSON, Summary: summaryJSON}
	if err := h.sources.CreateVerified(r.Context(), plan, expected); err != nil {
		if errors.Is(err, db.ErrMixExchangeSourceMismatch) {
			writeMixPlanError(w, 422, "SOURCE_MISMATCH", "source does not match the authored window")
		} else {
			writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to create mix plan")
		}
		return
	}
	response, err := mixPlanResponseFromDB(plan)
	if err != nil {
		writeMixPlanError(w, 500, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	writeMixPlanJSON(w, 201, response)
}
