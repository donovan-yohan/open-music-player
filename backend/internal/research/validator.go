package research

import (
	"context"
	"errors"
	"reflect"

	"github.com/openmusicplayer/backend/internal/discovery"
)

// PayloadValidator is the repository boundary. It accepts only Go-owned
// payloads and grounds every enhancement in the persisted deterministic base.
type PayloadValidator struct{}

func NewPayloadValidator() PayloadValidator { return PayloadValidator{} }

func (PayloadValidator) ValidateBaseline(_ context.Context, input RevisionInput) error {
	payload, err := ParseRevisionPayload(input.Payload)
	if err != nil || input.ID == "" || payload.Stage != StageBaseline {
		return payloadError("baseline")
	}
	for _, candidate := range payload.Candidates {
		quality := discovery.EvaluateSourceQuality(payload.Query, discovery.Candidate{CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID, SourceURL: candidate.SourceURL, Title: candidate.Title, Artist: candidate.Artist, Uploader: candidate.Uploader, DurationMs: candidate.DurationMs, Downloadable: candidate.Downloadable, Playable: candidate.Playable, Explicit: candidate.Explicit})
		if candidate.SourceQuality.Score != quality.Score || candidate.SourceQuality.Classification != quality.Classification || candidate.SourceQuality.Recommendation != quality.Recommendation || candidate.SourceQuality.Confidence != quality.Confidence || !reflect.DeepEqual(candidate.SourceQuality.Warnings, quality.Warnings) {
			return payloadError("baseline quality")
		}
	}
	return nil
}

func (PayloadValidator) ValidateEnhancement(_ context.Context, snapshot Snapshot, input RevisionInput) error {
	enhancement, err := ParseRevisionPayload(input.Payload)
	if err != nil || input.ID == "" || (enhancement.Stage != StageDirectJudge && enhancement.Stage != StageDeepAgent) {
		return payloadError("enhancement")
	}
	var baseline RevisionPayload
	found := false
	for _, revision := range snapshot.Revisions {
		candidate, parseErr := ParseRevisionPayload(revision.Payload)
		if parseErr == nil && candidate.Stage == StageBaseline {
			baseline, found = candidate, true
			break
		}
	}
	if !found || enhancement.Query != baseline.Query || len(enhancement.Candidates) != len(baseline.Candidates) {
		return payloadError("enhancement grounding")
	}
	for index := range baseline.Candidates {
		if !reflect.DeepEqual(enhancement.Candidates[index], baseline.Candidates[index]) {
			return payloadError("enhancement candidate")
		}
	}
	for _, recommendation := range enhancement.Recommendations {
		if !safeText(recommendation.Rationale, 240) {
			return errors.New("research unsafe model rationale")
		}
	}
	if !safeText(enhancement.Provenance.Source, 128) || !safeText(enhancement.Provenance.WorkerSchemaVersion, 128) {
		return errors.New("research unsafe model provenance")
	}
	return nil
}
