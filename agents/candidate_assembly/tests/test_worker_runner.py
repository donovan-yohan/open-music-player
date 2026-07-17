"""Network-free protocol tests for the durable JSONL worker command."""

from __future__ import annotations

import io
import json

import pytest

import candidate_assembly.arms.deep_agent as deep_mod
import candidate_assembly.worker_runner as runner
from candidate_assembly.model_client import (
    ModelAttempt,
    ModelConfig,
    StructuredOutputError,
    StructuredResult,
)
from candidate_assembly.budgets import Budget
from candidate_assembly.schemas import (
    AgentAction,
    AgentFinalOutput,
    BudgetSpent,
    Recommendation,
    WorkerDegradation,
    WorkerRevision,
    WorkerTerminal,
)
from conftest import make_result


def _request(*, direct: bool = True, deep: bool = False) -> dict:
    return {
        "schemaVersion": "omp.agent-search.worker.request.v1",
        "jobId": "job:273",
        "runId": "run:1",
        "query": "Artist Song",
        "limit": 2,
        "candidates": [
            {
                "candidateId": "youtube:a",
                "provider": "youtube",
                "title": "Artist - Song (Official Audio)",
                "artist": "Artist",
                "downloadable": True,
                "durationMs": 200000,
                "sourceQuality": {
                    "score": 92,
                    "classification": "official_audio",
                    "warnings": [],
                },
            },
            {
                "candidateId": "youtube:b",
                "provider": "youtube",
                "title": "Artist - Song (Live)",
                "artist": "Artist",
                "downloadable": True,
                "durationMs": 230000,
                "sourceQuality": {
                    "score": 70,
                    "classification": "live",
                    "warnings": ["live"],
                },
            },
        ],
        "catalog": [
            {
                "kind": "track",
                "id": "catalog:artist-song",
                "title": "Artist - Song",
                "artist": "Artist",
                "durationMs": 200000,
                "score": 100,
            }
        ],
        "metadata": {},
        "budgets": {
            "maxToolCalls": 8,
            "maxModelCalls": 4,
            "recursionLimit": 8,
            "maxCandidatesIn": 8,
            "maxRecommendations": 2,
            "wallClockMs": 10000,
            "maxRequestBytes": 8192,
            "maxResponseBytes": 16384,
            "maxTokensPerCompletion": 512,
        },
        "stages": {"directJudge": direct, "deepAgent": deep},
    }


def _stream(payload: dict) -> tuple[int, list[dict], str]:
    output = io.StringIO()
    exit_code = runner.run_stream(io.StringIO(json.dumps(payload) + "\n"), output)
    raw = output.getvalue()
    return exit_code, [json.loads(line) for line in raw.splitlines()], raw


def _config(monkeypatch):
    monkeypatch.setattr(
        runner,
        "_load_model_config",
        lambda: ModelConfig("http://example.test", "test-key", "fake-model"),
    )
    monkeypatch.setattr(runner, "build_openai_client", lambda _config: object())
    monkeypatch.setattr(runner, "make_json_object_chat", lambda *_args: lambda _m: "")
    monkeypatch.setattr(deep_mod, "build_openai_client", lambda _config: object())
    monkeypatch.setattr(deep_mod, "make_json_object_chat", lambda *_args: lambda _m: "")


def _direct_success(_chat, _messages, schema, **kwargs):
    attempt = ModelAttempt(1, 17, False, "success")
    kwargs["attempt_callback"](attempt)
    return StructuredResult(
        value=schema(judgments=[{"candidateId": "youtube:a", "score": 100, "reason": "Best audio."}]),
        calls_used=1,
        attempts=[attempt],
    )


def _deep_success():
    calls = 0

    def complete(_chat, _messages, schema, **kwargs):
        nonlocal calls
        calls += 1
        attempt = ModelAttempt(1, 9, False, "success")
        kwargs["attempt_callback"](attempt)
        if schema is AgentAction:
            return StructuredResult(
                value=AgentAction(action="search_sources", args={"query": "Artist Song"}),
                calls_used=1,
                attempts=[attempt],
            )
        return StructuredResult(
            value=AgentFinalOutput(
                interpretedIntent={"notes": "snapshot result"},
                recommendations=[
                    Recommendation(
                        candidateId="youtube:a",
                        rank=1,
                        confidence=0.9,
                        rationale="Official audio.",
                        evidence=[],
                        warnings=[],
                    )
                ],
            ),
            calls_used=1,
            attempts=[attempt],
        )

    return complete


