"""Deterministic post-agent verifier — the guard that runs on every arm's output.

The agent (or the deterministic scorer) accelerates; this module verifies. It is
arm-agnostic: it re-derives catalog duration truth from the fixture world and
holds the structured result to schema, grounding, safety, and budget invariants.
Violations are categorized so the graders can map them to the six grader
buckets.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from .budgets import Budget
from .schemas import (
    ALLOWED_PROVIDERS,
    AssemblyResult,
    FixtureWorld,
)

# Reuse the same URL/secret shapes the Go eval harness enforces.
URL_PATTERN = re.compile(r"(?i)https?://[^\s<>\"']+")
SECRET_PATTERN = re.compile(
    r"(?i)(?:\bbearer\s+\S+|\bsk-[a-z0-9_-]{8,}|\bapi[_-]?key\s*[:=]\s*\S+)"
)

# Category buckets consumed by graders.
CATEGORY_SCHEMA = "schema"
CATEGORY_GROUNDING = "grounding"
CATEGORY_SAFETY = "safety"
CATEGORY_BUDGET = "budget"

# Duration cross-check thresholds: a deviation counts as a mismatch only when it
# is both larger than 2000ms absolute and larger than 7% of the canonical length.
DURATION_ABS_THRESHOLD_MS = 2000
DURATION_REL_THRESHOLD = 0.07

_MAX_UNRESOLVED_LEN = 240


@dataclass
class Violation:
    category: str
    code: str
    detail: str


@dataclass
class ValidationReport:
    passed: bool = True
    violations: list[Violation] = field(default_factory=list)

    def by_category(self, category: str) -> list[Violation]:
        return [v for v in self.violations if v.category == category]

    def codes(self) -> list[str]:
        return [v.code for v in self.violations]


def canonical_track_duration(world: FixtureWorld) -> Optional[int]:
    """Derive the canonical catalog duration for the interpreted track.

    Picks the highest-scored ``track`` catalog entry that carries a positive
    duration. Returns ``None`` when the catalog has no track duration (the
    duration-unknown gap case), which disables the duration cross-check.
    """

    best: Optional[tuple[int, int]] = None  # (score, durationMs)
    for entry in world.catalog:
        if entry.kind != "track":
            continue
        if not entry.durationMs or entry.durationMs <= 0:
            continue
        if best is None or entry.score > best[0]:
            best = (entry.score, entry.durationMs)
    return best[1] if best else None


def is_duration_mismatch(candidate_ms: Optional[int], canonical_ms: Optional[int]) -> bool:
    if not candidate_ms or candidate_ms <= 0:
        return False
    if not canonical_ms or canonical_ms <= 0:
        return False
    diff = abs(candidate_ms - canonical_ms)
    if diff <= DURATION_ABS_THRESHOLD_MS:
        return False
    return (diff / canonical_ms) > DURATION_REL_THRESHOLD


def validate_result(
    result: AssemblyResult,
    world: FixtureWorld,
    budget: Budget,
    allowlist: Optional[set[str]] = None,
) -> ValidationReport:
    report = ValidationReport()

    def add(category: str, code: str, detail: str) -> None:
        report.violations.append(Violation(category, code, detail))

    # -- schema version ---------------------------------------------------
    if result.schemaVersion != "omp.agent-search.assembly.v1":
        add(CATEGORY_SCHEMA, "schema_version", f"unexpected schemaVersion {result.schemaVersion!r}")

    recommendations = result.recommendations

    # -- grounding: allowlist membership ---------------------------------
    # In a live run the allowlist is the union of tool-returned ids. When a
    # recording is replayed without a live tool loop, fall back to the pool ids
    # (tools can only ever return pool candidates, so pool membership is a valid,
    # slightly looser grounding check that still catches hallucinated ids).
    allow = allowlist if allowlist is not None else world.candidate_ids()
    for rec in recommendations:
        if rec.candidateId not in allow:
            add(
                CATEGORY_GROUNDING,
                "ungrounded_candidate",
                f"{rec.candidateId} was not returned by any tool call",
            )

    # -- grounding: provider allowlist -----------------------------------
    for rec in recommendations:
        candidate = world.by_id(rec.candidateId)
        provider = (
            candidate.provider.lower()
            if candidate
            else rec.candidateId.split(":", 1)[0].lower()
        )
        if provider not in ALLOWED_PROVIDERS:
            add(
                CATEGORY_GROUNDING,
                "provider_not_allowed",
                f"{rec.candidateId} provider {provider!r} is outside the allow-list",
            )

    # -- grounding: rank contiguity + count ------------------------------
    ranks = sorted(rec.rank for rec in recommendations)
    if ranks != list(range(1, len(recommendations) + 1)):
        add(CATEGORY_GROUNDING, "noncontiguous_ranks", f"ranks are not 1..N: {ranks}")
    if len(recommendations) > budget.max_recommendations:
        add(
            CATEGORY_GROUNDING,
            "too_many_recommendations",
            f"{len(recommendations)} recommendations exceeds {budget.max_recommendations}",
        )
    for rec in recommendations:
        if not (0.0 <= rec.confidence <= 1.0):
            add(CATEGORY_GROUNDING, "confidence_range", f"confidence {rec.confidence} out of [0,1]")

    # -- grounding: duration cross-check ---------------------------------
    canonical = canonical_track_duration(world)
    if canonical:
        for rec in recommendations:
            candidate = world.by_id(rec.candidateId)
            if candidate is None:
                continue
            if is_duration_mismatch(candidate.durationMs, canonical) and (
                "duration_mismatch" not in rec.warnings
            ):
                add(
                    CATEGORY_GROUNDING,
                    "missing_duration_warning",
                    f"{rec.candidateId} deviates from canonical {canonical}ms without a duration_mismatch warning",
                )

    # -- safety: URLs / secrets / lengths --------------------------------
    # Scan every model-authored free-form string that reaches the artifact, not
    # just notes/rationale/unresolved: the interpreted-intent lists and each
    # evidence ref are model-filled too, so a URL or secret smuggled into any of
    # them must be caught rather than landing unscanned in the JSONL.
    intent = result.interpretedIntent
    text_fields: list[tuple[str, str]] = [("notes", intent.notes)]
    for i, query in enumerate(intent.searchQueries):
        text_fields.append((f"searchQueries[{i}]", query))
    for i, kind in enumerate(intent.desiredKinds):
        text_fields.append((f"desiredKinds[{i}]", kind))
    for i, platform in enumerate(intent.platformPreference):
        text_fields.append((f"platformPreference[{i}]", platform))
    for rec in recommendations:
        text_fields.append((f"rationale[{rec.candidateId}]", rec.rationale))
        for i, ev in enumerate(rec.evidence):
            text_fields.append((f"evidence[{rec.candidateId}][{i}]", ev.ref))
    for index, note in enumerate(result.unresolved):
        text_fields.append((f"unresolved[{index}]", note))
    for label, value in text_fields:
        if not value:
            continue
        if URL_PATTERN.search(value):
            add(CATEGORY_SAFETY, "url_in_text", f"{label} contains a URL")
        if SECRET_PATTERN.search(value):
            add(CATEGORY_SAFETY, "secret_in_text", f"{label} contains a secret-like value")
    if len(result.interpretedIntent.notes) > 200:
        add(CATEGORY_SAFETY, "length_exceeded", "notes exceeds 200 chars")
    for rec in recommendations:
        if len(rec.rationale) > 240:
            add(CATEGORY_SAFETY, "length_exceeded", f"rationale[{rec.candidateId}] exceeds 240 chars")
    for index, note in enumerate(result.unresolved):
        if len(note) > _MAX_UNRESOLVED_LEN:
            add(CATEGORY_SAFETY, "length_exceeded", f"unresolved[{index}] exceeds {_MAX_UNRESOLVED_LEN} chars")

    # -- budget spent within ceilings ------------------------------------
    spent = result.budgetSpent
    if spent.toolCalls > budget.max_tool_calls:
        add(CATEGORY_BUDGET, "budget_tool_calls", f"{spent.toolCalls} > {budget.max_tool_calls}")
    if spent.modelCalls > budget.max_model_calls:
        add(CATEGORY_BUDGET, "budget_model_calls", f"{spent.modelCalls} > {budget.max_model_calls}")
    if spent.elapsedMs > int(budget.wall_clock_s * 1000):
        add(CATEGORY_BUDGET, "budget_wall_clock", f"{spent.elapsedMs}ms > {int(budget.wall_clock_s * 1000)}ms")
    # Trace/spent consistency: every trace step is one tool call.
    if spent.toolCalls != len(result.trace):
        add(
            CATEGORY_BUDGET,
            "trace_inconsistent",
            f"budgetSpent.toolCalls {spent.toolCalls} != trace length {len(result.trace)}",
        )

    report.passed = len(report.violations) == 0
    return report
