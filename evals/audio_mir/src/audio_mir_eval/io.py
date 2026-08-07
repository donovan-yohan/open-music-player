from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import mir_eval


class EvalInputError(ValueError):
    """Raised when a manifest or prediction artifact is not comparable."""


_ALLOWED_LABEL_KINDS = {"ground_truth", "external_reference", "synthetic"}
_ALLOWED_EVALUATION_SPLITS = {"calibration", "holdout", "pilot"}
EXPERIMENT_CONTEXT_FIELDS = ("id", "arm", "factor", "freeze_id")
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_EVALUATION_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_EXPERIMENT_VALUE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MIR_EVAL_MAX_EVENT_SECONDS = 30000.0
MIR_EVAL_MAX_STRATA = 64


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvalInputError(f"{field} must be a number")
    try:
        number = float(value)
    except OverflowError as exc:
        raise EvalInputError(f"{field} must be finite") from exc
    if not math.isfinite(number):
        raise EvalInputError(f"{field} must be finite")
    return number


def validate_experiment_context(
    experiment: dict[str, Any] | None,
) -> dict[str, str] | None:
    if experiment is None:
        return None
    if set(experiment) != set(EXPERIMENT_CONTEXT_FIELDS):
        raise EvalInputError(
            "experiment context must contain exactly id, arm, factor, and freeze_id"
        )
    if not all(
        isinstance(experiment[field], str)
        and _EXPERIMENT_VALUE_RE.fullmatch(experiment[field])
        for field in EXPERIMENT_CONTEXT_FIELDS
    ):
        raise EvalInputError("experiment context values must be safe non-empty labels")
    return {field: experiment[field] for field in EXPERIMENT_CONTEXT_FIELDS}


def _event_list(value: Any, field: str) -> list[float]:
    if not isinstance(value, list):
        raise EvalInputError(f"{field} must be an array")
    events = [_finite_number(item, f"{field}[]") for item in value]
    if not events:
        raise EvalInputError(f"{field} cannot be empty")
    if any(item < 0 for item in events):
        raise EvalInputError(f"{field} cannot contain negative positions")
    if any(item > MIR_EVAL_MAX_EVENT_SECONDS for item in events):
        raise EvalInputError(
            f"{field} cannot exceed {MIR_EVAL_MAX_EVENT_SECONDS:g} seconds"
        )
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


