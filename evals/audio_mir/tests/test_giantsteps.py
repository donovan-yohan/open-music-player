from __future__ import annotations

import json
from pathlib import Path

from audio_mir_eval.giantsteps import prepare_manifest


def test_prepare_tempo_prefers_v2_and_only_includes_present_audio(tmp_path: Path):
    dataset = tmp_path / "dataset"
    annotations = dataset / "annotations_v2" / "tempo"
    audio = dataset / "audio"
    annotations.mkdir(parents=True)
    audio.mkdir()
    (annotations / "one.LOFI.bpm").write_text("128.0\n", encoding="utf-8")
    (annotations / "missing.LOFI.bpm").write_text("99.0\n", encoding="utf-8")
    (audio / "one.LOFI.mp3").write_bytes(b"fixture")
    output = tmp_path / "manifest.jsonl"

    count, missing = prepare_manifest(
        dataset, task="tempo", output_path=output, limit=None
    )

    row = json.loads(output.read_text(encoding="utf-8"))
    assert count == 1
    assert missing == 1
    assert row["id"] == "giantsteps-tempo-v2:one.LOFI"
    assert row["reference"] == {"bpm": 128.0}
    assert row["label_kind"] == "ground_truth"
    assert row["provenance"]["license"].startswith("unspecified")
    assert row["provenance"]["source_revision"] == "unknown"


def test_prepare_key_keeps_mirex_key_label(tmp_path: Path):
    dataset = tmp_path / "dataset"
    annotations = dataset / "annotations" / "key"
    audio = dataset / "audio"
    annotations.mkdir(parents=True)
    audio.mkdir()
    (annotations / "one.LOFI.key").write_text("C# minor\n", encoding="utf-8")
    (audio / "one.LOFI.mp3").write_bytes(b"fixture")
    output = tmp_path / "manifest.jsonl"

    count, missing = prepare_manifest(dataset, task="key", output_path=output, limit=1)

    row = json.loads(output.read_text(encoding="utf-8"))
    assert (count, missing) == (1, 0)
    assert row["reference"] == {"key": "C# minor"}