def test_direct_only_emits_valid_revision_then_terminal_and_timing(monkeypatch):
    _config(monkeypatch)
    monkeypatch.setattr(runner, "complete_structured", _direct_success)

    exit_code, records, _raw = _stream(_request())

    assert exit_code == 0
    assert [record["recordType"] for record in records] == ["revision", "terminal"]
    revision = WorkerRevision.model_validate(records[0])
    terminal = WorkerTerminal.model_validate(records[1])
    assert revision.stage == "direct_judge"
    assert [item.durationMs for item in revision.timing.modelAttempts] == [17]
    assert terminal.outcome == "completed"
    assert terminal.timing.requestAcceptedToDirectFirstRevisionMs is not None
    assert terminal.timing.requestAcceptedToFinalMs >= 0
    assert terminal.timing.toolCalls == 2
    assert [(item.stage, item.durationMs) for item in terminal.timing.modelAttempts] == [
        ("direct_judge", 17)
    ]


def test_progressive_direct_then_deep_order(monkeypatch):
    _config(monkeypatch)
    monkeypatch.setattr(runner, "complete_structured", _direct_success)
    monkeypatch.setattr(deep_mod, "complete_structured", _deep_success())

    exit_code, records, _raw = _stream(_request(direct=True, deep=True))

    assert exit_code == 0
    assert [(record["recordType"], record.get("stage")) for record in records] == [
        ("revision", "direct_judge"),
        ("revision", "deep_agent"),
        ("terminal", None),
    ]
    assert records[-1]["outcome"] == "completed"


def test_global_budget_allows_combined_stages_only_within_exact_remaining_capacity(monkeypatch):
    _config(monkeypatch)
    monkeypatch.setattr(runner, "complete_structured", _direct_success)
    monkeypatch.setattr(deep_mod, "complete_structured", _deep_success())
    payload = _request(direct=True, deep=True)
    payload["budgets"]["maxModelCalls"] = 3  # direct=1, deep action+final=2
    payload["budgets"]["maxToolCalls"] = 3  # direct=2, deep search=1

    exit_code, records, _raw = _stream(payload)

    assert exit_code == 0
    assert [record["recordType"] for record in records] == ["revision", "revision", "terminal"]
    terminal = WorkerTerminal.model_validate(records[-1])
    assert terminal.outcome == "completed"
    assert terminal.timing.toolCalls == 3
    assert len(terminal.timing.modelAttempts) == 3
    assert terminal.timing.toolCalls <= payload["budgets"]["maxToolCalls"]
    assert len(terminal.timing.modelAttempts) <= payload["budgets"]["maxModelCalls"]


def test_global_budget_skips_deep_after_direct_exhausts_remaining_capacity(monkeypatch):
    _config(monkeypatch)
    monkeypatch.setattr(runner, "complete_structured", _direct_success)
    deep_called = False

    def should_not_run(*_args, **_kwargs):
        nonlocal deep_called
        deep_called = True
        raise AssertionError("DeepAgent must not start after aggregate exhaustion")

    monkeypatch.setattr(deep_mod, "complete_structured", should_not_run)
    payload = _request(direct=True, deep=True)
    payload["budgets"]["maxModelCalls"] = 1
    payload["budgets"]["maxToolCalls"] = 2

    exit_code, records, _raw = _stream(payload)

    assert exit_code == 0
    assert [record["recordType"] for record in records] == ["revision", "terminal"]
    assert records[0]["stage"] == "direct_judge"
    terminal = WorkerTerminal.model_validate(records[-1])
    assert not deep_called
    assert terminal.outcome == "degraded"
    assert terminal.degradations == [
        WorkerDegradation(stage="deep_agent", code="BUDGET_EXCEEDED")
    ]
    assert terminal.timing.toolCalls == 2
    assert len(terminal.timing.modelAttempts) == 1


