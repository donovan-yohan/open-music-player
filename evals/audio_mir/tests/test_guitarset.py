from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest

from audio_mir_eval.guitarset import prepare_manifest
from audio_mir_eval.io import EvalInputError


def _jams() -> dict:
    return {
        "annotations": [
            {
                "namespace": "beat_position",
                "data": [
                    {"time": 0.0, "value": {"position": 1, "num_beats": 4}},
                    {"time": 0.5, "value": {"position": 2, "num_beats": 4}},
                    {"time": 1.0, "value": {"position": 3, "num_beats": 4}},
                    {"time": 1.5, "value": {"position": 4, "num_beats": 4}},
                    {"time": 2.0, "value": {"position": 1, "num_beats": 4}},
                ],
            },
            {"namespace": "tempo", "data": [{"time": 0.0, "value": 120.0}]},
            {"namespace": "key_mode", "data": [{"time": 0.0, "value": "C#:minor"}]},
        ]
    }


def test_prepare_guitarset_extracts_all_supported_reference_tasks(tmp_path: Path):
    annotation_zip = tmp_path / "annotation.zip"
    with zipfile.ZipFile(annotation_zip, "w") as archive:
        archive.writestr("track.jams", json.dumps(_jams()))
    audio_dir = tmp_path / "audio"
    audio_dir.mkdir()
    (audio_dir / "track_mic.wav").write_bytes(b"fixture")
    output = tmp_path / "manifest.jsonl"

    count, missing = prepare_manifest(
        annotation_zip, audio_dir, output_path=output, limit=None
    )

    row = json.loads(output.read_text(encoding="utf-8"))
    assert (count, missing) == (1, 0)
    assert row["reference"] == {
        "bpm": 120.0,
        "beats_seconds": [0.0, 0.5, 1.0, 1.5, 2.0],
        "downbeats_seconds": [0.0, 2.0],
        "key": "C# minor",
    }
    assert row["provenance"]["license"] == "CC-BY-4.0"
    assert (
        row["audio_sha256"]
        == "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d"
    )


def test_prepare_guitarset_rejects_multirow_global_tempo(tmp_path: Path):
    document = _jams()
    tempo = next(
        annotation
        for annotation in document["annotations"]
        if annotation["namespace"] == "tempo"
    )
    tempo["data"].append({"time": 1.0, "value": 121.0})
    annotation_zip = tmp_path / "annotation.zip"
    with zipfile.ZipFile(annotation_zip, "w") as archive:
        archive.writestr("track.jams", json.dumps(document))
    audio_dir = tmp_path / "audio"
    audio_dir.mkdir()
    (audio_dir / "track_mic.wav").write_bytes(b"fixture")

    with pytest.raises(EvalInputError, match="exactly one row"):
        prepare_manifest(
            annotation_zip,
            audio_dir,
            output_path=tmp_path / "manifest.jsonl",
            limit=None,
        )
