from __future__ import annotations

from audio_mir_eval.score import build_report, score_track


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


def test_key_uses_mirex_relationship_weighting():
    result = score_track(
        _manifest("relative", "ground_truth", {"key": "C major"}),
        {"id": "relative", "key_index": 9, "mode": "minor"},
    )

    key = result["metrics"]["key"]
    assert key["weighted_score"] == 0.3
    assert key["relationship"] == "relative"
    assert key["exact"] == 0.0


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
    result = score_track(
        _manifest("beats", "ground_truth", {"beats_seconds": reference}),
        {"id": "beats", "beats_ms": estimate_ms},
    )

    beats = result["metrics"]["beats"]
    assert beats["trim_seconds"] == 5.0
    assert beats["evaluated_reference_events"] == 11
    assert beats["f_measure_70ms"] == 1.0
    assert beats["cemgil"] == 1.0
    assert beats["cmlc"] == 1.0
    assert beats["amlt"] == 1.0


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
