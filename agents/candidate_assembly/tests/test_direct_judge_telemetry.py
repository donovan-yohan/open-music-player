from __future__ import annotations

from candidate_assembly.arms.direct_judge import DirectJudgeArm
from candidate_assembly.budgets import Budget
from candidate_assembly.model_client import (
    ModelAttempt,
    ModelConfig,
    StructuredOutputError,
    StructuredResult,
)
from candidate_assembly.schemas import CaseInput
from conftest import make_world


def _prepare(monkeypatch):
    import candidate_assembly.arms.direct_judge as direct_mod

    monkeypatch.setattr(
        direct_mod.ModelConfig,
        "from_env",
        classmethod(lambda cls: ModelConfig("http://example.test", "key", "test-model")),
    )
    monkeypatch.setattr(direct_mod, "build_openai_client", lambda _config: object())
    monkeypatch.setattr(direct_mod, "make_json_object_chat", lambda *_args: lambda _messages: "")
    monkeypatch.setattr(
        direct_mod.go_ranker,
        "rank",
        lambda _prompt, candidates: [
            {
                **candidate,
                "metadata": {"sourceQuality": {"score": 80, "classification": "official_audio"}},
            }
            for candidate in candidates
        ],
    )
    return direct_mod


def test_direct_judge_one_call_budget_disables_repair_and_records_attempt(monkeypatch):
    direct_mod = _prepare(monkeypatch)
    repairs: list[int] = []

    def fake_complete(_chat, _messages, schema, **kwargs):
        repairs.append(kwargs["max_repair"])
        return StructuredResult(
            value=schema(judgments=[]), calls_used=1,
            attempts=[ModelAttempt(1, 7, False, "success")],
        )

    monkeypatch.setattr(direct_mod, "complete_structured", fake_complete)
    arm = DirectJudgeArm()
    result = arm.assemble(CaseInput(prompt="artist song"), make_world(), Budget(max_model_calls=1))

    assert repairs == [0]
    assert result.budgetSpent.modelCalls == 1
    assert [(attempt.attempt, attempt.status) for attempt in arm.model_attempts] == [(1, "success")]
    assert arm.tool_dispatch_latency_ms >= 0
    assert [event.phase for event in arm.progress_events][:2] == ["started", "tool_completed"]


def test_direct_judge_structured_failure_preserves_attempts_and_safe_failure(monkeypatch):
    direct_mod = _prepare(monkeypatch)

    def fake_complete(*_args, **_kwargs):
        raise StructuredOutputError(
            "raw completion text must not escape",
            calls_used=1,
            attempts=[ModelAttempt(1, 9, False, "parse_error")],
        )

    monkeypatch.setattr(direct_mod, "complete_structured", fake_complete)
    arm = DirectJudgeArm()
    result = arm.assemble(CaseInput(prompt="artist song"), make_world(), Budget(max_model_calls=1))

    assert result.error and result.error.code == "STRUCTURED_OUTPUT_ERROR"
    assert result.budgetSpent.modelCalls == 1
    assert len(result.trace) == 2
    assert [(attempt.duration_ms, attempt.status) for attempt in arm.model_attempts] == [(9, "parse_error")]
    assert "raw completion" not in str(arm.progress_events)


def test_direct_judge_config_failure_emits_started_then_failed(monkeypatch):
    import candidate_assembly.arms.direct_judge as direct_mod

    monkeypatch.setattr(
        direct_mod.ModelConfig, "from_env", classmethod(lambda cls: (_ for _ in ()).throw(ValueError("key")))
    )
    arm = DirectJudgeArm()
    result = arm.assemble(CaseInput(prompt="artist song"), make_world(), Budget.default())
    assert result.error and result.error.code == "MODEL_CONFIG_ERROR"
    assert [(event.phase, event.status) for event in arm.progress_events] == [
        ("started", None), ("failed", "failed")
    ]
