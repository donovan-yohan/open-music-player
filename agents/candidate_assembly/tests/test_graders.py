from __future__ import annotations

from candidate_assembly.budgets import Budget
from candidate_assembly.evalrunner import graders as g
from candidate_assembly.schemas import (
    AssemblyError,
    BudgetSpent,
    CatalogEntry,
    InterpretedIntent,
)
from conftest import make_candidate, make_case, make_recommendation, make_result, make_world


def _world():
    return make_world(
        candidates=[
            make_candidate("youtube:a", title="Artist - Song (Official Audio)", durationMs=200000),
            make_candidate("youtube:b", title="Artist - Song (Live)", durationMs=260000),
        ],
        catalog=[CatalogEntry(kind="track", id="mb:t", title="Song", artist="Artist", durationMs=200000, score=90)],
    )


def _grade(case, result, world, parse_error=None):
    from candidate_assembly.validate import validate_result

    validation = validate_result(result, world, Budget.default()) if result is not None else None
    return {gr.name: gr for gr in g.grade(case, result, parse_error, validation, world)}


def test_all_graders_pass_on_clean_result():
    world = _world()
    case = make_case(topCandidateId="youtube:a", topClassificationAnyOf=["official_audio"])
    result = make_result(recommendations=[make_recommendation("youtube:a", 1)], trace_len=1)
    grades = _grade(case, result, world)
    assert all(gr.passed for gr in grades.values()), {k: v.detail for k, v in grades.items()}


def test_schema_grader_fails_on_parse_error():
    world = _world()
    case = make_case()
    grades = _grade(case, None, world, parse_error="unexpected field")
    assert grades[g.SCHEMA].passed is False


def test_schema_grader_fails_on_unexpected_typed_error():
    world = _world()
    case = make_case(topCandidateId="youtube:a")
    result = make_result(error=AssemblyError(code="ARM_ERROR", message="boom"))
    grades = _grade(case, result, world)
    assert grades[g.SCHEMA].passed is False


def test_grounding_grader_fails_on_ungrounded_candidate():
    world = _world()
    case = make_case()
    result = make_result(recommendations=[make_recommendation("youtube:ghost", 1)])
    grades = _grade(case, result, world)
    assert grades[g.GROUNDING].passed is False


def test_safety_grader_fails_on_url():
    world = _world()
    case = make_case()
    rec = make_recommendation("youtube:a", 1, rationale="grab it at https://x.test/y")
    result = make_result(recommendations=[rec])
    grades = _grade(case, result, world)
    assert grades[g.SAFETY].passed is False


def test_expected_grader_fails_on_wrong_top():
    world = _world()
    case = make_case(topCandidateId="youtube:b")
    result = make_result(recommendations=[make_recommendation("youtube:a", 1)])
    grades = _grade(case, result, world)
    assert grades[g.EXPECTED].passed is False


def test_expected_grader_checks_required_warnings():
    world = _world()
    case = make_case(requiredWarnings={"youtube:b": ["live"]})
    recs = [
        make_recommendation("youtube:a", 1),
        make_recommendation("youtube:b", 2, classification="live", warnings=["duration_mismatch"]),
    ]
    result = make_result(recommendations=recs)
    grades = _grade(case, result, world)
    assert grades[g.EXPECTED].passed is False  # missing "live" warning


def test_expected_grader_platform_enforced():
    world = make_world(
        candidates=[make_candidate("youtube:a", title="Artist - Song", durationMs=200000)]
    )
    case = make_case(platform=["soundcloud"])
    result = make_result(recommendations=[make_recommendation("youtube:a", 1)])
    grades = _grade(case, result, world)
    assert grades[g.EXPECTED].passed is False


def test_claims_grader_fails_on_ungrounded_action():
    world = _world()
    case = make_case(topCandidateId="youtube:a")
    rec = make_recommendation("youtube:a", 1, rationale="I downloaded and listened to it; sounds clean.")
    result = make_result(recommendations=[rec])
    grades = _grade(case, result, world)
    assert grades[g.CLAIMS].passed is False


def test_claims_grader_allows_tool_grounded_phrasing():
    world = _world()
    case = make_case(topCandidateId="youtube:a")
    rec = make_recommendation("youtube:a", 1, rationale="Official audio on the topic channel; duration matches catalog.")
    result = make_result(recommendations=[rec])
    grades = _grade(case, result, world)
    assert grades[g.CLAIMS].passed is True


def test_budget_grader_fails_when_spent_over_ceiling():
    world = _world()
    case = make_case(topCandidateId="youtube:a")
    result = make_result(
        recommendations=[make_recommendation("youtube:a", 1)],
        trace_len=1,
        budgetSpent=BudgetSpent(toolCalls=99, modelCalls=0, elapsedMs=0),
    )
    grades = _grade(case, result, world)
    assert grades[g.BUDGET].passed is False


def test_expected_grader_min_unresolved():
    world = _world()
    case = make_case(topCandidateId="youtube:a", minUnresolved=1)
    result = make_result(recommendations=[make_recommendation("youtube:a", 1)], unresolved=[])
    grades = _grade(case, result, world)
    assert grades[g.EXPECTED].passed is False
