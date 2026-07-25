from __future__ import annotations

import json
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .io import EvalInputError, sha256_file, write_jsonl


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
        raise EvalInputError(
            f"analyzer exited {completed.returncode}; stderr was captured but is not embedded"
        )
    return _parse_analyzer_json(completed.stdout, "analyzer"), runtime


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
    run_record: dict[str, Any] = {
        "record_type": "run",
        "schema_version": 1,
        "created_at": datetime.now(UTC).isoformat(),
        "repo_head": repo_head,
        "manifest_sha256": sha256_file(manifest_path),
        "analyzer": metadata,
    }
    predictions: list[dict[str, Any]] = []
    errors = 0
    for item in manifest:
        track_id = item["id"]
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
            prediction.update(result)
            prediction["audio_sha256"] = audio_sha256
            prediction["runtime_seconds"] = round(runtime, 6)
        except (EvalInputError, OSError, subprocess.SubprocessError) as exc:
            errors += 1
            prediction["error"] = {
                "type": type(exc).__name__,
                "message": str(exc)[:500],
            }
        predictions.append(prediction)
    write_jsonl(output_path, [run_record, *predictions])
    return len(predictions), errors
