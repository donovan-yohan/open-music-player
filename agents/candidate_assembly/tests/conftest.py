"""Shared builders for hand-constructed worlds, cases, and assembly results."""

from __future__ import annotations

from candidate_assembly.schemas import (
    AssemblyResult,
    BudgetSpent,
    Case,
    CatalogEntry,
    Expectations,
    FixtureWorld,
    InterpretedIntent,
    Provenance,
    RawCandidate,
    Recommendation,
    TraceStep,
)


def make_candidate(candidate_id: str, **overrides) -> RawCandidate:
    data = {
        "candidateId": candidate_id,
        "provider": candidate_id.split(":", 1)[0],
        "sourceUrl": f"https://example.test/{candidate_id}",
        "title": overrides.pop("title", "Artist - Song"),
        "downloadable": True,
    }
    data.update(overrides)
    return RawCandidate.model_validate(data)


def make_world(
    candidates: list[RawCandidate] | None = None,
    catalog: list[CatalogEntry] | None = None,
) -> FixtureWorld:
    if candidates is None:
        candidates = [
            make_candidate("youtube:a", title="Artist - Song (Official Audio)", durationMs=200000),
            make_candidate("youtube:b", title="Artist - Song (Live)", durationMs=260000),
        ]
    return FixtureWorld(candidates=candidates, catalog=catalog or [])


def make_recommendation(candidate_id: str, rank: int, **overrides) -> Recommendation:
    data = {
        "candidateId": candidate_id,
        "rank": rank,
        "confidence": 0.8,
        "rationale": "official audio: title indicates official audio.",
        "classification": "official_audio",
        "evidence": [],
        "warnings": [],
    }
    data.update(overrides)
    return Recommendation.model_validate(data)


def make_result(
    arm: str = "deterministic",
    recommendations: list[Recommendation] | None = None,
    trace_len: int = 1,
    **overrides,
) -> AssemblyResult:
    if recommendations is None:
        recommendations = [make_recommendation("youtube:a", 1)]
    trace = [
        TraceStep(step=i + 1, tool="search_sources", argsDigest="abc123", resultCount=2, elapsedMs=0)
        for i in range(trace_len)
    ]
    data = {
        "arm": arm,
        "interpretedIntent": InterpretedIntent(notes="test"),
        "recommendations": recommendations,
        "unresolved": [],
        "trace": trace,
        "budgetSpent": BudgetSpent(toolCalls=trace_len, modelCalls=0, elapsedMs=0),
        "provenance": Provenance(orchestrator="test", model="", toolTransport="none"),
    }
    data.update(overrides)
    return AssemblyResult.model_validate(data)


def make_case(case_id: str = "case", prompt: str = "play artist song", **expected) -> Case:
    return Case(
        id=case_id,
        prompt=prompt,
        poolRef=f"{case_id}.json",
        expected=Expectations.model_validate(expected),
    )
