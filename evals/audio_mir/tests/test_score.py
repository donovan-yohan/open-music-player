from __future__ import annotations

import re
from pathlib import Path

from audio_mir_eval.score import _PITCHES, build_report, score_track


def _manifest(track_id: str, label_kind: str, reference: dict):
    return {
        "id": track_id,
        "label_kind": label_kind,
        "provenance": {"dataset": "fixture"},
        "reference": reference,
    }


def _report(manifest: list[dict], predictions: dict[str, dict]) -> dict:
    return build_report(
        manifest,
        predictions,
        run={"record_type": "run", "repo_head": "run-head"},
        scorer_repo_head="score-head",
        manifest_sha256="manifest",
        predictions_sha256="predictions",
        generated_at="2026-07-25T00:00:00+00:00",
    )


def test_tempo_reports_acc1_and_standard_mirex_acc2_separately():
    half = score_track(
        _manifest("half", "ground_truth", {"bpm": 120.0}),
        {"id": "half", "bpm": 60.0},
    )["metrics"]["tempo"]
    third = score_track(
        _manifest("third", "ground_truth", {"bpm": 120.0}),
        {"id": "third", "bpm": 40.0},
    )["metrics"]["tempo"]

    assert half["acc1"] == 0.0
    assert half["acc2"] == 1.0
    assert half["tempo_class"] == "half"
    assert third["acc2"] == 1.0
    assert third["tempo_class"] == "one_third"


def test_pitch_index_contract_matches_go_analyzer():
    repo_root = Path(__file__).resolve().parents[3]
    source = (repo_root / "backend/cmd/audio-analyzer/main.go").read_text(
        encoding="utf-8"
    )
    match = re.search(r"var keyNames = \[\]string\{([^}]*)\}", source)

    assert match is not None
    assert tuple(re.findall(r'"([^"]+)"', match.group(1))) == _PITCHES


def test_key_uses_mirex_relationship_weighting():
    result = score_track(
        _manifest("relative", "ground_truth", {"key": "C major"}),
        {"id": "relative", "key_index": 9, "mode": "minor"},
    )

    key = result["metrics"]["key"]
    assert key["weighted_score"] == 0.3
    assert key["relationship"] == "relative"
    assert key["exact"] == 0.0


def test_key_credits_perfect_fifths_in_both_directions():
    results = [
        score_track(
            _manifest(f"fifth-{key_index}", "ground_truth", {"key": "C major"}),
            {"id": f"fifth-{key_index}", "key_index": key_index, "mode": "major"},
        )["metrics"]["key"]
        for key_index in (5, 7)
    ]

    assert [result["weighted_score"] for result in results] == [0.5, 0.5]
    assert [result["relationship"] for result in results] == [
        "perfect_fifth",
        "perfect_fifth",
    ]


def test_missing_key_counts_as_an_exact_failure():
    result = score_track(
        _manifest("missing", "ground_truth", {"key": "C major"}),
        {"id": "missing", "key_index": None, "mode": None},
    )

    key = result["metrics"]["key"]
    assert key["available"] is False
    assert key["weighted_score"] == 0.0
    assert key["exact"] == 0.0


def test_event_metrics_apply_standard_five_second_trim():
    reference = [index * 0.5 for index in range(21)]
    estimate_ms = [250, 750, 1250, 1750, 2250, 2750, 3250, 3750, 4250, 4750]
    estimate_ms.extend(int(value * 1000) for value in reference if value >= 5.0)
    estimate_ms.append(40_000_000)
    estimate_ms.append(10**400)
    result = score_track(
        _manifest("beats", "ground_truth", {"beats_seconds": reference}),
        {"id": "beats", "beats_ms": estimate_ms},
    )

    beats = result["metrics"]["beats"]
    assert beats["trim_seconds"] == 5.0
    assert beats["evaluated_reference_events"] == 11
    assert beats["dropped_estimated_events"] == 2
    assert beats["f_measure_70ms"] == 1.0
    assert beats["cemgil"] == 1.0
    assert beats["cmlc"] == 1.0
    assert beats["amlt"] == 1.0


def test_local_tempo_reports_matched_interval_coverage_without_filling_gaps():
    reference = [5.0, 5.5, 6.0, 6.5, 7.0]
    result = score_track(
        _manifest("local-tempo", "ground_truth", {"beats_seconds": reference}),
        {"id": "local-tempo", "beats_ms": [5000, 5500, 6000, 7000]},
    )

    local_tempo = result["metrics"]["beats"]["local_tempo"]

    assert local_tempo["reference_intervals"] == 4
    assert local_tempo["matched_intervals"] == 2
    assert local_tempo["coverage"] == 0.5
    assert local_tempo["mean_absolute_relative_error"] == 0.0
    assert local_tempo["within_4_percent"] == 1.0


def test_local_tempo_reports_false_positive_tempo_changes_on_steady_reference():
    reference = [5.0, 5.5, 6.0, 6.5, 7.0]
    result = score_track(
        _manifest("tempo-change-fpr", "ground_truth", {"beats_seconds": reference}),
        {"id": "tempo-change-fpr", "beats_ms": [5000, 5480, 6000, 6480, 7000]},
    )

    changes = result["metrics"]["beats"]["local_tempo"]["tempo_change"]

    assert changes["comparable_boundaries"] == 3
    assert changes["false_positives"] == 3
    assert changes["false_positive_rate"] == 1.0


