from __future__ import annotations

import pytest

from candidate_assembly.budgets import Budget
from candidate_assembly.evalrunner import runner as runner_mod
from candidate_assembly.schemas import (
    ArmTelemetry,
    ModelCallAttempt,
    PROMPT_REVISION,
    PROGRESS_EVENT_SCHEMA_VERSION,
    ProgressEvent,
    RUN_SCHEMA_VERSION,
)
from conftest import make_result
from conftest import make_case, make_world


def _read(path):
    return path.read_text()


# --- Finding 3: artifact api_key literal-redaction min-length guard ----------


def test_write_artifact_keeps_short_api_key_literal(tmp_path):
    out = tmp_path / "short.jsonl"
    # A 6-char "key" must NOT blanket-redact ordinary substrings (< 8 guard),
    # and it is not secret-shaped so the regex leaves it alone too.
    runner_mod.write_artifact(str(out), [{"note": "secret"}], api_key="secret")
    text = _read(out)
    assert "secret" in text
    assert "[REDACTED]" not in text


def test_write_artifact_redacts_long_api_key_literal(tmp_path):
    out = tmp_path / "long.jsonl"
    key = "abcdef123456"  # 12 chars, not secret-shaped, so only the literal path redacts it
    runner_mod.write_artifact(str(out), [{"note": key}], api_key=key)
    text = _read(out)
    assert key not in text
    assert "[REDACTED]" in text


def test_write_artifact_redacts_exactly_eight_char_key(tmp_path):
    out = tmp_path / "boundary.jsonl"
    key = "12345678"  # boundary: 8 chars is long enough to redact
    runner_mod.write_artifact(str(out), [{"note": key}], api_key=key)
    text = _read(out)
    assert key not in text
    assert "[REDACTED]" in text


# --- Finding 4: corrupted recording -> typed failure, not a raw crash --------


def test_load_recording_missing_returns_none(tmp_path, monkeypatch):
    missing = tmp_path / "nope.json"
    monkeypatch.setattr(runner_mod, "recording_path", lambda arm, cid, base=None: missing)
    assert runner_mod._load_recording("deep_agent", "case1") is None


def test_load_recording_corrupt_raises_typed_error(tmp_path, monkeypatch):
    bad = tmp_path / "corrupt.json"
    bad.write_text("{ this is not valid json ]")
    monkeypatch.setattr(runner_mod, "recording_path", lambda arm, cid, base=None: bad)
    with pytest.raises(runner_mod.CorruptRecordingError):
        runner_mod._load_recording("deep_agent", "case1")


def test_run_case_arm_grades_corrupt_model_recording_as_typed_error(
    tmp_path, monkeypatch, capsys
):
    bad = tmp_path / "corrupt.json"
    bad.write_text("{ broken json")
    monkeypatch.setattr(runner_mod, "recording_path", lambda arm, cid, base=None: bad)

    case = make_case("case1")
    world = make_world()
    cfg = runner_mod.RunConfig(
        mode="replay",
        arms=["direct_judge"],
        run_id="corrupt-test",
        model="replay",
        prompt_revision=PROMPT_REVISION,
        budget=Budget.default(),
    )
    outcome = runner_mod.run_case_arm(case, world, "direct_judge", cfg)

    # Corrupted recording is graded (typed error), not silently skipped and not a crash.
    assert outcome.status == runner_mod.STATUS_GRADED
    assert outcome.passed is False
    assert outcome.parse_error and "CorruptRecordingError" in outcome.parse_error
    # A distinct warning is printed for the corrupted (vs missing) case.
    assert "corrupted recording" in capsys.readouterr().err


def test_case_artifact_serializes_typed_safe_ordered_progress_events(tmp_path):
    outcome = runner_mod.CaseArmOutcome(
        case_id="case1",
        arm="deep_agent",
        status=runner_mod.STATUS_GRADED,
        passed=True,
        latency_ms=42,
        result=make_result(arm="deep_agent"),
        telemetry=ArmTelemetry(
            startupProbeMs=7,
            modelAttempts=[ModelCallAttempt(attempt=1, durationMs=12, repair=False, status="success")],
            toolDispatchLatencyMs=4,
            finalizationMs=10,
            validationMs=2,
            totalArmWallMs=42,
            timeToFirstUsefulValidatedResultMs=44,
        ),
        progress_events=[
            ProgressEvent(sequence=1, kind="lifecycle", phase="started", elapsedMs=0),
            ProgressEvent(
                sequence=2,
                kind="validated_result",
                phase="validated",
                elapsedMs=44,
                status="passed",
                resultCount=1,
            ),
        ],
    )
    cfg = runner_mod.RunConfig(
        mode="live", arms=["deep_agent"], run_id="telemetry-test", model="test",
        prompt_revision=PROMPT_REVISION, budget=Budget.default(),
    )
    records = runner_mod.build_records([outcome], cfg)
    case = records[1]
    assert case["schemaVersion"] == RUN_SCHEMA_VERSION
    assert RUN_SCHEMA_VERSION == "omp.agent-search.eval.run.v4"
    assert case["telemetry"]["modelAttempts"][0]["durationMs"] == 12
    assert [event["sequence"] for event in case["progressEvents"]] == [1, 2]
    assert {event["schemaVersion"] for event in case["progressEvents"]} == {
        PROGRESS_EVENT_SCHEMA_VERSION
    }
    assert PROGRESS_EVENT_SCHEMA_VERSION == "omp.agent-search.eval.progress.v2"
    rendered = str(case)
    assert not any(forbidden in rendered.lower() for forbidden in ("prompt", "reasoning", "http", "key"))
    out = tmp_path / "telemetry.jsonl"
    runner_mod.write_artifact(str(out), records, api_key="abcdef123456")
    assert "abcdef123456" not in out.read_text()


def test_write_artifact_redacts_urls_jwts_and_named_gateway_tokens(tmp_path):
    out = tmp_path / "leaks.jsonl"
    leaked = {
        "url": "https://provider.example/watch?v=private",
        "note": "Bearer capability-opaque-token",
        "jwt": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature-token",
        "serviceToken": "service-token-never-recorded",
        "nested": {"firecrawlKey": "fc-private-key-123456"},
    }
    runner_mod.write_artifact(str(out), [leaked])
    rendered = out.read_text()
    for secret in (
        "provider.example",
        "capability-opaque-token",
        "eyJhbGciOiJIUzI1NiJ9",
        "service-token-never-recorded",
        "fc-private-key-123456",
    ):
        assert secret not in rendered
    assert "[REDACTED]" in rendered
