from __future__ import annotations

import json
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .io import (
    EvalInputError,
    load_partial_predictions,
    sha256_file,
    write_jsonl,
)

_ANALYZER_RESULT_FIELDS = {
    "bpm",
    "tempo_confidence",
    "beats_ms",
    "downbeats_ms",
    "downbeat_confidence",
    "key_index",
    "mode",
    "key_confidence",
}


def _parse_analyzer_json(stdout: str, context: str) -> dict[str, Any]:
    try:
        value = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise EvalInputError(f"{context}: analyzer emitted invalid JSON") from exc
    if not isinstance(value, dict):
        raise EvalInputError(f"{context}: analyzer output must be an object")
    return value


def _invoke(command: list[str], timeout_seconds: float) -> tuple[dict[str, Any], float]:
    started = time.monotonic()
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
    runtime = time.monotonic() - started
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        detail = f": {stderr[-500:]}" if stderr else ""
        raise EvalInputError(f"analyzer exited {completed.returncode}{detail}")
    return _parse_analyzer_json(completed.stdout, "analyzer"), runtime


def _persist(
    output_path: Path,
    run_record: dict[str, Any],
    predictions: dict[str, dict[str, Any]],
    manifest_ids: list[str],
    *,
    complete: bool,
) -> None:
    run_record["updated_at"] = datetime.now(UTC).isoformat()
    run_record["prediction_count"] = len(predictions)
    run_record["complete"] = complete
    ordered = [
        predictions[track_id] for track_id in manifest_ids if track_id in predictions
    ]
    write_jsonl(output_path, [run_record, *ordered])


def run_analyzer(
    manifest: list[dict[str, Any]],
    *,
    manifest_path: Path,
    analyzer_python: Path,
    analyzer_script: Path,
    model_path: Path,
    output_path: Path,
    repo_head: str,
    timeout_seconds: float,
    resume: bool = False,
) -> tuple[int, int]:
    for path, label in (
        (analyzer_python, "analyzer Python"),
        (analyzer_script, "analyzer script"),
        (model_path, "analyzer model"),
    ):
        if not path.is_file():
            raise EvalInputError(f"{label} does not exist: {path}")
    if timeout_seconds <= 0:
        raise EvalInputError("timeout must be positive")

    metadata, _ = _invoke(
        [
            str(analyzer_python),
            str(analyzer_script),
            "--check",
            "--model",
            str(model_path),
        ],
        timeout_seconds,
    )
    manifest_sha256 = sha256_file(manifest_path)
    manifest_ids = [item["id"] for item in manifest]
    run_record: dict[str, Any] = {
        "record_type": "run",
        "schema_version": 2,
        "created_at": datetime.now(UTC).isoformat(),
        "repo_head": repo_head,
        "manifest_sha256": manifest_sha256,
        "model_sha256": sha256_file(model_path),
        "analyzer_script_sha256": sha256_file(analyzer_script),
        "analyzer": metadata,
    }
    predictions: dict[str, dict[str, Any]] = {}

    if resume and output_path.exists():
        existing_run, existing_predictions = load_partial_predictions(output_path)
        for field, label in (
            ("manifest_sha256", "manifest_sha256"),
            ("repo_head", "repo_head"),
            ("model_sha256", "model checkpoint"),
            ("analyzer_script_sha256", "analyzer script"),
            ("analyzer", "analyzer metadata"),
        ):
            if existing_run.get(field) != run_record[field]:
                raise EvalInputError(f"cannot resume: {label} changed")
        unexpected = set(existing_predictions) - set(manifest_ids)
        if unexpected:
            raise EvalInputError(
                f"cannot resume: artifact contains unexpected ids: {sorted(unexpected)[:3]}"
            )
        run_record["created_at"] = existing_run.get(
            "created_at", run_record["created_at"]
        )
        predictions = {
            track_id: prediction
            for track_id, prediction in existing_predictions.items()
            if not prediction.get("error")
        }

    _persist(output_path, run_record, predictions, manifest_ids, complete=False)
    for item in manifest:
        track_id = item["id"]
        if track_id in predictions:
            continue
        raw_audio_path = item.get("audio_path")
        prediction: dict[str, Any] = {"record_type": "prediction", "id": track_id}
        try:
            if not isinstance(raw_audio_path, str) or not raw_audio_path:
                raise EvalInputError("manifest record has no audio_path")
            audio_path = Path(raw_audio_path)
            if not audio_path.is_absolute():
                audio_path = (manifest_path.parent / audio_path).resolve()
            if not audio_path.is_file():
                raise EvalInputError(f"audio file does not exist: {audio_path}")
            audio_sha256 = sha256_file(audio_path)
            expected_sha256 = item.get("audio_sha256")
            if expected_sha256 is not None and expected_sha256 != audio_sha256:
                raise EvalInputError("audio_sha256 mismatch")
            result, runtime = _invoke(
                [
                    str(analyzer_python),
                    str(analyzer_script),
                    "--model",
                    str(model_path),
                    str(audio_path),
                ],
                timeout_seconds,
            )
            prediction.update(
                {
                    key: value
                    for key, value in result.items()
                    if key in _ANALYZER_RESULT_FIELDS
                }
            )
            prediction["audio_sha256"] = audio_sha256
            prediction["runtime_seconds"] = round(runtime, 6)
        except (EvalInputError, OSError, subprocess.SubprocessError) as exc:
            prediction["error"] = {
                "type": type(exc).__name__,
                "message": str(exc)[:500],
            }
        predictions[track_id] = prediction
        _persist(output_path, run_record, predictions, manifest_ids, complete=False)

    _persist(output_path, run_record, predictions, manifest_ids, complete=True)
    errors = sum(bool(prediction.get("error")) for prediction in predictions.values())
    return len(predictions), errors
