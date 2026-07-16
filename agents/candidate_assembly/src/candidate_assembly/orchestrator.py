"""Framework-neutral orchestrator interface + arm registry.

Every arm — the deterministic Go-scorer baseline, the single-shot judge, and the
bounded DeepAgents loop — implements the same ``CandidateAssembler`` protocol, so
the eval runner, the validator, and the graders never know or care which
transport produced a result. Arms are looked up by name from ``ARM_FACTORIES``;
the CLI selects a subset with ``--arm``.
"""

from __future__ import annotations

from typing import Callable, Protocol, runtime_checkable

from .budgets import Budget
from .schemas import AssemblyResult, CaseInput, FixtureWorld


@runtime_checkable
class CandidateAssembler(Protocol):
    name: str

    def assemble(
        self, case_input: CaseInput, world: FixtureWorld, budget: Budget
    ) -> AssemblyResult:
        ...


# Arm names are stable identifiers used by the CLI, recordings directory layout,
# and artifact records.
DETERMINISTIC_ARM = "deterministic"
DIRECT_JUDGE_ARM = "direct_judge"
DEEP_AGENT_ARM = "deep_agent"

ALL_ARMS: tuple[str, ...] = (DETERMINISTIC_ARM, DIRECT_JUDGE_ARM, DEEP_AGENT_ARM)

# Arms that never touch the network. Only these are graded live in replay mode;
# the model arms are replayed from recordings (or skipped when absent).
DETERMINISTIC_ARMS: frozenset[str] = frozenset({DETERMINISTIC_ARM})


def _build_deterministic() -> CandidateAssembler:
    from .arms.deterministic import DeterministicArm

    return DeterministicArm()


def _build_direct_judge() -> CandidateAssembler:
    from .arms.direct_judge import DirectJudgeArm

    return DirectJudgeArm()


def _build_deep_agent() -> CandidateAssembler:
    from .arms.deep_agent import DeepAgentArm

    return DeepAgentArm()


# Factories are lazy so importing the registry never imports the optional
# ``live`` dependency stack (langchain/deepagents). The deterministic arm and the
# whole replay path stay import-light.
ARM_FACTORIES: dict[str, Callable[[], CandidateAssembler]] = {
    DETERMINISTIC_ARM: _build_deterministic,
    DIRECT_JUDGE_ARM: _build_direct_judge,
    DEEP_AGENT_ARM: _build_deep_agent,
}


def build_arm(name: str) -> CandidateAssembler:
    if name not in ARM_FACTORIES:
        raise KeyError(f"unknown arm {name!r}; known arms: {', '.join(ALL_ARMS)}")
    return ARM_FACTORIES[name]()


def resolve_arm_names(selection: list[str] | None) -> list[str]:
    """Return the ordered, de-duplicated arm names for a selection, defaulting to
    all arms. Preserves the canonical ``ALL_ARMS`` order for stable artifacts."""

    if not selection:
        return list(ALL_ARMS)
    wanted = {name.strip() for name in selection if name and name.strip()}
    unknown = wanted - set(ARM_FACTORIES)
    if unknown:
        raise KeyError(
            f"unknown arm(s): {', '.join(sorted(unknown))}; known: {', '.join(ALL_ARMS)}"
        )
    return [name for name in ALL_ARMS if name in wanted]
