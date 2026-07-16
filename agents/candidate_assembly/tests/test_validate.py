from __future__ import annotations

from candidate_assembly.budgets import Budget
from candidate_assembly.schemas import CatalogEntry
from candidate_assembly.validate import (
    CATEGORY_BUDGET,
    CATEGORY_GROUNDING,
    CATEGORY_SAFETY,
    canonical_track_duration,
    is_duration_mismatch,
    validate_result,
)
from conftest import make_candidate, make_recommendation, make_result, make_world


def _codes(report, category):
    return {v.code for v in report.by_category(category)}


def test_clean_result_passes_validation():
    world = make_world()
    result = make_result()
    report = validate_result(result, world, Budget.default())
    assert report.passed, report.codes()


def test_ungrounded_candidate_flagged():
    world = make_world()
    result = make_result(recommendations=[make_recommendation("youtube:ghost", 1)])
    report = validate_result(result, world, Budget.default())
    assert "ungrounded_candidate" in _codes(report, CATEGORY_GROUNDING)


def test_provider_not_allowed_flagged():
    world = make_world(candidates=[make_candidate("vimeo:z", title="Artist - Song")])
    result = make_result(recommendations=[make_recommendation("vimeo:z", 1)])
    report = validate_result(result, world, Budget.default())
    assert "provider_not_allowed" in _codes(report, CATEGORY_GROUNDING)


def test_noncontiguous_ranks_flagged():
    world = make_world()
    recs = [make_recommendation("youtube:a", 1), make_recommendation("youtube:b", 3)]
    result = make_result(recommendations=recs, trace_len=1)
    report = validate_result(result, world, Budget.default())
    assert "noncontiguous_ranks" in _codes(report, CATEGORY_GROUNDING)


def test_too_many_recommendations_flagged():
    world = make_world(
        candidates=[make_candidate(f"youtube:{i}", title="Artist - Song") for i in range(4)]
    )
    recs = [make_recommendation(f"youtube:{i}", i + 1) for i in range(4)]
    result = make_result(recommendations=recs)
    report = validate_result(result, world, Budget.default().with_overrides(max_recommendations=2))
    assert "too_many_recommendations" in _codes(report, CATEGORY_GROUNDING)


def test_url_in_rationale_flagged():
    world = make_world()
    rec = make_recommendation("youtube:a", 1, rationale="see https://evil.test/x for details")
    result = make_result(recommendations=[rec])
    report = validate_result(result, world, Budget.default())
    assert "url_in_text" in _codes(report, CATEGORY_SAFETY)


def test_secret_in_notes_flagged():
    world = make_world()
    from candidate_assembly.schemas import InterpretedIntent

    result = make_result(interpretedIntent=InterpretedIntent(notes="api_key=sk-abcdefgh12345678"))
    report = validate_result(result, world, Budget.default())
    assert "secret_in_text" in _codes(report, CATEGORY_SAFETY)


def test_budget_and_trace_consistency_flagged():
    world = make_world()
    # budgetSpent.toolCalls (5) disagrees with the trace length (1).
    from candidate_assembly.schemas import BudgetSpent

    result = make_result(trace_len=1, budgetSpent=BudgetSpent(toolCalls=5, modelCalls=0, elapsedMs=0))
    report = validate_result(result, world, Budget.default())
    assert "trace_inconsistent" in _codes(report, CATEGORY_BUDGET)


def test_budget_tool_calls_over_ceiling_flagged():
    world = make_world()
    from candidate_assembly.schemas import BudgetSpent

    result = make_result(trace_len=1, budgetSpent=BudgetSpent(toolCalls=99, modelCalls=0, elapsedMs=0))
    report = validate_result(result, world, Budget.default().with_overrides(max_tool_calls=8))
    assert "budget_tool_calls" in _codes(report, CATEGORY_BUDGET)


def test_missing_duration_warning_flagged():
    world = make_world(
        candidates=[make_candidate("youtube:long", title="Artist - Song", durationMs=2880000)],
        catalog=[CatalogEntry(kind="track", id="mb:t", title="Song", artist="Artist", durationMs=240000, score=90)],
    )
    rec = make_recommendation("youtube:long", 1, warnings=[])
    result = make_result(recommendations=[rec])
    report = validate_result(result, world, Budget.default())
    assert "missing_duration_warning" in _codes(report, CATEGORY_GROUNDING)


def test_duration_warning_present_passes():
    world = make_world(
        candidates=[make_candidate("youtube:long", title="Artist - Song", durationMs=2880000)],
        catalog=[CatalogEntry(kind="track", id="mb:t", title="Song", artist="Artist", durationMs=240000, score=90)],
    )
    rec = make_recommendation("youtube:long", 1, warnings=["duration_mismatch"])
    result = make_result(recommendations=[rec])
    report = validate_result(result, world, Budget.default())
    assert "missing_duration_warning" not in _codes(report, CATEGORY_GROUNDING)


def test_duration_mismatch_boundary():
    # Requires BOTH > 2000ms absolute AND > 7% relative.
    assert is_duration_mismatch(202000, 200000) is False  # exactly 2000ms diff
    assert is_duration_mismatch(202001, 200000) is False  # >2000ms but ~1% relative
    assert is_duration_mismatch(107000, 100000) is False  # exactly 7% relative
    assert is_duration_mismatch(107001, 100000) is True  # >2000ms and >7%
    assert is_duration_mismatch(108000, 100000) is True
    assert is_duration_mismatch(None, 100000) is False
    assert is_duration_mismatch(100000, None) is False


def test_canonical_track_duration_prefers_highest_score():
    world = make_world(
        catalog=[
            CatalogEntry(kind="track", id="a", title="x", durationMs=200000, score=70),
            CatalogEntry(kind="track", id="b", title="x", durationMs=240000, score=95),
            CatalogEntry(kind="artist", id="c", title="x", score=99),
        ]
    )
    assert canonical_track_duration(world) == 240000


def test_canonical_track_duration_none_when_no_duration():
    world = make_world(
        catalog=[CatalogEntry(kind="track", id="a", title="x", score=80)]
    )
    assert canonical_track_duration(world) is None
