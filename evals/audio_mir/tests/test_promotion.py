from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path

import pytest

from audio_mir_eval.cli import main
from audio_mir_eval.io import EvalInputError
from audio_mir_eval.promotion import (
    build_evidence_packet,
    calibration_evidence_sha256,
    evaluate_promotion,
    freeze_packet_sha256,
    validate_evidence_packet,
)
from audio_mir_eval.score import build_report


def _manifest(track_id: str, evaluation_split: str, stratum: str) -> dict:
    beats = [5.0 + index * 0.5 for index in range(14)]
    return {
        "id": track_id,
        "label_kind": "ground_truth",
        "evaluation_split": evaluation_split,
        "stratum": stratum,
        "provenance": {"dataset": "fixture"},
        "reference": {
            "beats_seconds": beats,
            "downbeats_seconds": [5.0, 7.0, 9.0, 11.0],
            "meter_beats": 4,
        },
    }


def _report(
    arm: str, *, shifted_downbeats: bool, runtime: float, peak_rss_kib: int
) -> dict:
    manifest = [
        _manifest("calibration-a", "calibration", "steady_edm"),
        _manifest("calibration-b", "calibration", "half_time"),
        _manifest("calibration-c", "calibration", "variable_tempo"),
        _manifest("holdout-a", "holdout", "breakdown"),
        _manifest("holdout-b", "holdout", "variable_tempo"),
    ]
    beats_ms = [5000 + index * 500 for index in range(14)]
    downbeats_ms = (
        [5000, 7500, 9000, 10500] if shifted_downbeats else [5000, 7000, 9000, 11000]
    )
    predictions = {
        item["id"]: {
            "id": item["id"],
            "beats_ms": beats_ms,
            "downbeats_ms": downbeats_ms,
            "downbeat_confidence": 0.9,
            "runtime_seconds": runtime,
            "audio_sha256": hashlib.sha256(item["id"].encode()).hexdigest(),
        }
        for item in manifest
    }
    report = build_report(
        manifest,
        predictions,
        run={
            "record_type": "run",
            "repo_head": "run-head",
            "repo_worktree_clean": True,
            "model_sha256": "b" * 64,
            "analyzer_script_sha256": "c" * 64,
            "analyzer": {"version": "fixture"},
            "experiment": {
                "id": "raveform-phase-v1",
                "arm": arm,
                "factor": "downbeat-postprocessor",
                "freeze_id": "freeze-packet-sha256",
            },
            "resource_usage": {
                "peak_rss_kib": peak_rss_kib,
                "scope": "runner_process_children_lifetime",
            },
        },
        scorer_repo_head="score-head",
        manifest_sha256="a" * 64,
        predictions_sha256=("d" if arm == "omp-regularized" else "e") * 64,
        generated_at="2026-07-26T00:00:00+00:00",
        scorer_worktree_clean=True,
    )
    report["run"]["experiment"]["freeze_id"] = freeze_packet_sha256(report)
    return report


def _policy() -> dict:
    calibration_report = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    return {
        "schema_version": 1,
        "label_kind": "ground_truth",
        "evaluation_split": "holdout",
        "minimum_holdout_tracks": 2,
        "downbeats": {
            "minimum_phase_precision_delta": 0.1,
            "maximum_cmlc_regression": 0.0,
            "maximum_f_measure_regression": 0.0,
            "maximum_cemgil_regression": 0.0,
            "maximum_cmlt_regression": 0.0,
            "maximum_reference_downbeat_recall_regression": 0.0,
            "maximum_phase_f1_regression": 0.0,
            "minimum_paired_phase_precision_lower_ci": 0.0,
            "minimum_paired_cmlc_lower_ci": 0.0,
        },
        "beats": {
            "maximum_f_measure_regression": 0.0,
            "maximum_cemgil_regression": 0.0,
            "maximum_cmlc_regression": 0.0,
            "maximum_cmlt_regression": 0.0,
            "maximum_local_tempo_coverage_regression": 0.0,
            "maximum_local_tempo_error_increase": 0.0,
            "maximum_tempo_change_false_positive_rate_increase": 0.0,
        },
        "resources": {
            "maximum_runtime_p95_ratio": 1.2,
            "maximum_peak_rss_ratio": 1.2,
        },
        "paired": {"minimum_tracks": 2, "bootstrap_resamples": 200},
        "required_holdout_strata": ["breakdown", "variable_tempo"],
        "automation": {
            "threshold_source": "calibration",
            "calibration_evidence_sha256": calibration_evidence_sha256(
                calibration_report
            ),
            "confidence_threshold": 0.8,
            "minimum_calibration_tracks": 2,
            "minimum_calibration_coverage": 1.0,
            "minimum_holdout_coverage": 1.0,
            "minimum_track_phase_precision": 1.0,
            "maximum_holdout_false_lock_rate": 0.0,
            "maximum_calibration_false_lock_rate": 0.0,
        },
    }


