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
    repo_is_clean,
    write_json,
    write_manifest,
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
        "model_sha256": "b" * 64,
        "analyzer_script_sha256": "c" * 64,
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


def test_write_manifest_preserves_existing_file_when_validation_fails(tmp_path: Path):
    path = tmp_path / "manifest.jsonl"
    existing = {
        "id": "existing",
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
        "reference": {"bpm": 120},
    }
    _write_jsonl(path, [existing])
    original = path.read_bytes()
    invalid = existing | {"id": "duplicate"}

    with pytest.raises(EvalInputError, match="duplicate id"):
        write_manifest(path, [invalid, invalid])

    assert path.read_bytes() == original
    assert not list(tmp_path.glob("*.manifest"))


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


def test_manifest_preserves_split_and_stratum_and_rejects_unknown_split(tmp_path: Path):
    path = tmp_path / "manifest.jsonl"
    record = {
        "id": "track",
        "label_kind": "ground_truth",
        "evaluation_split": "holdout",
        "stratum": "variable_tempo",
        "provenance": {"dataset": "fixture"},
        "reference": {"bpm": 120},
    }
    _write_jsonl(path, [record])

    assert load_manifest(path)[0]["evaluation_split"] == "holdout"
    assert load_manifest(path)[0]["stratum"] == "variable_tempo"

    _write_jsonl(path, [record | {"evaluation_split": "train"}])
    with pytest.raises(EvalInputError, match="evaluation_split"):
        load_manifest(path)


def test_manifest_rejects_unbounded_strata_taxonomy(tmp_path: Path):
    path = tmp_path / "manifest.jsonl"
    record = {
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
        "reference": {"bpm": 120},
    }
    _write_jsonl(
        path,
        [
            record | {"id": f"track-{index}", "stratum": f"stratum-{index}"}
            for index in range(65)
        ],
    )

    with pytest.raises(EvalInputError, match="more than 64 strata"):
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

    bpm_path = tmp_path / "bpm.jsonl"
    _write_jsonl(bpm_path, [base | {"reference": {"bpm": 10**400}}])
    with pytest.raises(EvalInputError, match="must be finite"):
        load_manifest(bpm_path)


def test_repo_head_rejects_an_enclosing_repository(monkeypatch):
    root = Path(__file__).resolve().parents[3]

    assert repo_head(root) != "unknown"
    assert repo_head(root / "backend") == "unknown"

    calls: list[list[str]] = []

    def fake_run(command: list[str], **_kwargs):
        calls.append(command)
        stdout = str(root) if "--show-toplevel" in command else "a" * 40
        return type("Completed", (), {"stdout": stdout})()

    monkeypatch.setattr(
        "audio_mir_eval.io.shutil.which", lambda _command: "relative/git"
    )
    monkeypatch.setattr("audio_mir_eval.io.subprocess.run", fake_run)
    assert repo_head(root) == "a" * 40
    assert all(Path(command[0]).is_absolute() for command in calls)

    monkeypatch.setattr("audio_mir_eval.io.shutil.which", lambda _command: None)
    assert repo_head(root) == "unknown"


def test_repo_is_clean_requires_an_exact_root_and_no_local_changes(monkeypatch):
    root = Path(__file__).resolve().parents[3]
    status = ""

    def fake_run(command: list[str], **_kwargs):
        if "--show-toplevel" in command:
            stdout = str(root)
        elif "status" in command:
            stdout = status
        else:
            raise AssertionError(f"unexpected command: {command}")
        return type("Completed", (), {"stdout": stdout})()

    monkeypatch.setattr("audio_mir_eval.io.shutil.which", lambda _command: "/bin/git")
    monkeypatch.setattr("audio_mir_eval.io.subprocess.run", fake_run)

    assert repo_is_clean(root) is True
    status = " M evals/audio_mir/src/audio_mir_eval/score.py\n"
    assert repo_is_clean(root) is False
    assert repo_is_clean(root / "backend") is False


def test_atomic_write_respects_restrictive_umask(tmp_path: Path):
    old_umask = os.umask(0o077)
    try:
        output = tmp_path / "report.json"
        write_json(output, {"ok": True})
    finally:
        os.umask(old_umask)

    assert output.stat().st_mode & 0o777 == 0o600
