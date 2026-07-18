package research

import (
	"context"
	"errors"
	"reflect"
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