def test_promotion_accepts_improved_frozen_candidate_with_held_out_evidence():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )

    decision = evaluate_promotion(baseline, candidate, _policy())

    assert decision["passed"] is True
    assert decision["automation"]["coverage"] == 1.0
    assert decision["automation"]["unknown_phase_locked_tracks"] == 0
    assert decision["automation"]["unknown_meter_locked_tracks"] == 0
    assert decision["paired_deltas"]["phase_precision"]["bootstrap_lower_ci_95"] > 0
    assert all(gate["passed"] for gate in decision["gates"])
    assert (
        decision["comparison"]["baseline_analyzer_script_sha256"]
        == decision["comparison"]["candidate_analyzer_script_sha256"]
    )


def test_promotion_fails_closed_when_experiment_context_is_missing():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["run"].pop("experiment")

    decision = evaluate_promotion(baseline, candidate, _policy())

    assert decision["passed"] is False
    context_gate = next(
        gate
        for gate in decision["gates"]
        if gate["name"] == "experiment_context_declared"
    )
    assert context_gate["passed"] is False


def test_promotion_rejects_changed_or_missing_audio_identity():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][0]["audio_sha256"] = "f" * 64

    decision = evaluate_promotion(baseline, candidate, _policy())

    audio_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "frozen_audio_hashes"
    )
    assert audio_gate["passed"] is False
    candidate["tracks"][0].pop("audio_sha256")
    with pytest.raises(EvalInputError, match="audio_sha256"):
        evaluate_promotion(baseline, candidate, _policy())


def test_promotion_rejects_pilot_or_cross_split_audio_identity():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][0]["evaluation_split"] = "pilot"

    decision = evaluate_promotion(baseline, candidate, _policy())

    pilot_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "candidate_sealed_splits"
    )
    assert pilot_gate["passed"] is False
    assert pilot_gate["unexpected_splits"] == ["pilot"]

    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][3]["audio_sha256"] = candidate["tracks"][0]["audio_sha256"]

    decision = evaluate_promotion(baseline, candidate, _policy())

    overlap_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "candidate_sealed_splits"
    )
    assert overlap_gate["passed"] is False
    assert overlap_gate["calibration_holdout_audio_overlap"] == 1


def test_promotion_rejects_a_high_confidence_unknown_phase_lock():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][3]["metrics"]["downbeats"]["bar_phase"]["evaluable"] = False

    decision = evaluate_promotion(baseline, candidate, _policy())

    unknown_phase_gate = next(
        gate
        for gate in decision["gates"]
        if gate["name"] == "unknown_phase_remains_unlocked"
    )
    assert unknown_phase_gate["passed"] is False
    assert unknown_phase_gate["unknown_phase_tracks"] == 1
    assert unknown_phase_gate["locked_unknown_phase_tracks"] == 1


def test_promotion_rejects_a_high_confidence_unknown_calibration_phase_lock():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][0]["metrics"]["downbeats"]["bar_phase"]["evaluable"] = False

    decision = evaluate_promotion(baseline, candidate, _policy())

    calibration_unknown_gate = next(
        gate
        for gate in decision["gates"]
        if gate["name"] == "calibration_unknown_phase_remains_unlocked"
    )
    assert calibration_unknown_gate["passed"] is False
    assert calibration_unknown_gate["unknown_phase_tracks"] == 1
    assert calibration_unknown_gate["locked_unknown_phase_tracks"] == 1


@pytest.mark.parametrize(
    ("metric_path", "gate_name", "lower_is_better"),
    [
        (("downbeats", "f_measure_70ms"), "downbeat_f_measure_non_regression", False),
        (("downbeats", "cemgil"), "downbeat_cemgil_non_regression", False),
        (("downbeats", "cmlc"), "downbeat_cmlc_non_regression", False),
        (("downbeats", "cmlt"), "downbeat_cmlt_non_regression", False),
        (
            ("downbeats", "bar_phase", "reference_downbeat_recall"),
            "downbeat_reference_recall_non_regression",
            False,
        ),
        (
            ("downbeats", "bar_phase", "phase_f1"),
            "downbeat_phase_f1_non_regression",
            False,
        ),
        (("beats", "f_measure_70ms"), "beat_f_measure_non_regression", False),
        (("beats", "cemgil"), "beat_cemgil_non_regression", False),
        (("beats", "cmlc"), "beat_cmlc_non_regression", False),
        (("beats", "cmlt"), "beat_cmlt_non_regression", False),
        (
            ("beats", "local_tempo", "coverage"),
            "local_tempo_coverage_non_regression",
            False,
        ),
        (
            ("beats", "local_tempo", "mean_absolute_relative_error"),
            "local_tempo_error_budget",
            True,
        ),
    ],
)
def test_promotion_rejects_required_metric_regressions(
    metric_path: tuple[str, ...], gate_name: str, lower_is_better: bool
):
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    baseline_metric = baseline["groups"]["ground_truth"]["splits"]["holdout"]
    candidate_metric = candidate["groups"]["ground_truth"]["splits"]["holdout"]
    for name in metric_path[:-1]:
        baseline_metric = baseline_metric[name]
        candidate_metric = candidate_metric[name]
    baseline_value = baseline_metric[metric_path[-1]]
    candidate_metric[metric_path[-1]] = (
        baseline_value + 0.01 if lower_is_better else baseline_value - 0.01
    )

    decision = evaluate_promotion(baseline, candidate, _policy())

    phase_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "downbeat_phase_precision"
    )
    regression_gate = next(
        gate for gate in decision["gates"] if gate["name"] == gate_name
    )
    assert phase_gate["passed"] is True
    assert regression_gate["passed"] is False


