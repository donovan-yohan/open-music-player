from __future__ import annotations

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
        'beats_ms': [0, 500, 1000, 1500],
        'downbeats_ms': [0],
        'downbeat_confidence': 0.8,
        'key_index': 0,
        'mode': 'major',
        'key_confidence': 0.7,
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
                    "beats_seconds": [0.0, 0.5, 1.0, 1.5],
                },
            }
        ],
    )
    predictions = tmp_path / "predictions.jsonl"
    report = tmp_path / "report.json"

    run_exit = main(
        [
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
    )
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
    assert score_exit == 0
    result = json.loads(report.read_text(encoding="utf-8"))
    assert result["counts"] == {"expected": 1, "scored": 1, "infra_errors": 0}
    assert result["groups"]["ground_truth"]["tempo"]["acc1"] == 1.0
    assert result["groups"]["ground_truth"]["key"]["weighted_score"] == 1.0


def test_score_fails_on_partial_prediction_set(tmp_path: Path):
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
    _write_jsonl(predictions, [{"id": "wrong", "bpm": 120}])

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
