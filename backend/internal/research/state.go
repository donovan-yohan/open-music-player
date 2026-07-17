package research

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

var (
	ErrInvalidTransition  = errors.New("invalid research job transition")
	ErrInvalidRevision    = errors.New("invalid research revision")
	ErrInvalidDegradation = errors.New("invalid research degradation")
	ErrInvalidReview      = errors.New("invalid research review")
)

func TransitionJob(from, to JobStatus) error {
	if from != to && jobTransitions[from][to] {
		return nil
	}
	return fmt.Errorf("%w: %s -> %s", ErrInvalidTransition, from, to)
}

func TransitionRun(from, to RunStatus) error {
	if from == RunRunning && to.Terminal() {
		return nil
	}
	return fmt.Errorf("%w: run %s -> %s", ErrInvalidTransition, from, to)
}

func ValidateRunStatus(status RunStatus) error {
	switch status {
	case RunRunning, RunCompleted, RunDegraded, RunCancelled, RunTimedOut, RunLeaseLost:
		return nil
	default:
		return fmt.Errorf("%w: unknown run status %q", ErrInvalidTransition, status)
	}
}

func ValidateCreate(input CreateInput) error {
	if input.OwnerID == "" || input.IdempotencyKey == "" || input.RequestHash == "" || input.Baseline.ID == "" || input.MaxAttempts < 1 {
		return fmt.Errorf("%w: required create fields missing", ErrInvalidRevision)
	}
	return nil
}

func ValidateEnhancement(input RevisionInput) error {
	if input.ID == "" {
		return fmt.Errorf("%w: revision id required", ErrInvalidRevision)
	}
	return nil
}

func ValidateDegradation(d Degradation) error {
	retryable, ok := degradationRetryable[d.Code]
	message, known := degradationMessages[d.Code]
	if !ok || !known || (retryable != d.Retryable && !(d.Code == DegradationLeaseExpired && !d.Retryable)) || (d.Message != "" && d.Message != message) {
		return fmt.Errorf("%w: %q", ErrInvalidDegradation, d.Code)
	}
	return nil
}

func PublicDegradation(code DegradationCode) Degradation {
	return Degradation{Code: code, Message: degradationMessages[code], Retryable: degradationRetryable[code]}
}

func effectiveDegradation(job Job, degradation Degradation) Degradation {
	if job.Attempts >= job.MaxAttempts {
		degradation.Retryable = false
	}
	return degradation
}

func CanonicalRequestHash(raw json.RawMessage) (json.RawMessage, string, error) {
	decoder := json.NewDecoder(bytesReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, "", ErrInvalidRevision
	}
	if _, ok := value.(map[string]any); !ok {
		return nil, "", ErrInvalidRevision
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, "", ErrInvalidRevision
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return nil, "", ErrInvalidRevision
	}
	digest := sha256.Sum256(canonical)
	return json.RawMessage(canonical), hex.EncodeToString(digest[:]), nil
}

func CanRetry(job Job, d *Degradation) bool {
	return job.Status == JobDegraded && job.RetrySafe && d != nil && d.Retryable && job.Attempts < job.MaxAttempts
}

func ValidateReview(input ReviewInput) error {
	if input.CandidateID == "" || input.IdempotencyKey == "" || len(input.Reason) > 512 || (input.Action != ReviewAccepted && input.Action != ReviewOverridden) {
		return ErrInvalidReview
	}
	return nil
}

func ValidateTerminalTelemetry(value TerminalTelemetry) error {
	if value.ToolCalls < 0 || len(value.ModelAttempts) > 24 {
		return ErrInvalidRevision
	}
	for _, timing := range []*int64{value.ProcessStartupToRequestAcceptedMs, value.RequestAcceptedToDirectFirstMs, value.RequestAcceptedToFinalMs} {
		if timing != nil && *timing < 0 {
			return ErrInvalidRevision
		}
	}
	for _, attempt := range value.ModelAttempts {
		if (attempt.Stage != StageDirectJudge && attempt.Stage != StageDeepAgent) || attempt.Attempt < 1 || attempt.DurationMs < 0 || (attempt.Status != "success" && attempt.Status != "parse_error" && attempt.Status != "transport_error") {
			return ErrInvalidRevision
		}
	}
	return nil
}

var jobTransitions = map[JobStatus]map[JobStatus]bool{
	JobQueued:          {JobRunning: true, JobCancelled: true},
	JobRunning:         {JobCancelRequested: true, JobCompleted: true, JobDegraded: true},
	JobCancelRequested: {JobCancelled: true},
	JobDegraded:        {JobQueued: true},
}

var degradationRetryable = map[DegradationCode]bool{
	DegradationModelDisabled: false, DegradationModelUnavailable: true, DegradationBudgetExhausted: false,
	DegradationTransient: true, DegradationTimeout: true, DegradationRunnerTerminal: false,
	DegradationValidationRejected: false, DegradationSafetyRejected: false, DegradationEnhancementRejected: false,
	DegradationLeaseExpired: true, DegradationNoCandidates: false,
}

var degradationMessages = map[DegradationCode]string{
	DegradationModelDisabled:       "Research enhancements are disabled.",
	DegradationModelUnavailable:    "Research enhancements are temporarily unavailable.",
	DegradationBudgetExhausted:     "Research enhancement budget is exhausted.",
	DegradationTransient:           "Research enhancements are temporarily unavailable.",
	DegradationTimeout:             "Research enhancement timed out.",
	DegradationRunnerTerminal:      "Research enhancement ended unexpectedly.",
	DegradationValidationRejected:  "Research enhancement response was rejected.",
	DegradationSafetyRejected:      "Research enhancement response was rejected for safety.",
	DegradationEnhancementRejected: "Research enhancement response was rejected.",
	DegradationLeaseExpired:        "Research worker lease expired.",
	DegradationNoCandidates:        "No matching candidates were found.",
}

// bytesReader exists to keep canonicalization focused and testable without
// exposing a parser abstraction at the service boundary.
func bytesReader(raw []byte) *bytes.Reader { return bytes.NewReader(raw) }