def test_request_acceptance_timing_starts_after_stdin_validation(monkeypatch):
    _config(monkeypatch)
    clock_values = iter([101.0, 104.0, 104.0, 104.0, 104.0, 106.0, 110.0])
    monkeypatch.setattr(runner, "_now", lambda: next(clock_values))
    monkeypatch.setattr(runner, "_PROCESS_STARTED", 100.0)
    direct_result = make_result(
        arm="direct_judge",
        trace_len=2,
        budgetSpent=BudgetSpent(toolCalls=2, modelCalls=1),
    )
    direct_stage = runner.StageRun(
        direct_result,
        [ModelAttempt(1, 7, False, "success")],
        2,
        20,
        30,
        0,
    )
    monkeypatch.setattr(runner, "_run_direct", lambda *_args: direct_stage)

    exit_code, records, _raw = _stream(_request())

    assert exit_code == 0
    terminal = WorkerTerminal.model_validate(records[-1])
    assert terminal.timing.processStartupToRequestAcceptedMs == 4000
    assert terminal.timing.requestAcceptedToDirectFirstRevisionMs == 2000
    assert terminal.timing.requestAcceptedToFinalMs == 6000


def test_request_budget_ledger_uses_one_deadline_before_later_stage(monkeypatch):
    now = [10.0]
    monkeypatch.setattr(runner, "_now", lambda: now[0])
    ledger = runner.RequestBudgetLedger(Budget.default(), request_started_at=10.0)

    assert ledger.can_start(min_tool_calls=1, min_model_calls=1)
    now[0] = 190.0
    assert not ledger.can_start(min_tool_calls=1, min_model_calls=1)


def test_request_budget_ledger_debits_calls_and_tool_bytes_across_stages(monkeypatch):
    monkeypatch.setattr(runner, "_now", lambda: 0.0)
    ledger = runner.RequestBudgetLedger(
        Budget(
            max_tool_calls=3,
            max_model_calls=2,
            max_request_bytes=100,
            max_response_bytes=200,
        ),
        request_started_at=0.0,
    )
    ledger.consume(
        runner.StageRun(
            None,
            [ModelAttempt(1, 1, False, "success")],
            2,
            40,
            60,
            0,
        )
    )

    remaining = ledger.remaining_budget()
    assert remaining.max_tool_calls == 1
    assert remaining.max_model_calls == 1
    assert remaining.max_request_bytes == 60
    assert remaining.max_response_bytes == 140


def test_wall_deadline_between_stages_preserves_direct_revision_and_skips_deep(monkeypatch):
    _config(monkeypatch)
    now = [0.0]
    monkeypatch.setattr(runner, "_now", lambda: now[0])
    monkeypatch.setattr(runner, "_PROCESS_STARTED", 0.0)
    direct_stage = runner.StageRun(
        make_result(
            arm="direct_judge",
            trace_len=2,
            budgetSpent=BudgetSpent(toolCalls=2, modelCalls=1),
        ),
        [ModelAttempt(1, 1, False, "success")],
        2,
        20,
        30,
        0,
    )
    monkeypatch.setattr(runner, "_run_direct", lambda *_args: direct_stage)
    original_write = runner._write_record

    def write_then_advance(output, record):
        original_write(output, record)
        if isinstance(record, WorkerRevision):
            now[0] = 2.0

    monkeypatch.setattr(runner, "_write_record", write_then_advance)
    payload = _request(direct=True, deep=True)
    payload["budgets"]["wallClockMs"] = 1000

    exit_code, records, _raw = _stream(payload)

    assert exit_code == 0
    assert [record["recordType"] for record in records] == ["revision", "terminal"]
    assert records[0]["stage"] == "direct_judge"
    assert records[1]["degradations"] == [
        {"stage": "deep_agent", "code": "BUDGET_EXCEEDED"}
    ]


def test_allowlist_rejection_degrades_without_revision(monkeypatch):
    _config(monkeypatch)

    def unknown_final(_chat, _messages, schema, **kwargs):
        attempt = ModelAttempt(1, 3, False, "success")
        kwargs["attempt_callback"](attempt)
        if schema is AgentAction:
            return StructuredResult(
                value=AgentAction(action="finalize"), calls_used=1, attempts=[attempt]
            )
        return StructuredResult(
            value=AgentFinalOutput(
                interpretedIntent={"notes": "bad id"},
                recommendations=[
                    Recommendation(
                        candidateId="youtube:invented",
                        rank=1,
                        confidence=0.8,
                        rationale="Unknown.",
                    )
                ],
            ),
            calls_used=1,
            attempts=[attempt],
        )

    monkeypatch.setattr(deep_mod, "complete_structured", unknown_final)
    exit_code, records, _raw = _stream(_request(direct=False, deep=True))

    assert exit_code == 0
    assert len(records) == 1
    assert records[0]["outcome"] == "degraded"
    assert records[0]["degradations"] == [{"stage": "deep_agent", "code": "VALIDATION_FAILED"}]


