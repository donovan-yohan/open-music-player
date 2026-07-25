from __future__ import annotations

from audio_mir_eval.score import build_report, score_track


def _manifest(track_id: str, label_kind: str, reference: dict):
    return {
        "id": track_id,
        "label_kind": label_kind,
        "provenance": {"dataset": "fixture"},
        "reference": reference,
    }


def test_tempo_reports_exact_and_octave_tolerant_accuracy_separately():
    result = score_track(
        _manifest("half", "ground_truth", {"bpm": 120.0}),
        {"id": "half", "bpm": 60.0},
    )

    tempo = result["metrics"]["tempo"]
    assert tempo["acc1"] == 0.0
    assert tempo["acc2"] == 1.0
    assert tempo["octave_class"] == "half"


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


def test_event_metrics_include_alignment_and_continuity_scores():
    reference = [0.0, 0.5, 1.0, 1.5, 2.0]
    result = score_track(
        _manifest("beats", "ground_truth", {"beats_seconds": reference}),
        {"id": "beats", "beats_ms": [0, 500, 1000, 1500, 2000]},
    )

    beats = result["metrics"]["beats"]
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

    report = build_report(
        manifest,
        predictions,
        run={},
        repo_head="abc",
        manifest_sha256="manifest",
        predictions_sha256="predictions",
        generated_at="2026-07-25T00:00:00+00:00",
    )

    assert set(report["groups"]) == {"external_reference", "ground_truth"}
    assert report["groups"]["ground_truth"]["tempo"]["acc1"] == 1.0
    assert report["groups"]["external_reference"]["tempo"]["acc1"] == 0.0
