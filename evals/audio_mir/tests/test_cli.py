from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from audio_mir_eval.cli import main


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def test_run_then_score_with_exact_analyzer_subprocess(tmp_path: Path):
    analyzer = tmp_path / "fake_analyzer.py"
    analyzer.write_text(
        """import json, sys
if '--check' in sys.argv:
    print(json.dumps({'analyzer': 'fake', 'analyzer_version': '1'}))
else:
    print(json.dumps({
        'bpm': 120.0,
        'tempo_confidence': 0.9,
        'beats_ms': [5000, 5500, 6000, 6500],
        'downbeats_ms': [5000],
        'downbeat_confidence': 0.8,
        'key_index': 0,
        'key': 'C major',
        'mode': 'major',
        'key_confidence': 0.7,
        'spectral_bands': {'low': [1.0]},
    }))
""",
        encoding="utf-8",
    )
    model = tmp_path / "model.ckpt"
    model.write_bytes(b"fixture")
    audio = tmp_path / "track.wav"
    audio.write_bytes(b"not decoded by the fake analyzer")
    manifest = tmp_path / "manifest.jsonl"
    _write_jsonl(
        manifest,
        [
            {
                "id": "track",
                "audio_path": "track.wav",
                "label_kind": "ground_truth",
                "provenance": {"dataset": "fixture"},
                "reference": {
                    "bpm": 120,
                    "key": "C major",
                    "beats_seconds": [5.0, 5.5, 6.0, 6.5],
                },
            }
        ],
    )
    predictions = tmp_path / "predictions.jsonl"
    report = tmp_path / "report.json"

    run_args = [
        "--repo-root",
        str(tmp_path),
        "run",
        "--manifest",
        str(manifest),
        "--analyzer-python",
        sys.executable,
        "--analyzer-script",
        str(analyzer),
        "--model",
        str(model),
        "--output",
        str(predictions),
    ]
    run_exit = main(run_args)
    audio.unlink()
    resume_exit = main([*run_args, "--resume"])
    score_exit = main(
        [
            "--repo-root",
            str(tmp_path),
            "score",
            "--manifest",
            str(manifest),
            "--predictions",
            str(predictions),
            "--output",
            str(report),
        ]
    )

    assert run_exit == 0
    assert resume_exit == 0
    assert score_exit == 0
    result = json.loads(report.read_text(encoding="utf-8"))
    prediction_rows = [
        json.loads(line)
        for line in predictions.read_text(encoding="utf-8").splitlines()
    ]
    prediction = next(
        row for row in prediction_rows if row.get("record_type") == "prediction"
    )
    assert "key" not in prediction
    assert "spectral_bands" not in prediction
    assert result["counts"] == {
        "expected": 1,
        "predictions": 1,
        "completed": 1,
        "infra_errors": 0,
    }
    assert result["run"]["manifest_sha256"] == result["manifest_sha256"]
    assert (
        result["run"]["model_sha256"] == hashlib.sha256(model.read_bytes()).hexdigest()
    )
    assert (
        result["run"]["analyzer_script_sha256"]
        == hashlib.sha256(analyzer.read_bytes()).hexdigest()
    )
    assert result["run"]["complete"] is True
    assert result["groups"]["ground_truth"]["tempo"]["acc1"] == 1.0
    assert result["groups"]["ground_truth"]["key"]["weighted_score"] == 1.0

    model.write_bytes(b"changed checkpoint")
    assert main([*run_args, "--resume"]) == 1


def test_score_fails_on_partial_prediction_set(tmp_path: Path, capsys):
    manifest = tmp_path / "manifest.jsonl"
    _write_jsonl(
        manifest,
        [
            {
                "id": "expected",
                "label_kind": "ground_truth",
                "provenance": {"dataset": "fixture"},
                "reference": {"bpm": 120},
            }
        ],
    )
    predictions = tmp_path / "predictions.jsonl"
    _write_jsonl(
        predictions,
        [
            {
                "record_type": "run",
                "schema_version": 2,
                "complete": True,
                "prediction_count": 1,
                "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
                "model_sha256": "b" * 64,
                "analyzer_script_sha256": "c" * 64,
                "repo_head": "abc",
                "analyzer": {"analyzer": "fake"},
            },
            {"record_type": "prediction", "id": "wrong", "bpm": 120},
        ],
    )

    assert (
        main(
            [
                "--repo-root",
                str(tmp_path),
                "score",
                "--manifest",
                str(manifest),
                "--predictions",
                str(predictions),
                "--output",
                str(tmp_path / "report.json"),
            ]
        )
        == 1
    )
    assert "prediction set mismatch" in capsys.readouterr().err


def test_score_rejects_prediction_manifest_hash_mismatch(tmp_path: Path):
    original = tmp_path / "original.jsonl"
    changed = tmp_path / "changed.jsonl"
    predictions = tmp_path / "predictions.jsonl"
    base = {
        "id": "track",
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
        "reference": {"bpm": 120},
    }
    _write_jsonl(original, [base])
    _write_jsonl(changed, [base | {"reference": {"bpm": 121}}])
    _write_jsonl(
        predictions,
        [
            {
                "record_type": "run",
                "schema_version": 2,
                "complete": True,
                "prediction_count": 1,
                "manifest_sha256": hashlib.sha256(original.read_bytes()).hexdigest(),
                "model_sha256": "b" * 64,
                "analyzer_script_sha256": "c" * 64,
                "repo_head": "abc",
                "analyzer": {"analyzer": "fake"},
            },
            {"record_type": "prediction", "id": "track", "bpm": 120},
        ],
    )

    assert (
        main(
            [
                "--repo-root",
                str(tmp_path),
                "score",
                "--manifest",
                str(changed),
                "--predictions",
                str(predictions),
                "--output",
                str(tmp_path / "report.json"),
            ]
        )
        == 1
    )
