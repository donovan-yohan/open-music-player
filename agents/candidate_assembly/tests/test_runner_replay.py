from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from candidate_assembly.budgets import Budget
from candidate_assembly.evalrunner import corpus as corpus_mod
from candidate_assembly.evalrunner import runner as runner_mod
from candidate_assembly.evalrunner.cli import main as cli_main
from candidate_assembly.schemas import PROMPT_REVISION

pytestmark = pytest.mark.skipif(
    shutil.which("go") is None, reason="Go toolchain required for the deterministic arm"
)


def _read_records(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def test_replay_all_arms_line_count_and_structure(tmp_path):
    out = tmp_path / "run.jsonl"
    code = cli_main(["--mode", "replay", "--output", str(out)])
    # Replay is a real quality gate over the committed recordings: it exits 0 when
    # every graded outcome passes and 1 when a recorded model output fails a
    # grader. Either is a valid graded result; only a usage/config error is 2.
    assert code in (0, 1)
    records = _read_records(out)
    corpus = corpus_mod.load_corpus()
    # header + (cases × arms) + summary
    assert len(records) == 1 + len(corpus.cases) * 3 + 1
    assert records[0]["recordType"] == "run"
    assert records[-1]["recordType"] == "summary"


def test_replay_grades_all_recorded_arms(tmp_path):
    # With recordings committed for every arm, replay grades all three (the
    # deterministic arm runs hermetically; the model arms replay from their
    # recordings). Assert the stable invariants — full grading and no safety
    # failures — not model-content-dependent pass counts.
    out = tmp_path / "run.jsonl"
    cli_main(["--mode", "replay", "--output", str(out)])
    records = _read_records(out)
    summary = records[-1]["totals"]
    assert summary["perArm"]["deterministic"]["graded"] == 12
    assert summary["perArm"]["deterministic"]["passed"] == 12
    for arm in ("direct_judge", "deep_agent"):
        assert summary["perArm"][arm]["graded"] == 12
        assert summary["perArm"][arm]["skipped"] == 0
    assert summary["overall"]["graded"] == 36
    assert summary["overall"]["safetyFailures"] == 0


def test_replay_deterministic_only_line_count(tmp_path):
    out = tmp_path / "det.jsonl"
    assert cli_main(["--mode", "replay", "--arm", "deterministic", "--output", str(out)]) == 0
    records = _read_records(out)
    assert len(records) == 1 + 12 + 1


def test_recorded_result_matches_live_deterministic_run():
    corpus = corpus_mod.load_corpus()
    case = corpus.cases[0]
    world = corpus_mod.load_world(case)
    result, _, _ = runner_mod._run_arm_live("deterministic", case, world, Budget.default(), 5)
    recording = json.loads(runner_mod.recording_path("deterministic", case.id).read_text())
    from candidate_assembly.schemas import AssemblyResult

    recorded = AssemblyResult.model_validate(recording)
    assert recorded.model_dump(exclude_none=True) == result.model_dump(exclude_none=True)


def test_drift_detected_when_recording_tampered(monkeypatch):
    corpus = corpus_mod.load_corpus()
    case = corpus.cases[0]
    world = corpus_mod.load_world(case)
    tampered = json.loads(runner_mod.recording_path("deterministic", case.id).read_text())
    tampered["recommendations"][0]["confidence"] = 0.01  # force a diff

    monkeypatch.setattr(runner_mod, "_load_recording", lambda arm, cid: tampered)

    cfg = runner_mod.RunConfig(
        mode="replay",
        arms=["deterministic"],
        run_id="drift-test",
        model="replay",
        prompt_revision=PROMPT_REVISION,
        budget=Budget.default(),
    )
    outcome = runner_mod.run_case_arm(case, world, "deterministic", cfg)
    assert outcome.status == runner_mod.STATUS_DRIFT
    assert outcome.passed is False