def test_downbeat_phase_reports_one_to_three_beat_confusion_without_4_4_extrapolation():
    beats = [5.0 + index * 0.5 for index in range(14)]
    result = score_track(
        _manifest(
            "phase",
            "ground_truth",
            {"beats_seconds": beats, "downbeats_seconds": [5.0, 7.0, 9.0, 11.0]},
        ),
        {
            "id": "phase",
            "beats_ms": [int(value * 1000) for value in beats],
            "downbeats_ms": [5000, 7500, 9000, 10500],
        },
    )

    phase = result["metrics"]["downbeats"]["bar_phase"]

    assert phase["phase_precision"] == 0.5
    assert phase["reference_downbeat_recall"] == 0.5
    assert phase["confusion"] == {
        "on_downbeat": 2,
        "one_beat_shift": 1,
        "two_beat_shift": 0,
        "three_beat_shift": 1,
        "other_beat_shift": 0,
        "off_grid": 0,
        "unanchored": 0,
    }


def test_downbeat_phase_refuses_unanchored_reference_annotations():
    beats = [5.0 + index * 0.5 for index in range(14)]
    result = score_track(
        _manifest(
            "unaligned-phase",
            "ground_truth",
            {"beats_seconds": beats, "downbeats_seconds": [5.0, 7.25, 9.0, 11.0]},
        ),
        {
            "id": "unaligned-phase",
            "downbeats_ms": [5000, 7000, 9000, 11000],
        },
    )

    phase = result["metrics"]["downbeats"]["bar_phase"]

    assert phase["evaluable"] is False
    assert phase["reference_downbeats_anchored_to_beats"] == 3
    assert phase["unanchored_reference_downbeats"] == 1
    assert phase["phase_precision"] is None


def test_report_separates_calibration_and_holdout_confidence_evidence():
    beats = [5.0 + index * 0.5 for index in range(14)]
    reference = {"beats_seconds": beats, "downbeats_seconds": [5.0, 7.0, 9.0, 11.0]}
    manifest = [
        _manifest("calibration", "ground_truth", reference)
        | {"evaluation_split": "calibration", "stratum": "steady_edm"},
        _manifest("holdout", "ground_truth", reference)
        | {"evaluation_split": "holdout", "stratum": "steady_edm"},
    ]
    predictions = {
        "calibration": {
            "id": "calibration",
            "beats_ms": [int(value * 1000) for value in beats],
            "downbeats_ms": [5000, 7000, 9000, 11000],
            "downbeat_confidence": 0.9,
        },
        "holdout": {
            "id": "holdout",
            "beats_ms": [int(value * 1000) for value in beats],
            "downbeats_ms": [5000, 7500, 9000, 10500],
            "downbeat_confidence": 0.6,
        },
    }

    report = _report(manifest, predictions)
    group = report["groups"]["ground_truth"]

    assert report["schema_version"] == 3
    assert (
        group["splits"]["calibration"]["downbeats"]["bar_phase"]["phase_precision"]
        == 1.0
    )
    assert (
        group["splits"]["holdout"]["downbeats"]["bar_phase"]["phase_precision"] == 0.5
    )
    confidence = group["splits"]["holdout"]["downbeats"]["confidence"]
    assert confidence["phase_eligible_tracks"] == 1
    assert confidence["reported_confidence_tracks"] == 1
    assert confidence["risk_coverage"][6]["coverage"] == 1.0
    assert group["strata"]["steady_edm"]["tracks"] == 2
    assert (
        group["strata"]["steady_edm"]["splits"]["holdout"]["downbeats"]["bar_phase"][
            "phase_precision"
        ]
        == 0.5
    )
    local_tempo = group["splits"]["holdout"]["beats"]["local_tempo"]
    assert local_tempo["reference_intervals"] == 13
    assert local_tempo["matched_intervals"] == 13
    assert local_tempo["coverage"] == 1.0


def test_report_never_blends_external_references_with_ground_truth():
    manifest = [
        _manifest("gt", "ground_truth", {"bpm": 120.0}),
        _manifest("external", "external_reference", {"bpm": 120.0}),
    ]
    predictions = {
        "gt": {"id": "gt", "bpm": 120.0},
        "external": {"id": "external", "bpm": 60.0},
    }

    report = _report(manifest, predictions)

    assert set(report["groups"]) == {"external_reference", "ground_truth"}
    assert report["groups"]["ground_truth"]["tempo"]["acc1"] == 1.0
    assert report["groups"]["external_reference"]["tempo"]["acc1"] == 0.0
    assert "record_type" not in report["run"]


def test_infra_errors_are_not_averaged_into_model_accuracy():
    manifest = [
        _manifest("ok", "ground_truth", {"bpm": 120.0}),
        _manifest("infra", "ground_truth", {"bpm": 120.0}),
    ]
    predictions = {
        "ok": {"id": "ok", "bpm": 120.0},
        "infra": {"id": "infra", "error": {"type": "TimeoutExpired"}},
    }

    report = _report(manifest, predictions)
    tempo = report["groups"]["ground_truth"]["tempo"]

    assert tempo["references"] == 2
    assert tempo["evaluated"] == 1
    assert tempo["infra_errors"] == 1
    assert tempo["coverage"] == 1.0
    assert tempo["acc1"] == 1.0
