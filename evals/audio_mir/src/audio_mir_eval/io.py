from __future__ import annotations

import hashlib
import json
import math
import os
import re
import subprocess
import tempfile
from collections.abc import Iterable
from pathlib import Path
from typing import Any


class EvalInputError(ValueError):
    """Raised when a manifest or prediction artifact is not comparable."""


_ALLOWED_LABEL_KINDS = {"ground_truth", "external_reference", "synthetic"}
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")


def _finite_number(value: Any, field: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvalInputError(f"{field} must be a number")
    number = float(value)
    if not math.isfinite(number) or (positive and number <= 0):
        qualifier = "positive and finite" if positive else "finite"
        raise EvalInputError(f"{field} must be {qualifier}")
    return number


def _event_list(value: Any, field: str) -> list[float]:
    if not isinstance(value, list):
        raise EvalInputError(f"{field} must be an array")
    events = [_finite_number(item, f"{field}[]") for item in value]
    if any(item < 0 for item in events):
        raise EvalInputError(f"{field} cannot contain negative positions")
    if events != sorted(set(events)):
        raise EvalInputError(f"{field} must be strictly increasing and unique")
    return events


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise EvalInputError(f"file does not exist: {path}")
    rows: list[dict[str, Any]] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise EvalInputError(f"{path}:{line_number}: invalid JSON") from exc
        if not isinstance(value, dict):
            raise EvalInputError(f"{path}:{line_number}: expected a JSON object")
        rows.append(value)
    if not rows:
        raise EvalInputError(f"file contains no records: {path}")
    return rows


def load_manifest(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, raw in enumerate(_read_jsonl(path), 1):
        track_id = raw.get("id")
        if not isinstance(track_id, str) or not _ID_RE.fullmatch(track_id):
            raise EvalInputError(f"manifest record {index}: invalid id")
        if track_id in seen:
            raise EvalInputError(f"manifest contains duplicate id: {track_id}")
        seen.add(track_id)

        label_kind = raw.get("label_kind")
        if label_kind not in _ALLOWED_LABEL_KINDS:
            raise EvalInputError(
                f"manifest {track_id}: label_kind must be one of {sorted(_ALLOWED_LABEL_KINDS)}"
            )
        provenance = raw.get("provenance")
        if not isinstance(provenance, dict) or not isinstance(
            provenance.get("dataset"), str
        ):
            raise EvalInputError(f"manifest {track_id}: provenance.dataset is required")
        reference = raw.get("reference")
        if not isinstance(reference, dict):
            raise EvalInputError(f"manifest {track_id}: reference must be an object")

        normalized_reference: dict[str, Any] = {}
        if "bpm" in reference:
            normalized_reference["bpm"] = _finite_number(
                reference["bpm"], f"manifest {track_id}.reference.bpm", positive=True
            )
        if "key" in reference:
            key = reference["key"]
            if not isinstance(key, str) or not key.strip():
                raise EvalInputError(
                    f"manifest {track_id}.reference.key must be a string"
                )
            normalized_reference["key"] = key.strip()
        for field in ("beats_seconds", "downbeats_seconds"):
            if field in reference:
                normalized_reference[field] = _event_list(
                    reference[field], f"manifest {track_id}.reference.{field}"
                )
                if not normalized_reference[field]:
                    raise EvalInputError(
                        f"manifest {track_id}.reference.{field} cannot be empty"
                    )
        if not normalized_reference:
            raise EvalInputError(
                f"manifest {track_id}: reference has no supported task"
            )

        record = dict(raw)
        record["id"] = track_id
        record["label_kind"] = label_kind
        record["reference"] = normalized_reference
        records.append(record)
    return records


def load_predictions(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    run: dict[str, Any] = {}
    predictions: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(_read_jsonl(path), 1):
        record_type = raw.get("record_type", "prediction")
        if record_type == "run":
            if run:
                raise EvalInputError(
                    "prediction artifact contains multiple run records"
                )
            run = raw
            continue
        if record_type != "prediction":
            raise EvalInputError(
                f"prediction record {index}: unknown record_type {record_type!r}"
            )
        track_id = raw.get("id")
        if not isinstance(track_id, str) or not _ID_RE.fullmatch(track_id):
            raise EvalInputError(f"prediction record {index}: invalid id")
        if track_id in predictions:
            raise EvalInputError(f"predictions contain duplicate id: {track_id}")
        predictions[track_id] = raw
    if not predictions:
        raise EvalInputError("prediction artifact contains no predictions")
    return run, predictions


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = "".join(
        json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
        for record in records
    )
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temp_name = handle.name
    os.replace(temp_name, path)


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(value, sort_keys=True, indent=2) + "\n"
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temp_name = handle.name
    os.replace(temp_name, path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_head(repo_root: Path) -> str:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return completed.stdout.strip() or "unknown"
