"""Unit tests for the deep_agent finalize-step message construction.

Network-free: ``_finalize_messages`` is pure. It guards the failure observed in
live recording — the model, primed by the action-loop assistant turns, emitting
another ``{"action", "args"}`` object at finalize instead of AgentFinalOutput.
"""

from __future__ import annotations

from candidate_assembly.arms.deep_agent import (
    DeepAgentArm,
    _FINALIZE_INSTRUCTION,
    _finalize_messages,
)
from candidate_assembly.budgets import Budget
from candidate_assembly.model_client import (
    ModelAttempt,
    ModelConfig,
    StructuredOutputError,
    StructuredResult,
    schema_prompt,
)
from candidate_assembly.schemas import AgentAction, AgentFinalOutput, CaseInput
from conftest import make_world


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
    assert msgs[1:3] == prior[1:3]
    assert prior[-1]["content"] in msgs[-1]["content"]
    assert _FINALIZE_INSTRUCTION in msgs[-1]["content"]
    _assert_alternating(msgs)


def test_finalize_instruction_forbids_action_shape():
    msgs = _finalize_messages(_prior())
    last = msgs[-1]
    assert last["role"] == "user"
    assert _FINALIZE_INSTRUCTION in last["content"]
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


def test_finalize_adds_user_instruction_after_prior_assistant_turn():
    prior = _prior()[:-1]
    msgs = _finalize_messages(prior)
    assert msgs[-1] == {"role": "user", "content": _FINALIZE_INSTRUCTION}
    _assert_alternating(msgs)


def test_finalize_merges_instruction_with_prior_user_observation():
    prior = _prior()
    msgs = _finalize_messages(prior)
    assert msgs[-1]["role"] == "user"
    assert msgs[-1]["content"].startswith('{"observation": []}')
    assert _FINALIZE_INSTRUCTION in msgs[-1]["content"]
    _assert_alternating(msgs)


def test_finalize_accepts_history_without_an_original_system_turn():
    prior = _prior()[1:-1]
    msgs = _finalize_messages(prior)
    assert msgs[1:3] == prior
    assert msgs[-1]["role"] == "user"
    _assert_alternating(msgs)


def test_native_transport_is_typed_unsupported_before_model_initialization(monkeypatch):
    import candidate_assembly.arms.deep_agent as deep_mod

    monkeypatch.setenv("AGENT_SEARCH_TOOL_TRANSPORT", "native")
    monkeypatch.setattr(
        deep_mod.ModelConfig,
        "from_env",
        classmethod(lambda cls: (_ for _ in ()).throw(AssertionError("must not initialize"))),
    )
    arm = DeepAgentArm()
    result = arm.assemble(CaseInput(prompt="artist song"), make_world(), Budget.default())
    assert result.error and result.error.code == "UNSUPPORTED_TRANSPORT"
    assert result.provenance.toolTransport == "native"
    assert [(event.phase, event.status) for event in arm.progress_events] == [
        ("started", None), ("failed", "failed")
    ]


def test_action_and_finalize_respect_two_call_budget(monkeypatch):
    import candidate_assembly.arms.deep_agent as deep_mod

    monkeypatch.setattr(
        deep_mod.ModelConfig,
        "from_env",
        classmethod(lambda cls: ModelConfig("http://example.test", "key", "test-model")),
    )
    monkeypatch.setattr(deep_mod, "build_openai_client", lambda _config: object())
    monkeypatch.setattr(deep_mod, "make_json_object_chat", lambda *_args: lambda _messages: "")
    repair_budgets: list[int] = []

    def fake_complete(_chat, _messages, schema, **kwargs):
        repair_budgets.append(kwargs["max_repair"])
        if schema is AgentAction:
            return StructuredResult(
                value=AgentAction(action="finalize"), calls_used=1,
                attempts=[ModelAttempt(1, 1, False, "success")],
            )
        return StructuredResult(
            value=AgentFinalOutput(interpretedIntent={}), calls_used=1,
            attempts=[ModelAttempt(1, 1, False, "success")],
        )

    monkeypatch.setattr(deep_mod, "complete_structured", fake_complete)
    result = DeepAgentArm().assemble(
        CaseInput(prompt="play artist song"), make_world(), Budget(max_model_calls=2)
    )
    assert repair_budgets == [0, 0]
    assert result.budgetSpent.modelCalls == 2


def test_deep_agent_config_failure_emits_safe_started_then_failed(monkeypatch):
    import candidate_assembly.arms.deep_agent as deep_mod

    monkeypatch.setattr(
        deep_mod.ModelConfig, "from_env", classmethod(lambda cls: (_ for _ in ()).throw(ValueError("key")))
    )
    arm = DeepAgentArm()
    result = arm.assemble(CaseInput(prompt="artist song"), make_world(), Budget.default())
    assert result.error and result.error.code == "MODEL_CONFIG_ERROR"
    assert [(event.phase, event.status) for event in arm.progress_events] == [
        ("started", None), ("failed", "failed")
    ]


def _assert_alternating(messages: list[dict]) -> None:
    roles = [message["role"] for message in messages]
    assert roles[0] == "system"
    assert roles[1:] == ["user", "assistant", "user"][: len(roles) - 1]


def test_structured_failure_retains_spent_calls_partial_trace_and_safe_events(monkeypatch):
    import candidate_assembly.arms.deep_agent as deep_mod

    monkeypatch.setattr(
        deep_mod.ModelConfig,
        "from_env",
        classmethod(lambda cls: ModelConfig("http://example.test", "key", "test-model")),
    )
    monkeypatch.setattr(deep_mod, "build_openai_client", lambda _config: object())
    monkeypatch.setattr(deep_mod, "make_json_object_chat", lambda *_args: lambda _messages: "")
    calls = 0

    def fake_complete(_chat, _messages, schema, **_kwargs):
        nonlocal calls
        calls += 1
        if schema is AgentAction:
            return StructuredResult(
                value=AgentAction(action="search_sources", args={"query": "Artist Song"}),
                calls_used=1,
                attempts=[ModelAttempt(1, 12, False, "success")],
            )
        raise StructuredOutputError(
            "schema validation failed: secret model text",
            calls_used=1,
            attempts=[ModelAttempt(1, 8, False, "parse_error")],
        )

    monkeypatch.setattr(deep_mod, "complete_structured", fake_complete)
    arm = DeepAgentArm()
    result = arm.assemble(CaseInput(prompt="play artist song"), make_world(), Budget(max_model_calls=2))

    assert calls == 2
    assert result.error and result.error.code == "STRUCTURED_OUTPUT_ERROR"
    assert result.budgetSpent.modelCalls == 2
    assert result.budgetSpent.toolCalls == 1
    assert len(result.trace) == 1
    assert [(a.attempt, a.status) for a in arm.model_attempts] == [
        (1, "success"),
        (2, "parse_error"),
    ]
    assert [event.sequence for event in arm.progress_events] == list(
        range(1, len(arm.progress_events) + 1)
    )
    assert "secret" not in str(arm.progress_events)
    assert all(event.phase != "partial_revision" for event in arm.progress_events)
