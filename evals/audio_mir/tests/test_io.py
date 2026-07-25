from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from audio_mir_eval.io import (
    EvalInputError,
    load_manifest,
    load_predictions,
    repo_head,
    write_json,
)


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def _run_record(*, complete: bool = True) -> dict:
    return {
        "record_type": "run",
        "schema_version": 2,
        "complete": complete,
        "prediction_count": 1,
        "manifest_sha256": "a" * 64,
        "repo_head": "abc",
        "analyzer": {"version": "v1"},
    }


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


def test_manifest_rejects_malformed_key_before_analysis(tmp_path: Path):
    path = tmp_path / "manifest.jsonl"
    _write_jsonl(
        path,
        [
            {
                "id": "track",
                "label_kind": "ground_truth",
                "provenance": {"dataset": "fixture"},
                "reference": {"key": "C major/A minor"},
            }
        ],
    )

    with pytest.raises(EvalInputError, match="valid mir_eval key"):
        load_manifest(path)


def test_prediction_artifact_accepts_complete_provenance_header(tmp_path: Path):
    path = tmp_path / "predictions.jsonl"
    _write_jsonl(
        path,
        [
            _run_record(),
            {"record_type": "prediction", "id": "track", "bpm": 120},
        ],
    )

    run, predictions = load_predictions(path)

    assert run["analyzer"]["version"] == "v1"
    assert predictions["track"]["bpm"] == 120


def test_prediction_artifact_rejects_incomplete_run(tmp_path: Path):
    path = tmp_path / "predictions.jsonl"
    _write_jsonl(
        path,
        [
            _run_record(complete=False),
            {"record_type": "prediction", "id": "track", "bpm": 120},
        ],
    )

    with pytest.raises(EvalInputError, match="incomplete"):
        load_predictions(path)


def test_manifest_rejects_unlabelled_key_and_out_of_range_events(tmp_path: Path):
    base = {
        "id": "track",
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
    }
    key_path = tmp_path / "key.jsonl"
    _write_jsonl(key_path, [base | {"reference": {"key": "X"}}])
    with pytest.raises(EvalInputError, match="no annotated key"):
        load_manifest(key_path)

    events_path = tmp_path / "events.jsonl"
    _write_jsonl(
        events_path,
        [base | {"reference": {"beats_seconds": [5.0, 30001.0]}}],
    )
    with pytest.raises(EvalInputError, match="cannot exceed 30000 seconds"):
        load_manifest(events_path)


def test_repo_head_rejects_an_enclosing_repository():
    root = Path(__file__).resolve().parents[3]

    assert repo_head(root) != "unknown"
    assert repo_head(root / "backend") == "unknown"


def test_atomic_write_respects_restrictive_umask(tmp_path: Path):
    old_umask = os.umask(0o077)
    try:
        output = tmp_path / "report.json"
        write_json(output, {"ok": True})
    finally:
        os.umask(old_umask)

    assert output.stat().st_mode & 0o777 == 0o600
