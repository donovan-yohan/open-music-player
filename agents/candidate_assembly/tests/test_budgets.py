from __future__ import annotations

import pytest

from candidate_assembly.budgets import Budget, BudgetExceeded
from candidate_assembly.fixture_tools import ToolBox, ToolError
from candidate_assembly.schemas import AssemblyError, AssemblyResult, BudgetSpent, InterpretedIntent, Provenance
from conftest import make_candidate, make_world


def _box(**budget_overrides):
    world = make_world(
        candidates=[make_candidate(f"youtube:{i}", title="Artist - Song") for i in range(5)]
    )
    return ToolBox(world, Budget.default().with_overrides(**budget_overrides), now=lambda: 0.0)


def test_tool_call_ceiling_raises_budget_exceeded():
    box = _box(max_tool_calls=2)
    box.search_sources("artist song")
    box.search_sources("artist song")
    with pytest.raises(BudgetExceeded) as exc:
        box.search_sources("artist song")
    assert exc.value.code == "BUDGET_EXCEEDED"


def test_fake_tool_loop_converts_overflow_to_typed_failure():
    box = _box(max_tool_calls=3)
    error = None
    for _ in range(10):
        try:
            box.search_sources("artist song")
        except BudgetExceeded as exc:
            error = exc
            break
    assert error is not None
    # An arm converts the overflow into a typed-error AssemblyResult.
    result = AssemblyResult(
        arm="deep_agent",
        interpretedIntent=InterpretedIntent(notes="budget exceeded"),
        recommendations=[],
        trace=list(box.trace),
        budgetSpent=BudgetSpent(toolCalls=box.tool_calls),
        provenance=Provenance(orchestrator="deepagents-0.6.12"),
        error=AssemblyError(code=error.code, message=error.message),
    )
    assert result.error is not None
    assert result.error.code == "BUDGET_EXCEEDED"
    assert box.tool_calls == 3


def test_request_bytes_cap_raises():
    box = _box(max_request_bytes=32)
    with pytest.raises(BudgetExceeded):
        box.search_sources("x" * 1000)


def test_response_bytes_cap_raises():
    box = _box(max_response_bytes=8)
    with pytest.raises(BudgetExceeded):
        box.search_sources("artist song")


def test_unknown_candidate_raises_tool_error_and_counts_call():
    box = _box()
    with pytest.raises(ToolError):
        box.inspect_source_metadata("youtube:does-not-exist")
    assert box.tool_calls == 1
    assert box.trace[-1].tool == "inspect_source_metadata"
