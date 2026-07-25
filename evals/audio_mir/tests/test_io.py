from __future__ import annotations

import json
from pathlib import Path

import pytest

from audio_mir_eval.io import EvalInputError, load_manifest, load_predictions


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def test_manifest_rejects_duplicate_track_ids(tmp_path: Path):
    record = {
        "id": "duplicate",
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
        "reference": {"bpm": 120},
    }
    path = tmp_path / "manifest.jsonl"
    _write_jsonl(path, [record, record])

    with pytest.raises(EvalInputError, match="duplicate id"):
        load_manifest(path)


def test_manifest_requires_reference_provenance_class(tmp_path: Path):
    path = tmp_path / "manifest.jsonl"
    _write_jsonl(
        path,
        [
            {
                "id": "track",
                "label_kind": "probably-correct",
                "provenance": {"dataset": "fixture"},
                "reference": {"key": "C major"},
            }
        ],
    )

    with pytest.raises(EvalInputError, match="label_kind"):
        load_manifest(path)


def test_prediction_artifact_accepts_one_run_header(tmp_path: Path):
    path = tmp_path / "predictions.jsonl"
    _write_jsonl(
        path,
        [
            {"record_type": "run", "analyzer": {"version": "v1"}},
            {"record_type": "prediction", "id": "track", "bpm": 120},
        ],
    )

    run, predictions = load_predictions(path)

    assert run["analyzer"]["version"] == "v1"
    assert predictions["track"]["bpm"] == 120
