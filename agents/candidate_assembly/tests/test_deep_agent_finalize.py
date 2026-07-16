"""Unit tests for the deep_agent finalize-step message construction.

Network-free: ``_finalize_messages`` is pure. It guards the failure observed in
live recording — the model, primed by the action-loop assistant turns, emitting
another ``{"action", "args"}`` object at finalize instead of AgentFinalOutput.
"""

from __future__ import annotations

from candidate_assembly.arms.deep_agent import (
    _FINALIZE_INSTRUCTION,
    _finalize_messages,
)
from candidate_assembly.schemas import AgentAction, AgentFinalOutput
from candidate_assembly.model_client import schema_prompt


def _prior() -> list[dict]:
    return [
        {"role": "system", "content": "SYS: " + schema_prompt(AgentAction)},
        {"role": "user", "content": '{"prompt": "play x", "limit": 5}'},
        {"role": "assistant", "content": '{"action": "search_sources", "args": {}}'},
        {"role": "user", "content": '{"observation": []}'},
    ]


def test_finalize_pins_final_schema_and_drops_action_system():
    prior = _prior()
    msgs = _finalize_messages(prior)
    # System turn is replaced with the AgentFinalOutput schema, not AgentAction's.
    assert msgs[0]["role"] == "system"
    assert schema_prompt(AgentFinalOutput) in msgs[0]["content"]
    assert schema_prompt(AgentAction) not in msgs[0]["content"]
    # The original system turn is dropped; gathered observations are preserved.
    assert msgs[1:1 + len(prior[1:])] == prior[1:]


def test_finalize_instruction_forbids_action_shape():
    msgs = _finalize_messages(_prior())
    last = msgs[-1]
    assert last["role"] == "user"
    assert last["content"] == _FINALIZE_INSTRUCTION
    lowered = _FINALIZE_INSTRUCTION.lower()
    # Explicitly closes the tool phase and forbids the action envelope shape.
    assert "action" in lowered and "args" in lowered
    # Names the exact required top-level keys so the model switches shapes.
    assert "interpretedIntent" in _FINALIZE_INSTRUCTION
    assert "recommendations" in _FINALIZE_INSTRUCTION
    assert "unresolved" in _FINALIZE_INSTRUCTION


def test_finalize_does_not_mutate_prior():
    prior = _prior()
    snapshot = [dict(m) for m in prior]
    _finalize_messages(prior)
    assert prior == snapshot
