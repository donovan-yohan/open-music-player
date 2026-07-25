from __future__ import annotations

import json
import os
import zipfile
from pathlib import Path
from typing import Any

from .io import EvalInputError, sha256_file, write_manifest

_SOURCE = "https://doi.org/10.5281/zenodo.3371780"
_AUDIO_SUFFIXES = {".wav", ".flac", ".mp3", ".ogg", ".m4a"}


def _audio_index(audio_dir: Path) -> dict[str, Path]:
    index: dict[str, Path] = {}
    for path in sorted(audio_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in _AUDIO_SUFFIXES:
            continue
        keys = {path.stem}
        for suffix in ("_mic", "_mix", "_mono", "_mono-mic"):
            if path.stem.endswith(suffix):
                keys.add(path.stem[: -len(suffix)])
        for key in keys:
            previous = index.get(key)
            if previous is not None and previous != path:
                raise EvalInputError(f"multiple GuitarSet audio files match {key}")
            index[key] = path
    return index


def _annotation(document: dict[str, Any], namespace: str) -> dict[str, Any]:
    annotations = document.get("annotations")
    if not isinstance(annotations, list):
        raise EvalInputError("GuitarSet JAMS document has no annotations array")
    matches = [item for item in annotations if item.get("namespace") == namespace]
    if len(matches) != 1:
        raise EvalInputError(
            f"GuitarSet JAMS document must contain exactly one {namespace} annotation"
        )
    return matches[0]


def _data(annotation: dict[str, Any], namespace: str) -> list[dict[str, Any]]:
    data = annotation.get("data")
    if not isinstance(data, list) or not data:
        raise EvalInputError(f"GuitarSet {namespace} annotation has no data")
    if not all(isinstance(item, dict) for item in data):
        raise EvalInputError(f"GuitarSet {namespace} data must contain objects")
    return data


def _key_label(value: Any) -> str:
    if not isinstance(value, str) or ":" not in value:
        raise EvalInputError("GuitarSet key_mode value is invalid")
    tonic, mode = value.split(":", 1)
    mode = {"maj": "major", "min": "minor"}.get(mode, mode)
    if not tonic or mode not in {"major", "minor"}:
        raise EvalInputError("GuitarSet key_mode value is invalid")
    return f"{tonic} {mode}"


def _reference(document: dict[str, Any]) -> dict[str, Any]:
    beat_rows = _data(_annotation(document, "beat_position"), "beat_position")
    beats: list[float] = []
    downbeats: list[float] = []
    for row in beat_rows:
        time = row.get("time")
        value = row.get("value")
        if not isinstance(time, (int, float)) or isinstance(time, bool) or time < 0:
            raise EvalInputError("GuitarSet beat_position time is invalid")
        position = value.get("position") if isinstance(value, dict) else None
        if not isinstance(position, int) or isinstance(position, bool):
            raise EvalInputError("GuitarSet beat_position value is invalid")
        beats.append(float(time))
        if position == 1:
            downbeats.append(float(time))
    beats = sorted(set(beats))
    downbeats = sorted(set(downbeats))

    tempo_rows = _data(_annotation(document, "tempo"), "tempo")
    if len(tempo_rows) != 1:
        raise EvalInputError("GuitarSet global tempo must contain exactly one row")
    bpm = tempo_rows[0].get("value")
    if not isinstance(bpm, (int, float)) or isinstance(bpm, bool) or bpm <= 0:
        raise EvalInputError("GuitarSet tempo value is invalid")

    key_rows = _data(_annotation(document, "key_mode"), "key_mode")
    if len(key_rows) != 1:
        raise EvalInputError("GuitarSet global key must contain exactly one row")
    reference = {
        "bpm": float(bpm),
        "beats_seconds": beats,
        "key": _key_label(key_rows[0].get("value")),
    }
    if downbeats:
        reference["downbeats_seconds"] = downbeats
    return reference


def prepare_manifest(
    annotation_zip: Path,
    audio_dir: Path,
    *,
    output_path: Path,
    limit: int | None,
) -> tuple[int, int]:
    if limit is not None and limit <= 0:
        raise EvalInputError("limit must be positive")
    if not annotation_zip.is_file():
        raise EvalInputError(
            f"GuitarSet annotation archive does not exist: {annotation_zip}"
        )
    annotation_archive_sha256 = sha256_file(annotation_zip)
    if not audio_dir.is_dir():
        raise EvalInputError(f"GuitarSet audio directory does not exist: {audio_dir}")
    audio_by_stem = _audio_index(audio_dir)
    records: list[dict[str, Any]] = []
    missing_audio = 0
    try:
        archive = zipfile.ZipFile(annotation_zip)
    except zipfile.BadZipFile as exc:
        raise EvalInputError("GuitarSet annotation archive is not a ZIP file") from exc
    with archive:
        names = sorted(name for name in archive.namelist() if name.endswith(".jams"))
        for name in names:
            stem = Path(name).stem
            audio_path = audio_by_stem.get(stem)
            if audio_path is None:
                missing_audio += 1
                continue
            try:
                document = json.loads(archive.read(name))
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise EvalInputError(f"invalid GuitarSet annotation: {name}") from exc
            if not isinstance(document, dict):
                raise EvalInputError(f"invalid GuitarSet annotation object: {name}")
            records.append(
                {
                    "id": f"guitarset-1.1.0:{stem}",
                    "audio_path": os.path.relpath(audio_path, output_path.parent),
                    "audio_sha256": sha256_file(audio_path),
                    "label_kind": "ground_truth",
                    "provenance": {
                        "dataset": "guitarset-1.1.0",
                        "source": _SOURCE,
                        "annotation_file": name,
                        "annotation_archive_sha256": annotation_archive_sha256,
                        "license": "CC-BY-4.0",
                    },
                    "reference": _reference(document),
                }
            )
            if limit is not None and len(records) >= limit:
                break
    if not records:
        raise EvalInputError("no matching GuitarSet audio and annotations were found")
    write_manifest(output_path, records)
    return len(records), missing_audio
