package research

import (
	"context"
	"errors"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

var (
	ErrNotFound       = errors.New("research job not found")
	ErrForbidden      = errors.New("research job is not owned by user")
	ErrNoJobAvailable = errors.New("no research job available")
	ErrLeaseLost      = errors.New("research job lease lost")
)

// Repository persists every mutation and its ordered event atomically. Create
// must persist the deterministic baseline and both created/revision events.
type Repository interface {
	Create(ctx context.Context, input CreateInput) (*Snapshot, error)
	Get(ctx context.Context, jobID, ownerID string) (*Snapshot, error)
	Events(ctx context.Context, jobID, ownerID string, afterSequence int64, limit int) ([]Event, error)
	Cancel(ctx context.Context, jobID, ownerID string) (*Snapshot, error)
	Retry(ctx context.Context, jobID, ownerID string) (*Snapshot, error)
	Review(ctx context.Context, jobID, ownerID string, input ReviewInput) (*db.SourceSelectionDecision, error)
	Claim(ctx context.Context, workerID string, capabilities WorkerCapabilities, leaseExpiresAt time.Time) (*Claim, error)
	RenewLease(ctx context.Context, claim Claim, leaseExpiresAt time.Time) (bool, error)
	RecoverExpiredLeases(ctx context.Context, now time.Time) (int, error)
	AppendEnhancement(ctx context.Context, claim Claim, input RevisionInput) (*Revision, error)
	RecordTerminal(ctx context.Context, claim Claim, telemetry TerminalTelemetry) error
	Degrade(ctx context.Context, claim Claim, degradation Degradation) (*Snapshot, error)
	RetryClaim(ctx context.Context, claim Claim, retryAt time.Time) (*Snapshot, error)
	Finish(ctx context.Context, claim Claim, status JobStatus) (*Snapshot, error)
}

type Validator interface {
	ValidateBaseline(context.Context, RevisionInput) error
	ValidateEnhancement(context.Context, Snapshot, RevisionInput) error
}

type ServiceConfig struct {
	Repository      Repository
	Validator       Validator
	VariantAssigner VariantAssigner
}
type Service struct {
	repository      Repository
	validator       Validator
	variantAssigner VariantAssigner
}

// VariantAssigner owns stable policy selection. The core passes only durable
// identifiers, making this layer independent from process configuration.
type VariantAssigner interface {
	Assign(VariantAssignmentInput) (VariantAssignment, error)
}

type VariantAssignerFunc func(VariantAssignmentInput) (VariantAssignment, error)

func (f VariantAssignerFunc) Assign(input VariantAssignmentInput) (VariantAssignment, error) {
	return f(input)
}

type deterministicVariantAssigner struct{}

func (deterministicVariantAssigner) Assign(VariantAssignmentInput) (VariantAssignment, error) {
	return deterministicAssignment(), nil
}

func NewService(cfg ServiceConfig) *Service {
	assigner := cfg.VariantAssigner
	if assigner == nil {
		assigner = deterministicVariantAssigner{}
	}
	return &Service{repository: cfg.Repository, validator: cfg.Validator, variantAssigner: assigner}
}
func (s *Service) Create(ctx context.Context, input CreateInput) (*Snapshot, error) {
	canonical, hash, err := CanonicalRequestHash(input.Request)
	if err != nil {
		return nil, err
	}
	input.Request, input.RequestHash = canonical, hash
	if err := ValidateCreate(input); err != nil {
		return nil, err
	}
	if s.validator == nil {
		return nil, errors.New("research validator is required")
	}
	if err := s.validator.ValidateBaseline(ctx, input.Baseline); err != nil {
		return nil, err
	}
	assignment, err := s.variantAssigner.Assign(VariantAssignmentInput{OwnerID: input.OwnerID, RequestHash: input.RequestHash, IdempotencyKey: input.IdempotencyKey})
	if err != nil {
		return nil, err
	}
	input.Assignment, err = NormalizeVariantAssignment(assignment)
	if err != nil {
		return nil, err
	}
	return s.repository.Create(ctx, input)
}
func (s *Service) Get(ctx context.Context, id, owner string) (*Snapshot, error) {
	return s.repository.Get(ctx, id, owner)
}
func (s *Service) Events(ctx context.Context, id, owner string, after int64, limit int) ([]Event, error) {
	return s.repository.Events(ctx, id, owner, after, limit)
}
func (s *Service) Cancel(ctx context.Context, id, owner string) (*Snapshot, error) {
	return s.repository.Cancel(ctx, id, owner)
}
func (s *Service) Retry(ctx context.Context, id, owner string) (*Snapshot, error) {
	return s.repository.Retry(ctx, id, owner)
}
func (s *Service) Review(ctx context.Context, id, owner string, input ReviewInput) (*db.SourceSelectionDecision, error) {
	if err := ValidateReview(input); err != nil {
		return nil, err
	}
	return s.repository.Review(ctx, id, owner, input)
}
