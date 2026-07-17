from __future__ import annotations

from candidate_assembly.budgets import Budget
from candidate_assembly.evalrunner import runner as runner_mod
from candidate_assembly.model_client import ModelAttempt
from candidate_assembly.schemas import (
    AssemblyError,
    BudgetSpent,
    Evidence,
    ProgressEvent,
    Provenance,
)
from conftest import make_case, make_result, make_world


class _BaselineArm:
    name = "deterministic"

    def assemble(self, _case_input, _world, _budget):
        self.allowlist = {"youtube:a"}
        self.tool_dispatch_latency_ms = 3
        self.model_attempts = []
        self.progress_events = []
        self.finalization_ms = None
        return make_result(arm=self.name)


class _FailingModelArm:
    name = "deep_agent"

    def assemble(self, _case_input, _world, _budget):
        self.allowlist = {"youtube:a"}
        self.tool_dispatch_latency_ms = 5
        self.model_attempts = [ModelAttempt(1, 11, False, "transport_error")]
        self.finalization_ms = 11
        self.progress_events = [
            ProgressEvent(sequence=1, kind="lifecycle", phase="started", elapsedMs=0),
            ProgressEvent(
                sequence=2, kind="lifecycle", phase="model_call", elapsedMs=11,
                attempt=1, repair=False, status="transport_error",
            ),
            ProgressEvent(sequence=3, kind="lifecycle", phase="failed", elapsedMs=11, status="failed"),
        ]
        return make_result(
            arm=self.name,
            recommendations=[],
            budgetSpent=BudgetSpent(toolCalls=1, modelCalls=1),
            provenance=Provenance(orchestrator="fake", model="test", toolTransport="structured_action"),
            error=AssemblyError(code="MODEL_FAILURE", message="safe failure"),
        )


def test_live_model_artifact_runs_validated_baseline_before_model_and_retains_it(monkeypatch):
    calls: list[str] = []

    def fake_build(name):
        calls.append(name)
        return _BaselineArm() if name == "deterministic" else _FailingModelArm()

    monkeypatch.setattr(runner_mod, "build_arm", fake_build)
    case = make_case("case1")
    world = make_world()
    cfg = runner_mod.RunConfig(
        mode="live", arms=["deep_agent"], run_id="baseline", model="test",
        prompt_revision="test", budget=Budget.default(),
    )
    outcome = runner_mod.run_case_arm(case, world, "deep_agent", cfg)

    assert calls == ["deterministic", "deep_agent"]
    assert outcome.deterministic_baseline is not None
    assert outcome.deterministic_baseline.candidateIds == ["youtube:a"]
    assert outcome.result and outcome.result.error and outcome.result.error.code == "MODEL_FAILURE"
    assert [event.sequence for event in outcome.progress_events] == list(
        range(1, len(outcome.progress_events) + 1)
    )
    assert outcome.progress_events[0].phase == "baseline_validated"
    assert outcome.telemetry.firstPartialRevisionMs is None
    assert outcome.progress_events[-1].phase == "validated"
    assert outcome.progress_events[-1].status == "failed"
    assert outcome.telemetry.toolDispatchLatencyMs == 5

    records = runner_mod.build_records([outcome], cfg)
    payload = records[1]
    assert payload["deterministicBaseline"]["candidateIds"] == ["youtube:a"]
    assert "firstPartialRevisionMs" not in payload["telemetry"]
    rendered = str(payload["deterministicBaseline"]) + str(payload["progressEvents"])
    assert not any(value in rendered.lower() for value in ("prompt", "http", "reasoning", "secret"))


class _BrokenBaselineArm:
    name = "deterministic"

    def assemble(self, _case_input, _world, _budget):
        raise RuntimeError("Bearer secret-do-not-record")


def test_typed_baseline_error_emits_failed_event_without_refs(monkeypatch):
    def fake_build(name):
        return _BrokenBaselineArm() if name == "deterministic" else _FailingModelArm()

    monkeypatch.setattr(runner_mod, "build_arm", fake_build)
    cfg = runner_mod.RunConfig(
        mode="live", arms=["deep_agent"], run_id="baseline-error", model="test",
        prompt_revision="test", budget=Budget.default(),
    )
    outcome = runner_mod.run_case_arm(make_case("case1"), make_world(), "deep_agent", cfg)
    assert outcome.deterministic_baseline is not None
    assert outcome.deterministic_baseline.candidateIds == []
    assert outcome.deterministic_baseline.evidenceRefs == []
    assert outcome.progress_events[0].phase == "failed"
    assert outcome.progress_events[0].candidateIds == []
    assert outcome.progress_events[0].evidenceRefs == []


def test_safe_baseline_extractors_filter_unsafe_candidate_and_evidence_values():
    result = make_result()
    result.recommendations[0].candidateId = "https://example.test/not-an-id"
    result.recommendations[0].evidence = [
        Evidence(tool="search_sources", ref="Bearer-secret-value")
    ]
    assert runner_mod._safe_candidate_ids(result) == []
    assert runner_mod._safe_evidence_refs(result) == []
