package research

import (
	"encoding/json"
	"time"
)

type JobStatus string

const (
	JobQueued          JobStatus = "queued"
	JobRunning         JobStatus = "running"
	JobCancelRequested JobStatus = "cancel_requested"
	JobCompleted       JobStatus = "completed"
	JobDegraded        JobStatus = "degraded"
	JobCancelled       JobStatus = "cancelled"
)

func (s JobStatus) Terminal() bool { return s == JobCompleted || s == JobDegraded || s == JobCancelled }

type RunStatus string

const (
	RunRunning   RunStatus = "running"
	RunCompleted RunStatus = "completed"
	RunDegraded  RunStatus = "degraded"
	RunCancelled RunStatus = "cancelled"
	RunTimedOut  RunStatus = "timed_out"
	RunLeaseLost RunStatus = "lease_lost"
)

func (s RunStatus) Terminal() bool {
	switch s {
	case RunCompleted, RunDegraded, RunCancelled, RunTimedOut, RunLeaseLost:
		return true
	default:
		return false
	}
}

type RevisionKind string

const (
	RevisionBaseline    RevisionKind = "baseline"
	RevisionEnhancement RevisionKind = "enhancement"
)

type DegradationCode string

const (
	DegradationModelDisabled       DegradationCode = "model_disabled"
	DegradationModelUnavailable    DegradationCode = "model_unavailable"
	DegradationBudgetExhausted     DegradationCode = "budget_exhausted"
	DegradationTransient           DegradationCode = "transient"
	DegradationTimeout             DegradationCode = "timeout"
	DegradationRunnerTerminal      DegradationCode = "runner_terminal"
	DegradationValidationRejected  DegradationCode = "validation_rejected"
	DegradationSafetyRejected      DegradationCode = "safety_rejected"
	DegradationEnhancementRejected DegradationCode = "enhancement_rejected"
	DegradationLeaseExpired        DegradationCode = "lease_expired"
	DegradationNoCandidates        DegradationCode = "no_candidates"
)

type Degradation struct {
	Code      DegradationCode `json:"code"`
	Message   string          `json:"message,omitempty"`
	Retryable bool            `json:"retryable"`
}

type EventKind string

const (
	EventCreated          EventKind = "created"
	EventRevisionAppended EventKind = "revision_appended"
	EventClaimed          EventKind = "claimed"
	EventLeaseRenewed     EventKind = "lease_renewed"
	EventLeaseRecovered   EventKind = "lease_recovered"
	EventDegraded         EventKind = "degraded"
	EventCancelRequested  EventKind = "cancel_requested"
	EventCancelled        EventKind = "cancelled"
	EventRetried          EventKind = "retried"
	EventCompleted        EventKind = "completed"
	EventReviewed         EventKind = "reviewed"
	EventRunnerTerminal   EventKind = "runner_terminal"
)

type FailureKind string

const (
	FailureTransient  FailureKind = "transient"
	FailureTerminal   FailureKind = "terminal"
	FailureSafety     FailureKind = "safety"
	FailureValidation FailureKind = "validation"
	FailureTimeout    FailureKind = "timeout"
)

type ReviewAction string

const (
	ReviewAccepted   ReviewAction = "accepted"
	ReviewOverridden ReviewAction = "overridden"
)

type CreateInput struct {
	ID             string          `json:"id,omitempty"`
	OwnerID        string          `json:"-"`
	Request        json.RawMessage `json:"request"`
	RequestHash    string          `json:"requestHash"`
	RetrySafe      bool            `json:"retrySafe"`
	MaxAttempts    int             `json:"maxAttempts"`
	IdempotencyKey string          `json:"idempotencyKey"`
	Baseline       RevisionInput   `json:"baseline"`
}