def test_redacts_invalid_model_reason_from_terminal(monkeypatch):
    _config(monkeypatch)

    def unsafe_reason(_chat, _messages, schema, **kwargs):
        attempt = ModelAttempt(1, 2, False, "success")
        kwargs["attempt_callback"](attempt)
        return StructuredResult(
            value=schema(judgments=[{"candidateId": "youtube:a", "score": 99, "reason": "https://secret.example"}]),
            calls_used=1,
            attempts=[attempt],
        )

    monkeypatch.setattr(runner, "complete_structured", unsafe_reason)
    _exit_code, records, raw = _stream(_request())

    assert len(records) == 1
    assert records[0]["degradations"][0]["code"] == "VALIDATION_FAILED"
    assert "https://" not in raw


def test_unbounded_deep_output_degrades_before_projection(monkeypatch):
    _config(monkeypatch)

    def oversized_final(_chat, _messages, schema, **kwargs):
        attempt = ModelAttempt(1, 4, False, "success")
        kwargs["attempt_callback"](attempt)
        if schema is AgentAction:
            return StructuredResult(
                value=AgentAction(action="finalize"), calls_used=1, attempts=[attempt]
            )
        return StructuredResult(
            value=AgentFinalOutput(
                interpretedIntent={"notes": "safe"},
                unresolved=["safe" for _ in range(9)],
            ),
            calls_used=1,
            attempts=[attempt],
        )

    monkeypatch.setattr(deep_mod, "complete_structured", oversized_final)
    _exit_code, records, _raw = _stream(_request(direct=False, deep=True))

    assert len(records) == 1
    assert records[0]["degradations"] == [
        {"stage": "deep_agent", "code": "VALIDATION_FAILED"}
    ]


def test_disabled_model_emits_predictable_unavailable_terminal(monkeypatch):
    monkeypatch.delenv("OMP_CANDIDATE_WORKER_LIVE", raising=False)

    exit_code, records, _raw = _stream(_request())

    assert exit_code == 0
    assert len(records) == 1
    terminal = WorkerTerminal.model_validate(records[0])
    assert terminal.outcome == "unavailable"
    assert terminal.degradations == [WorkerDegradation(stage="direct_judge", code="MODEL_DISABLED")]


def test_direct_success_is_preserved_when_deep_fails(monkeypatch):
    _config(monkeypatch)
    monkeypatch.setattr(runner, "complete_structured", _direct_success)

    def deep_failure(_chat, _messages, _schema, **kwargs):
        attempt = ModelAttempt(1, 6, False, "parse_error")
        kwargs["attempt_callback"](attempt)
        raise StructuredOutputError("raw model output", calls_used=1, attempts=[attempt])

    monkeypatch.setattr(deep_mod, "complete_structured", deep_failure)
    exit_code, records, _raw = _stream(_request(direct=True, deep=True))

    assert exit_code == 0
    assert [record["recordType"] for record in records] == ["revision", "terminal"]
    assert records[0]["stage"] == "direct_judge"
    assert records[1]["outcome"] == "degraded"
    assert records[1]["degradations"] == [
        {"stage": "deep_agent", "code": "STRUCTURED_OUTPUT_ERROR"}
    ]


def test_protocol_rejects_url_field_and_cancellation_writes_no_partial_json(monkeypatch):
    payload = _request()
    payload["candidates"][0]["sourceUrl"] = "https://forbidden.example"
    exit_code, records, raw = _stream(payload)
    assert exit_code == 2
    assert len(records) == 1
    assert records[0]["outcome"] == "invalid_request"
    assert "https://" not in raw

    _config(monkeypatch)
    monkeypatch.setattr(runner, "_run_direct", lambda *_args: (_ for _ in ()).throw(runner.WorkerCancelled()))
    output = io.StringIO()
    assert runner.run_stream(io.StringIO(json.dumps(_request()) + "\n"), output) == 143
    records = [json.loads(line) for line in output.getvalue().splitlines()]
    assert len(records) == 1
    assert records[0]["outcome"] == "cancelled"
    WorkerTerminal.model_validate(records[0])
