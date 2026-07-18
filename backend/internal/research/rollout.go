package research

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// RolloutConfig is the framework-neutral policy boundary for optional
// asynchronous research. It contains only feature controls; request content,
// credentials, gateway configuration, and model configuration do not cross it.
type RolloutConfig struct {
	ResearchEnabled     bool
	DirectJudgeEnabled  bool
	DeepAgentEnabled    bool
	DeepAgentDarkLaunch bool
	DeepAgentCohortBPS  int
}

// NewRolloutVariantAssigner returns a deterministic, stateless assignment
// policy. The returned assignment is persisted by Service.Create and is then
// the only execution authority for retries and recovered leases.
func NewRolloutVariantAssigner(cfg RolloutConfig) (VariantAssigner, error) {
	if cfg.DeepAgentCohortBPS < 0 || cfg.DeepAgentCohortBPS > 10000 {
		return nil, fmt.Errorf("research deep-agent cohort must be between 0 and 10000 BPS")
	}
	if cfg.DeepAgentEnabled != cfg.DeepAgentDarkLaunch {
		return nil, fmt.Errorf("research deep-agent requires explicit dark-launch policy")
	}
	return rolloutVariantAssigner{cfg: cfg}, nil
}

type rolloutVariantAssigner struct{ cfg RolloutConfig }

func (a rolloutVariantAssigner) Assign(input VariantAssignmentInput) (VariantAssignment, error) {
	if !a.cfg.ResearchEnabled {
		return deterministicAssignment(), nil
	}
	if a.deepEligible(input) {
		return VariantAssignment{
			Variant: VariantBoundedAgentDarkLaunch,
			Cohort:  fmt.Sprintf("deep-bps-%04d", a.cfg.DeepAgentCohortBPS),
		}, nil
	}
	if a.cfg.DirectJudgeEnabled {
		return VariantAssignment{Variant: VariantDirectStructuredJudge, Cohort: defaultVariantCohort}, nil
	}
	return deterministicAssignment(), nil
}

func (a rolloutVariantAssigner) deepEligible(input VariantAssignmentInput) bool {
	if !a.cfg.DeepAgentEnabled || !a.cfg.DeepAgentDarkLaunch || a.cfg.DeepAgentCohortBPS == 0 || input.RequestHash == "" {
		return false
	}
	return rolloutCohortBPS(input.RequestHash) < a.cfg.DeepAgentCohortBPS
}

// rolloutCohortBPS hashes the already canonical request digest, rather than
// request text or any operator credential. It returns a stable [0, 10000)
// bucket and retains no assignment input.
func rolloutCohortBPS(requestHash string) int {
	digest := sha256.Sum256([]byte("omp-research-rollout-v1:" + requestHash))
	return int(binary.BigEndian.Uint64(digest[:8]) % 10000)
}

func deterministicAssignment() VariantAssignment {
	return VariantAssignment{Variant: VariantDeterministicOnly, Cohort: defaultVariantCohort}
}