type Job struct {
	ID               string          `json:"id"`
	OwnerID          string          `json:"ownerId"`
	Request          json.RawMessage `json:"request"`
	RequestHash      string          `json:"requestHash"`
	IdempotencyKey   string          `json:"idempotencyKey"`
	Status           JobStatus       `json:"status"`
	RetrySafe        bool            `json:"retrySafe"`
	Attempts         int             `json:"attempts"`
	MaxAttempts      int             `json:"maxAttempts"`
	AvailableAt      time.Time       `json:"availableAt"`
	LatestRevision   int             `json:"latestRevision"`
	LatestRevisionID string          `json:"latestRevisionId"`
	CreatedAt        time.Time       `json:"createdAt"`
	UpdatedAt        time.Time       `json:"updatedAt"`
}

type Run struct {
	ID             string     `json:"id"`
	JobID          string     `json:"jobId"`
	WorkerID       string     `json:"workerId"`
	LeaseToken     string     `json:"leaseToken"`
	Status         RunStatus  `json:"status"`
	Attempt        int        `json:"attempt"`
	LeaseExpiresAt time.Time  `json:"leaseExpiresAt"`
	StartedAt      time.Time  `json:"startedAt"`
	FinishedAt     *time.Time `json:"finishedAt,omitempty"`
}

type RevisionInput struct {
	ID      string          `json:"id"`
	Payload json.RawMessage `json:"payload"`
}

type Revision struct {
	ID          string          `json:"id"`
	JobID       string          `json:"jobId"`
	Number      int             `json:"number"`
	Kind        RevisionKind    `json:"kind"`
	Payload     json.RawMessage `json:"payload"`
	ValidatedAt time.Time       `json:"validatedAt"`
}

type Snapshot struct {
	Job                     Job                `json:"job"`
	Revisions               []Revision         `json:"revisions"`
	LatestDegradation       *Degradation       `json:"latestDegradation,omitempty"`
	LatestTerminalTelemetry *TerminalTelemetry `json:"latestTerminalTelemetry,omitempty"`
}

// TerminalTelemetry is runner-owned, bounded lifecycle accounting. It contains
// no model text, command output, URLs, or credentials.
type TerminalTelemetry struct {
	ProcessStartupToRequestAcceptedMs *int64                 `json:"processStartupToRequestAcceptedMs,omitempty"`
	RequestAcceptedToDirectFirstMs    *int64                 `json:"requestAcceptedToDirectFirstRevisionMs,omitempty"`
	RequestAcceptedToFinalMs          *int64                 `json:"requestAcceptedToFinalMs,omitempty"`
	ToolCalls                         int                    `json:"toolCalls"`
	ModelAttempts                     []TerminalModelAttempt `json:"modelAttempts,omitempty"`
}

type TerminalModelAttempt struct {
	Stage      RevisionStage `json:"stage"`
	Attempt    int           `json:"attempt"`
	DurationMs int64         `json:"durationMs"`
	Repair     bool          `json:"repair"`
	Status     string        `json:"status"`
}

type Claim struct {
	Snapshot Snapshot `json:"snapshot"`
	Run      Run      `json:"run"`
}

type Event struct {
	JobID       string             `json:"jobId"`
	Sequence    int64              `json:"sequence"`
	Kind        EventKind          `json:"kind"`
	RunID       string             `json:"runId,omitempty"`
	RevisionID  string             `json:"revisionId,omitempty"`
	Revision    int                `json:"revision,omitempty"`
	Degradation *Degradation       `json:"degradation,omitempty"`
	Telemetry   *TerminalTelemetry `json:"telemetry,omitempty"`
	CreatedAt   time.Time          `json:"createdAt"`
}

type ReviewInput struct {
	RevisionID     string       `json:"revisionId"`
	RevisionNumber int          `json:"revisionNumber"`
	CandidateID    string       `json:"candidateId"`
	Action         ReviewAction `json:"action"`
	Reason         string       `json:"reason,omitempty"`
	IdempotencyKey string       `json:"idempotencyKey"`
	ReviewerID     string       `json:"reviewerId,omitempty"`
}
