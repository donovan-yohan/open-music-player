"""Bounded, evals-first candidate-assembly orchestrator prototype (issue #265).

Public surface: schemas (the assembly contract), budgets, the read-only fixture
tools, the framework-neutral orchestrator interface + arm registry, the
deterministic post-agent verifier, and the eval runner. Nothing here imports the
optional ``live`` model stack at module load; the model arms import it lazily.
"""

from __future__ import annotations

from .budgets import Budget, BudgetExceeded
from .gateway_tools import GatewayConfig, GatewayToolBox, build_gateway_toolbox_from_env
from .schemas import (
    ASSEMBLY_SCHEMA_VERSION,
    CORPUS_SCHEMA_VERSION,
    PROMPT_REVISION,
    RUN_SCHEMA_VERSION,
    AssemblyResult,
    CaseInput,
    Corpus,
    FixtureWorld,
)

__all__ = [
    "Budget",
    "BudgetExceeded",
    "GatewayConfig",
    "GatewayToolBox",
    "build_gateway_toolbox_from_env",
    "AssemblyResult",
    "CaseInput",
    "Corpus",
    "FixtureWorld",
    "ASSEMBLY_SCHEMA_VERSION",
    "CORPUS_SCHEMA_VERSION",
    "RUN_SCHEMA_VERSION",
    "PROMPT_REVISION",
]