def _validated_key(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvalInputError(f"{field} must be a string")
    key = value.strip()
    if key.lower() == "x":
        raise EvalInputError(f"{field} has no annotated key")
    try:
        mir_eval.key.validate(key, key)
    except ValueError as exc:
        raise EvalInputError(f"{field} is not a valid mir_eval key: {key!r}") from exc
    return key


def load_manifest(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    seen_strata: set[str] = set()
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
            bpm = _finite_number(reference["bpm"], f"manifest {track_id}.reference.bpm")
            if bpm <= 0:
                raise EvalInputError(
                    f"manifest {track_id}.reference.bpm must be positive"
                )
            normalized_reference["bpm"] = bpm
        if "key" in reference:
            normalized_reference["key"] = _validated_key(
                reference["key"], f"manifest {track_id}.reference.key"
            )
        for field in ("beats_seconds", "downbeats_seconds"):
            if field in reference:
                normalized_reference[field] = _event_list(
                    reference[field], f"manifest {track_id}.reference.{field}"
                )
        if not normalized_reference:
            raise EvalInputError(
                f"manifest {track_id}: reference has no supported task"
            )

        evaluation_split = raw.get("evaluation_split", "unspecified")
        if (
            evaluation_split != "unspecified"
            and evaluation_split not in _ALLOWED_EVALUATION_SPLITS
        ):
            raise EvalInputError(
                f"manifest {track_id}: evaluation_split must be one of "
                f"{sorted(_ALLOWED_EVALUATION_SPLITS)}"
            )
        stratum = raw.get("stratum", "unspecified")
        if not isinstance(stratum, str) or not _EVALUATION_LABEL_RE.fullmatch(stratum):
            raise EvalInputError(
                f"manifest {track_id}: stratum must be a short safe label"
            )
        if stratum not in seen_strata:
            if len(seen_strata) >= MIR_EVAL_MAX_STRATA:
                raise EvalInputError(
                    f"manifest has more than {MIR_EVAL_MAX_STRATA} strata; "
                    "use a bounded analytical taxonomy"
                )
            seen_strata.add(stratum)

        audio_sha256 = raw.get("audio_sha256")
        if audio_sha256 is not None and (
            not isinstance(audio_sha256, str)
            or not _SHA256_RE.fullmatch(audio_sha256.lower())
        ):
            raise EvalInputError(
                f"manifest {track_id}.audio_sha256 must be 64 hex chars"
            )

        record = dict(raw)
        record["id"] = track_id
        record["label_kind"] = label_kind
        record["reference"] = normalized_reference
        record["evaluation_split"] = evaluation_split
        record["stratum"] = stratum
        if isinstance(audio_sha256, str):
            record["audio_sha256"] = audio_sha256.lower()
        records.append(record)
    return records


def _load_predictions(
    path: Path, *, require_complete: bool
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    run: dict[str, Any] | None = None
    predictions: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(_read_jsonl(path), 1):
        record_type = raw.get("record_type", "prediction")
        if record_type == "run":
            if run is not None:
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

    if run is None:
        raise EvalInputError("prediction artifact is missing its run record")
    if run.get("schema_version") != 2:
        raise EvalInputError("prediction artifact run schema_version must be 2")
    if require_complete and run.get("complete") is not True:
        raise EvalInputError(
            "prediction artifact is incomplete; rerun or resume analysis"
        )
    manifest_sha = run.get("manifest_sha256")
    if not isinstance(manifest_sha, str) or not _SHA256_RE.fullmatch(manifest_sha):
        raise EvalInputError("prediction artifact has an invalid manifest_sha256")
    for field in ("model_sha256", "analyzer_script_sha256"):
        digest = run.get(field)
        if not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest):
            raise EvalInputError(f"prediction artifact has an invalid {field}")
    if not isinstance(run.get("repo_head"), str) or not run["repo_head"]:
        raise EvalInputError("prediction artifact is missing repo_head")
    if not isinstance(run.get("analyzer"), dict):
        raise EvalInputError("prediction artifact is missing analyzer metadata")
    if run.get("prediction_count") != len(predictions):
        raise EvalInputError("prediction artifact count does not match its run record")
    if require_complete and not predictions:
        raise EvalInputError("prediction artifact contains no predictions")
    return run, predictions


def load_predictions(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    return _load_predictions(path, require_complete=True)


def load_partial_predictions(
    path: Path,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    return _load_predictions(path, require_complete=False)


def _fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as handle:
            temp_name = handle.name
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        old_umask = os.umask(0)
        os.umask(old_umask)
        os.chmod(temp_name, 0o666 & ~old_umask)
        os.replace(temp_name, path)
        _fsync_directory(path.parent)
    except Exception:
        if temp_name is not None:
            Path(temp_name).unlink(missing_ok=True)
        raise


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    content = "".join(
        json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
        for record in records
    )
    _atomic_write(path, content)


def write_manifest(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".manifest", dir=path.parent
    )
    os.close(descriptor)
    temp_path = Path(temp_name)
    try:
        write_jsonl(temp_path, records)
        load_manifest(temp_path)
        os.replace(temp_path, path)
        _fsync_directory(path.parent)
    finally:
        temp_path.unlink(missing_ok=True)


def write_json(path: Path, value: dict[str, Any]) -> None:
    _atomic_write(path, json.dumps(value, sort_keys=True, indent=2) + "\n")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_head(repo_root: Path) -> str:
    repo_root = repo_root.resolve()
    git = shutil.which("git")
    if git is None:
        return "unknown"
    git = str(Path(git).resolve())
    try:
        top_level = subprocess.run(
            [git, "rev-parse", "--show-toplevel"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        if not top_level or Path(top_level).resolve() != repo_root:
            return "unknown"
        completed = subprocess.run(
            [git, "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return completed.stdout.strip() or "unknown"


def repo_is_clean(repo_root: Path) -> bool:
    """Return whether ``repo_root`` is the exact, clean checkout root.

    A commit SHA alone cannot identify scorer or analyzer code when local edits
    are present. Reports may still be generated from a dirty tree for debugging,
    but promotion rejects them.
    """
    repo_root = repo_root.resolve()
    git = shutil.which("git")
    if git is None:
        return False
    git = str(Path(git).resolve())
    try:
        top_level = subprocess.run(
            [git, "rev-parse", "--show-toplevel"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        if not top_level or Path(top_level).resolve() != repo_root:
            return False
        status = subprocess.run(
            [git, "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return not status.strip()