def test_promote_command_writes_a_passing_decision(tmp_path: Path):
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    baseline_path = tmp_path / "baseline.json"
    candidate_path = tmp_path / "candidate.json"
    policy_path = tmp_path / "policy.json"
    decision_path = tmp_path / "decision.json"
    evidence_path = tmp_path / "evidence.json"
    for path, value in (
        (baseline_path, baseline),
        (candidate_path, candidate),
        (policy_path, _policy()),
    ):
        path.write_text(json.dumps(value), encoding="utf-8")

    exit_code = main(
        [
            "--repo-root",
            str(Path(__file__).resolve().parents[3]),
            "promote",
            "--baseline-report",
            str(baseline_path),
            "--candidate-report",
            str(candidate_path),
            "--policy",
            str(policy_path),
            "--output",
            str(decision_path),
            "--evidence-output",
            str(evidence_path),
        ]
    )

    assert exit_code == 0
    assert json.loads(decision_path.read_text(encoding="utf-8"))["passed"] is True
    assert (
        len(json.loads(evidence_path.read_text(encoding="utf-8"))["packet_sha256"])
        == 64
    )


def test_evidence_packet_is_deterministic_and_rejects_any_tampering():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    policy = _policy()
    decision = evaluate_promotion(baseline, candidate, policy)

    packet = build_evidence_packet(baseline, candidate, policy, decision)
    assert packet == build_evidence_packet(baseline, candidate, policy, decision)
    assert (
        validate_evidence_packet(packet, baseline, candidate, policy, decision)
        == packet
    )

    packet["decision_sha256"] = "f" * 64
    with pytest.raises(EvalInputError, match="SHA-256"):
        validate_evidence_packet(packet, baseline, candidate, policy, decision)


def test_promotion_requires_declared_content_addressed_freeze_packet():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )

    assert freeze_packet_sha256(baseline) == freeze_packet_sha256(candidate)
    candidate = deepcopy(candidate)
    candidate["run"]["experiment"]["freeze_id"] = "f" * 64

    decision = evaluate_promotion(baseline, candidate, _policy())

    freeze_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "canonical_freeze_packet"
    )
    assert freeze_gate["passed"] is False

    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate["run"]["analyzer_script_sha256"] = "e" * 64
    decision = evaluate_promotion(baseline, candidate, _policy())
    freeze_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "canonical_freeze_packet"
    )
    assert freeze_gate["passed"] is False

    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate["run"]["analyzer"]["version"] = "tampered"
    decision = evaluate_promotion(baseline, candidate, _policy())
    freeze_gate = next(
        gate for gate in decision["gates"] if gate["name"] == "canonical_freeze_packet"
    )
    assert freeze_gate["passed"] is False


def test_calibration_provenance_excludes_holdout_and_rejects_wrong_policy_hash():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    holdout_changed = deepcopy(candidate)
    holdout_changed["tracks"][3]["metrics"]["downbeats"]["cmlc"] = 0.123
    assert calibration_evidence_sha256(candidate) == calibration_evidence_sha256(
        holdout_changed
    )

    policy = _policy()
    policy["automation"]["calibration_evidence_sha256"] = "f" * 64
    decision = evaluate_promotion(baseline, candidate, policy)
    calibration_gate = next(
        gate
        for gate in decision["gates"]
        if gate["name"] == "calibration_evidence_bound"
    )
    assert calibration_gate["passed"] is False


def test_promotion_rejects_unknown_meter_lock_and_missing_required_stratum():
    baseline = _report(
        "omp-regularized", shifted_downbeats=True, runtime=10.0, peak_rss_kib=1000
    )
    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate = deepcopy(candidate)
    candidate["tracks"][3]["meter_known"] = False
    decision = evaluate_promotion(baseline, candidate, _policy())
    assert (
        next(
            g
            for g in decision["gates"]
            if g["name"] == "unknown_meter_remains_unlocked"
        )["passed"]
        is False
    )

    candidate = _report(
        "candidate-phase", shifted_downbeats=False, runtime=11.0, peak_rss_kib=1100
    )
    candidate["tracks"][3]["metrics"]["downbeats"]["bar_phase"]["evaluable"] = False
    decision = evaluate_promotion(baseline, candidate, _policy())
    stratum_gate = next(
        gate
        for gate in decision["gates"]
        if gate["name"] == "required_holdout_strata_evaluable"
    )
    assert stratum_gate["passed"] is False
    assert stratum_gate["candidate_evaluable_counts"].get("breakdown", 0) == 0

    policy = _policy() | {"required_holdout_strata": ["non_4_4"]}
    decision = evaluate_promotion(baseline, candidate, policy)
    assert (
        next(
            g
            for g in decision["gates"]
            if g["name"] == "required_holdout_strata_evaluable"
        )["passed"]
        is False
    )
