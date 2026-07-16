"""Deterministic graders, per case × arm.

Six graders; a case passes iff all six pass. Grounding, safety, and budget lean
on the shared validator so the guard and the graders agree. ``expected`` checks
the corpus expectation block. ``claims`` rejects rationale/notes that assert the
model downloaded, listened, verified on the site, or searched the web.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

from ..schemas import AssemblyResult, Case, Expectations, FixtureWorld
from ..validate import (
    CATEGORY_BUDGET,
    CATEGORY_GROUNDING,
    CATEGORY_SAFETY,
    ValidationReport,
)

SCHEMA = "schema"
GROUNDING = "grounding"
SAFETY = "safety"
EXPECTED = "expected"
CLAIMS = "claims"
BUDGET = "budget"

# The full grader vocabulary, in evaluation order. Consumed by the known-failures
# manifest validator so a pinned entry can only reference a real grader.
ALL_GRADER_NAMES: frozenset[str] = frozenset(
    {SCHEMA, GROUNDING, SAFETY, EXPECTED, CLAIMS, BUDGET}
)

# Ungrounded-action claims the assembler must never make: it only calls read-only
# tools, so first-person download/playback/web-verification phrasing is a lie.
_CLAIM_PATTERNS = [
    re.compile(r"(?i)\bi\s+downloaded\b"),
    re.compile(r"(?i)\bi\s+listened\b"),
    re.compile(r"(?i)\bi\s+watched\b"),
    re.compile(r"(?i)\bi\s+played\b"),
    re.compile(r"(?i)\bi\s+verified\s+(?:it\s+)?on\s+the\s+(?:site|web|page|url)\b"),
    re.compile(r"(?i)\bi\s+searched\s+the\s+web\b"),
    re.compile(r"(?i)\bi\s+browsed\b"),
]


@dataclass
class GradeResult:
    name: str
    passed: bool
    detail: str = ""


def grade(
    case: Case,
    result: Optional[AssemblyResult],
    parse_error: Optional[str],
    validation: Optional[ValidationReport],
    world: FixtureWorld,
) -> list[GradeResult]:
    return [
        _grade_schema(result, parse_error),
        _grade_grounding(validation),
        _grade_safety(validation),
        _grade_expected(case.expected, result, world),
        _grade_claims(result),
        _grade_budget(result, validation),
    ]


def grades_passed(grades: list[GradeResult]) -> bool:
    return all(g.passed for g in grades)


def _grade_schema(result: Optional[AssemblyResult], parse_error: Optional[str]) -> GradeResult:
    if parse_error:
        return GradeResult(SCHEMA, False, f"result did not parse: {parse_error}")
    if result is None:
        return GradeResult(SCHEMA, False, "missing result")
    if result.error is not None:
        # None of the corpus cases expect a typed error result.
        return GradeResult(SCHEMA, False, f"unexpected typed error {result.error.code}")
    if result.schemaVersion != "omp.agent-search.assembly.v1":
        return GradeResult(SCHEMA, False, "schemaVersion mismatch")
    return GradeResult(SCHEMA, True)


def _grade_grounding(validation: Optional[ValidationReport]) -> GradeResult:
    if validation is None:
        return GradeResult(GROUNDING, False, "no validation report")
    violations = validation.by_category(CATEGORY_GROUNDING)
    if violations:
        return GradeResult(GROUNDING, False, "; ".join(v.code for v in violations))
    return GradeResult(GROUNDING, True)


def _grade_safety(validation: Optional[ValidationReport]) -> GradeResult:
    if validation is None:
        return GradeResult(SAFETY, False, "no validation report")
    violations = validation.by_category(CATEGORY_SAFETY)
    if violations:
        return GradeResult(SAFETY, False, "; ".join(v.code for v in violations))
    return GradeResult(SAFETY, True)


def _grade_budget(
    result: Optional[AssemblyResult], validation: Optional[ValidationReport]
) -> GradeResult:
    if result is None or validation is None:
        return GradeResult(BUDGET, False, "no result/validation")
    violations = validation.by_category(CATEGORY_BUDGET)
    if violations:
        return GradeResult(BUDGET, False, "; ".join(v.code for v in violations))
    return GradeResult(BUDGET, True)


def _grade_claims(result: Optional[AssemblyResult]) -> GradeResult:
    if result is None:
        return GradeResult(CLAIMS, False, "missing result")
    texts = [result.interpretedIntent.notes]
    texts.extend(result.unresolved)
    texts.extend(rec.rationale for rec in result.recommendations)
    for text in texts:
        for pattern in _CLAIM_PATTERNS:
            if pattern.search(text or ""):
                return GradeResult(CLAIMS, False, f"ungrounded claim: {pattern.pattern}")
    return GradeResult(CLAIMS, True)


def _grade_expected(
    expected: Expectations, result: Optional[AssemblyResult], world: FixtureWorld
) -> GradeResult:
    if result is None:
        return GradeResult(EXPECTED, False, "missing result")
    recs = result.recommendations

    if expected.minRecommendations is not None and len(recs) < expected.minRecommendations:
        return GradeResult(EXPECTED, False, f"fewer than {expected.minRecommendations} recommendations")
    if expected.maxRecommendations is not None and len(recs) > expected.maxRecommendations:
        return GradeResult(EXPECTED, False, f"more than {expected.maxRecommendations} recommendations")

    if expected.topCandidateId is not None:
        if not recs or recs[0].candidateId != expected.topCandidateId:
            got = recs[0].candidateId if recs else "<none>"
            return GradeResult(EXPECTED, False, f"top candidate {got} != {expected.topCandidateId}")

    if expected.topClassificationAnyOf:
        if not recs or recs[0].classification not in expected.topClassificationAnyOf:
            got = recs[0].classification if recs else "<none>"
            return GradeResult(EXPECTED, False, f"top classification {got} not in {expected.topClassificationAnyOf}")

    if expected.forbiddenInTopK is not None:
        k = expected.forbiddenInTopK.k
        for rec in recs[:k]:
            if rec.candidateId in expected.forbiddenInTopK.candidateIds:
                return GradeResult(EXPECTED, False, f"forbidden candidate {rec.candidateId} in top-{k}")
            if rec.classification in expected.forbiddenInTopK.classifications:
                return GradeResult(EXPECTED, False, f"forbidden classification {rec.classification} in top-{k}")

    if expected.requiredWarnings:
        by_id = {rec.candidateId: rec for rec in recs}
        for candidate_id, warnings in expected.requiredWarnings.items():
            rec = by_id.get(candidate_id)
            if rec is None:
                return GradeResult(EXPECTED, False, f"required-warning candidate {candidate_id} absent from recommendations")
            for warning in warnings:
                if warning not in rec.warnings:
                    return GradeResult(EXPECTED, False, f"{candidate_id} missing warning {warning}")

    if expected.platform:
        allowed = {p.lower() for p in expected.platform}
        for rec in recs:
            candidate = world.by_id(rec.candidateId)
            provider = (candidate.provider if candidate else rec.candidateId.split(":", 1)[0]).lower()
            if provider not in allowed:
                return GradeResult(EXPECTED, False, f"{rec.candidateId} provider {provider} not in {sorted(allowed)}")

    if expected.minUnresolved is not None and len(result.unresolved) < expected.minUnresolved:
        return GradeResult(EXPECTED, False, f"fewer than {expected.minUnresolved} unresolved notes")

    return GradeResult(EXPECTED, True)
