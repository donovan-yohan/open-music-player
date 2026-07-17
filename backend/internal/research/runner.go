package research

import (
	"context"
	"errors"
	"fmt"
)

// Runner receives a persisted baseline and can emit enhancements only.
type Runner interface {
	Run(context.Context, RunRequest, EnhancementSink) error
}
type RunRequest struct {
	Snapshot Snapshot
	Run      Run
}
type EnhancementSink interface {
	Append(context.Context, RevisionInput) error
	Terminal(context.Context, TerminalTelemetry) error
	Degrade(context.Context, Degradation) error
}
type RunnerError struct {
	Kind        FailureKind
	Err         error
	Degradation *Degradation
}

func (e *RunnerError) Error() string {
	if e.Err == nil {
		return string(e.Kind)
	}
	return fmt.Sprintf("%s: %v", e.Kind, e.Err)
}
func (e *RunnerError) Unwrap() error { return e.Err }
func Transient(e error) error        { return &RunnerError{Kind: FailureTransient, Err: e} }
func Terminal(e error) error         { return &RunnerError{Kind: FailureTerminal, Err: e} }
func Safety(e error) error           { return &RunnerError{Kind: FailureSafety, Err: e} }
func Validation(e error) error       { return &RunnerError{Kind: FailureValidation, Err: e} }
func TypedDegradation(d Degradation) error {
	return &RunnerError{Kind: failureKindFor(d), Err: errors.New("research worker terminal"), Degradation: &d}
}
func degradationFor(err error) Degradation {
	if errors.Is(err, context.DeadlineExceeded) {
		return PublicDegradation(DegradationTimeout)
	}
	var typed *RunnerError
	if errors.As(err, &typed) {
		if typed.Degradation != nil {
			return PublicDegradation(typed.Degradation.Code)
		}
		switch typed.Kind {
		case FailureTransient:
			return PublicDegradation(DegradationTransient)
		case FailureSafety:
			return PublicDegradation(DegradationSafetyRejected)
		case FailureValidation:
			return PublicDegradation(DegradationValidationRejected)
		}
	}
	return PublicDegradation(DegradationRunnerTerminal)
}

func failureKindFor(d Degradation) FailureKind {
	switch d.Code {
	case DegradationModelUnavailable, DegradationTransient:
		return FailureTransient
	case DegradationTimeout:
		return FailureTimeout
	case DegradationSafetyRejected:
		return FailureSafety
	case DegradationValidationRejected, DegradationEnhancementRejected:
		return FailureValidation
	default:
		return FailureTerminal
	}
}
