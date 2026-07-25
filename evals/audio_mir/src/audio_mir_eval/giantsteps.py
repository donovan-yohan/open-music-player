from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .io import EvalInputError, repo_head, sha256_file, write_manifest

_SOURCE = {
    "tempo": "https://github.com/GiantSteps/giantsteps-tempo-dataset",
    "key": "https://github.com/GiantSteps/giantsteps-key-dataset",
}


def _annotation_dir(root: Path, task: str) -> Path:
    if task == "tempo":
        v2 = root / "annotations_v2" / "tempo"
        return v2 if v2.is_dir() else root / "annotations" / "tempo"
    return root / "annotations" / "key"


def prepare_manifest(
    dataset_root: Path,
    *,
    task: str,
    output_path: Path,
    limit: int | None,
) -> tuple[int, int]:
    dataset_root = dataset_root.resolve()
    source_revision = repo_head(dataset_root)
    if task not in {"tempo", "key"}:
        raise EvalInputError("GiantSteps task must be tempo or key")
    if limit is not None and limit <= 0:
        raise EvalInputError("limit must be positive")
    annotations = _annotation_dir(dataset_root, task)
    audio_dir = dataset_root / "audio"
    if not annotations.is_dir() or not audio_dir.is_dir():
        raise EvalInputError(
            f"GiantSteps root must contain {annotations.relative_to(dataset_root)} and audio/"
        )
    extension = ".bpm" if task == "tempo" else ".key"
    records: list[dict[str, Any]] = []
    missing_audio = 0
    for annotation_path in sorted(annotations.glob(f"*{extension}")):
        audio_name = annotation_path.name[: -len(extension)] + ".mp3"
        audio_path = audio_dir / audio_name
        if not audio_path.is_file():
            missing_audio += 1
            continue
        raw = annotation_path.read_text(encoding="utf-8").strip()
        reference: dict[str, Any]
        if task == "tempo":
            try:
                bpm = float(raw.split()[0])
            except (IndexError, ValueError) as exc:
                raise EvalInputError(
                    f"invalid tempo annotation: {annotation_path}"
                ) from exc
            if bpm <= 0:
                raise EvalInputError(
                    f"non-positive tempo annotation: {annotation_path}"
                )
            reference = {"bpm": bpm}
            dataset = (
                "giantsteps-tempo-v2"
                if "annotations_v2" in annotations.parts
                else "giantsteps-tempo"
            )
        else:
            if not raw:
                raise EvalInputError(f"empty key annotation: {annotation_path}")
            reference = {"key": raw}
            dataset = "giantsteps-key"
        records.append(
            {
                "id": f"{dataset}:{annotation_path.name[: -len(extension)]}",
                "audio_path": os.path.relpath(audio_path, output_path.parent),
                "audio_sha256": sha256_file(audio_path),
                "label_kind": "ground_truth",
                "provenance": {
                    "dataset": dataset,
                    "source": _SOURCE[task],
                    "source_revision": source_revision,
                    "annotation_file": str(annotation_path.relative_to(dataset_root)),
                    "license": "unspecified by the dataset repository; do not redistribute",
                },
                "reference": reference,
            }
        )
        if limit is not None and len(records) >= limit:
            break
    if not records:
        raise EvalInputError("no matching GiantSteps audio and annotations were found")
    write_manifest(output_path, records)
    return len(records), missing_audio
