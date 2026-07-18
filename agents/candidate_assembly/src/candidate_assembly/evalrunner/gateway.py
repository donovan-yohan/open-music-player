"""Explicit real-provider dark-launch evaluator for the private Go gateway.

This is intentionally separate from the fixture corpus.  Provider results are
volatile, while replay must remain deterministic and offline.  The evaluator
records counts, timing, and typed outcomes only: no candidate text, URLs,
capabilities, credentials, or extracted markdown can enter an artifact.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..budgets import BUDGET_EXCEEDED_CODE, Budget, BudgetExceeded
from ..fixture_tools import ToolError
from ..gateway_tools import GatewayToolBox
from ..schemas import ALLOWED_PROVIDERS, is_safe_gateway_text

GATEWAY_CORPUS_SCHEMA_VERSION = "omp.agent-search.eval.gateway-corpus.v1"
GATEWAY_RUN_SCHEMA_VERSION = "omp.agent-search.eval.gateway-run.v1"

_FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "gateway_cases.v1.json"
_FIRECRAWL_ERRORS = frozenset(
    {
        "FIRECRAWL_DISABLED",
        "FIRECRAWL_TIMEOUT",
        "FIRECRAWL_RATE_LIMIT",
        "FIRECRAWL_RESPONSE_TOO_LARGE",
    }
)


class GatewayEvalError(RuntimeError):
    pass


class GatewayCase(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=80)
    query: str = Field(min_length=1, max_length=512)
    providers: list[str] = Field(default_factory=list, max_length=2)
    reviewedScenario: str = Field(min_length=1, max_length=80)
    requireCatalog: bool = True

    @field_validator("id", "query", "reviewedScenario")
    @classmethod
    def _safe_text(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway eval text")
        return value

    @field_validator("providers")
    @classmethod
    def _providers(cls, values: list[str]) -> list[str]:
        if any(provider not in ALLOWED_PROVIDERS for provider in values):
            raise ValueError("unsupported provider")
        return values


class GatewayCorpus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schemaVersion: str
    cases: list[GatewayCase] = Field(min_length=6, max_length=6)


class GatewayTools(Protocol):
    tool_calls: int
    trace: list

    def search_sources(self, query: str, providers: list[str] | None = None, limit: int = 10): ...

    def search_catalog(self, query: str, kind: str = "track", limit: int = 8): ...

    def extract_web(self, evidence_ref: str): ...


@dataclass(frozen=True)
class GatewayCaseOutcome:
    case_id: str
    terminal: str
    degradation: str
    fallback: str
    recovery: str
    budget: str
    latency_ms: int
    tool_calls: int
    model_calls: int
    tool_durations_ms: dict[str, int]
    source_count: int
    catalog_count: int
    provider_counts: dict[str, int]
    duration_mismatch_observed: bool
    error_code: str | None = None

    def record(self) -> dict:
        return {
            "schemaVersion": GATEWAY_RUN_SCHEMA_VERSION,
            "recordType": "gatewayCase",
            "caseId": self.case_id,
            "terminal": self.terminal,
            "degradation": self.degradation,
            "fallback": self.fallback,
            "recovery": self.recovery,
            "budget": self.budget,
            "latencyMs": self.latency_ms,
            "modelCalls": self.model_calls,
            "toolCalls": self.tool_calls,
            "toolDurationsMs": self.tool_durations_ms,
            "sourceCount": self.source_count,
            "catalogCount": self.catalog_count,
            "providerCounts": self.provider_counts,
            "durationMismatchObserved": self.duration_mismatch_observed,
            "errorCode": self.error_code,
        }


def load_gateway_corpus(path: Path | None = None) -> GatewayCorpus:
    try:
        raw = json.loads((path or _FIXTURE_PATH).read_text())
        corpus = GatewayCorpus.model_validate(raw)
    except (OSError, ValueError) as exc:
        raise GatewayEvalError("gateway eval corpus is invalid") from exc
    if corpus.schemaVersion != GATEWAY_CORPUS_SCHEMA_VERSION:
        raise GatewayEvalError("unsupported gateway eval corpus schema")
    ids = [case.id for case in corpus.cases]
    if len(ids) != len(set(ids)):
        raise GatewayEvalError("gateway eval corpus has duplicate case ids")
    required = {
        "official-audio",
        "explicit-request",
        "explicit-remix",
        "soundcloud-only",
        "ambiguous-catalog-title",
        "cross-provider-duration-mismatch",
    }
    if set(ids) != required:
        raise GatewayEvalError("gateway eval corpus must contain the reviewed case set")
    return corpus


def _duration_mismatch(candidates, catalog) -> bool:
    targets = [item.durationMs for item in catalog if getattr(item, "durationMs", None)]
    if not targets:
        return False
    target = targets[0]
    for candidate in candidates:
        duration = getattr(candidate, "durationMs", None)
        if duration is not None and abs(duration - target) > 2_000 and abs(duration - target) / target > 0.07:
            return True
    return False


def run_gateway_case(
    case: GatewayCase,
    toolbox: GatewayTools,
    budget: Budget,
    *,
    cancelled: Callable[[], bool] = lambda: False,
    monotonic: Callable[[], float] = time.monotonic,
) -> GatewayCaseOutcome:
    """Execute the bounded provider/catalog probe without recording observations."""

    started = monotonic()
    source_count = catalog_count = 0
    provider_counts: dict[str, int] = {}
    mismatch = False
    try:
        if cancelled():
            return GatewayCaseOutcome(case.id, "cancelled", "cancelled", "deterministic_baseline", "not_attempted", "within_budget", 0, 0, 0, {}, 0, 0, {}, False)
        candidates = toolbox.search_sources(case.query, case.providers or None, min(12, budget.max_candidates_in))
        source_count = len(candidates)
        for candidate in candidates:
            provider = getattr(candidate, "provider", "")
            if provider in ALLOWED_PROVIDERS:
                provider_counts[provider] = provider_counts.get(provider, 0) + 1
        if cancelled():
            return GatewayCaseOutcome(case.id, "cancelled", "cancelled", "deterministic_baseline", "not_attempted", "within_budget", _elapsed(started, monotonic), toolbox.tool_calls, 0, _tool_durations(toolbox.trace), source_count, 0, provider_counts, False)
        catalog = toolbox.search_catalog(case.query, "track", 8) if case.requireCatalog else []
        catalog_count = len(catalog)
        mismatch = _duration_mismatch(candidates, catalog)
        degradation = "none"
        if not source_count or (case.requireCatalog and not catalog_count):
            degradation = "provider_or_catalog_empty"
        if case.providers and any(getattr(c, "provider", None) not in case.providers for c in candidates):
            degradation = "provider_filter_drift"
        return GatewayCaseOutcome(case.id, "completed", degradation, "none" if degradation == "none" else "deterministic_baseline", "not_attempted", "within_budget", _elapsed(started, monotonic), toolbox.tool_calls, 0, _tool_durations(toolbox.trace), source_count, catalog_count, provider_counts, mismatch)
    except BudgetExceeded:
        return GatewayCaseOutcome(case.id, "failed", "budget_exhausted", "deterministic_baseline", "not_attempted", "exhausted", _elapsed(started, monotonic), getattr(toolbox, "tool_calls", 0), 0, _tool_durations(getattr(toolbox, "trace", [])), source_count, catalog_count, provider_counts, mismatch, BUDGET_EXCEEDED_CODE)
    except ToolError as exc:
        return GatewayCaseOutcome(case.id, "failed", "gateway_error", "deterministic_baseline", "not_attempted", "within_budget", _elapsed(started, monotonic), getattr(toolbox, "tool_calls", 0), 0, _tool_durations(getattr(toolbox, "trace", [])), source_count, catalog_count, provider_counts, mismatch, exc.code)


def _elapsed(started: float, monotonic: Callable[[], float]) -> int:
    return max(0, int(round((monotonic() - started) * 1000)))


def _tool_durations(trace: list) -> dict[str, int]:
    """Convert cumulative safe trace timings into per-tool durations."""

    previous = 0
    durations: dict[str, int] = {}
    for step in trace:
        tool = getattr(step, "tool", "")
        elapsed = getattr(step, "elapsedMs", previous)
        if tool not in {"search_sources", "search_catalog", "inspect_source_metadata", "extract_web"}:
            continue
        if not isinstance(elapsed, int) or elapsed < previous:
            continue
        durations[tool] = durations.get(tool, 0) + elapsed - previous
        previous = elapsed
    return durations


def run_firecrawl_experiment(
    toolbox: GatewayTools,
    case: GatewayCase,
    budget: Budget,
    *,
    enabled: bool,
    cancelled: Callable[[], bool] = lambda: False,
) -> dict:
    """One allowlisted extraction, with output intentionally discarded.

    It is an explicit billing boundary.  The result is a safe accounting record
    and typed status only; markdown is never returned or persisted.
    """

    record = {
        "schemaVersion": GATEWAY_RUN_SCHEMA_VERSION,
        "recordType": "firecrawlExperiment",
        "caseId": case.id,
        "enabled": enabled,
        "terminal": "disabled" if not enabled else "not_started",
        "errorCode": None,
        "firecrawlRequests": 0,
        "firecrawlCredits": 0,
        "firecrawlJobs": 0,
        "outputStored": False,
    }
    if not enabled:
        return record
    if cancelled():
        record["terminal"] = "cancelled"
        return record
    try:
        candidates = toolbox.search_sources(case.query, case.providers or None, min(12, budget.max_candidates_in))
        ref = next((ref for candidate in candidates for ref in getattr(candidate, "evidenceRefs", [])[:1]), None)
        if not ref:
            record["terminal"] = "degraded"
            record["errorCode"] = "EVIDENCE_UNAVAILABLE"
            return record
        if cancelled():
            record["terminal"] = "cancelled"
            return record
        # Exactly one extract call; response text is deliberately ignored.
        toolbox.extract_web(ref)
        record.update({"terminal": "completed", "firecrawlRequests": 1, "firecrawlCredits": 1, "firecrawlJobs": 1})
        return record
    except BudgetExceeded:
        record.update({"terminal": "failed", "errorCode": BUDGET_EXCEEDED_CODE})
        return record
    except ToolError as exc:
        record.update({"terminal": "failed", "errorCode": exc.code if exc.code in _FIRECRAWL_ERRORS else "GATEWAY_ERROR"})
        return record


def build_gateway_records(
    corpus: GatewayCorpus,
    outcomes: list[GatewayCaseOutcome],
    *,
    firecrawl: dict | None = None,
    local_resource: dict | None = None,
    run_state: str = "idle",
) -> list[dict]:
    records = [{
        "schemaVersion": GATEWAY_RUN_SCHEMA_VERSION,
        "recordType": "run",
        "run": {"mode": "gateway", "runState": run_state, "cases": [outcome.case_id for outcome in outcomes], "model": "none", "toolTransport": "private_gateway"},
        "localResource": local_resource,
    }]
    records.extend(outcome.record() for outcome in outcomes)
    if firecrawl is not None:
        records.append(firecrawl)
    records.append({
        "schemaVersion": GATEWAY_RUN_SCHEMA_VERSION,
        "recordType": "summary",
        "totals": {
            "cases": len(outcomes),
            "completed": sum(outcome.terminal == "completed" for outcome in outcomes),
            "degraded": sum(outcome.degradation != "none" for outcome in outcomes),
            "failed": sum(outcome.terminal == "failed" for outcome in outcomes),
            "cancelled": sum(outcome.terminal == "cancelled" for outcome in outcomes),
            "firecrawlRequests": (firecrawl or {}).get("firecrawlRequests", 0),
            "firecrawlCredits": (firecrawl or {}).get("firecrawlCredits", 0),
        },
    })
    return records


def build_gateway_toolbox(budget: Budget) -> GatewayToolBox:
    """Environment-only construction kept here so replay never imports it."""

    from ..gateway_tools import build_gateway_toolbox_from_env

    return build_gateway_toolbox_from_env(budget)
