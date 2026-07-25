from __future__ import annotations

import math
import statistics
import warnings
from collections import defaultdict
from collections.abc import Iterable
from typing import Any

import mir_eval
import numpy as np

_PITCHES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
_KEY_RELATION = {
    1.0: "exact",
    0.5: "perfect_fifth",
    0.3: "relative",
    0.2: "parallel",
    0.0: "other",
}


def _mean(values: Iterable[float]) -> float | None:
    items = [float(value) for value in values if math.isfinite(float(value))]
    return round(statistics.fmean(items), 6) if items else None


def _percentile(values: Iterable[float], percentile: float) -> float | None:
    items = sorted(float(value) for value in values if math.isfinite(float(value)))
    if not items:
        return None
    if len(items) == 1:
        return round(items[0], 6)
    position = (len(items) - 1) * percentile
    lower = math.floor(position)
    upper = math.ceil(position)
    value = items[lower] + (items[upper] - items[lower]) * (position - lower)
    return round(value, 6)


def _prediction_key(prediction: dict[str, Any]) -> str | None:
    direct = prediction.get("key")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    key_index = prediction.get("key_index")
    mode = prediction.get("mode")
    if (
        isinstance(key_index, int)
        and not isinstance(key_index, bool)
        and 0 <= key_index < 12
        and mode in {"major", "minor"}
    ):
        return f"{_PITCHES[key_index]} {mode}"
    return None


def _tempo_metrics(reference: float, estimate: Any) -> dict[str, Any]:
    if isinstance(estimate, bool) or not isinstance(estimate, (int, float)):
        return {
            "available": False,
            "acc1": 0.0,
            "acc2": 0.0,
            "octave_class": "missing",
            "absolute_log2_error": None,
        }
    estimate = float(estimate)
    if not math.isfinite(estimate) or estimate <= 0:
        return {
            "available": False,
            "acc1": 0.0,
            "acc2": 0.0,
            "octave_class": "missing",
            "absolute_log2_error": None,
        }
    ratios = {"exact": 1.0, "half": 0.5, "double": 2.0}
    relative_errors = {
        name: abs(estimate - reference * factor) / (reference * factor)
        for name, factor in ratios.items()
    }
    closest = min(relative_errors, key=lambda name: relative_errors[name])
    acc1 = float(relative_errors["exact"] <= 0.04)
    acc2 = float(min(relative_errors.values()) <= 0.04)
    octave_class = closest if relative_errors[closest] <= 0.04 else "other"
    return {
        "available": True,
        "reference_bpm": reference,
        "estimated_bpm": estimate,
        "ratio": round(estimate / reference, 6),
        "acc1": acc1,
        "acc2": acc2,
        "octave_class": octave_class,
        "absolute_log2_error": round(abs(math.log2(estimate / reference)), 6),
    }


def _event_metrics(reference: list[float], estimate_ms: Any) -> dict[str, Any]:
    if not isinstance(estimate_ms, list):
        estimate: list[float] = []
    else:
        estimate = []
        for value in estimate_ms:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            seconds = float(value) / 1000.0
            if math.isfinite(seconds) and seconds >= 0:
                estimate.append(seconds)
        estimate = sorted(set(estimate))
    reference_array = np.asarray(reference, dtype=float)
    estimate_array = np.asarray(estimate, dtype=float)
    if estimate_array.size == 0:
        return {
            "available": False,
            "reference_events": int(reference_array.size),
            "estimated_events": 0,
            "f_measure_70ms": 0.0,
            "cemgil": 0.0,
            "cmlc": 0.0,
            "cmlt": 0.0,
            "amlc": 0.0,
            "amlt": 0.0,
        }
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        f_measure = float(mir_eval.beat.f_measure(reference_array, estimate_array))
        cemgil = float(mir_eval.beat.cemgil(reference_array, estimate_array)[0])
        try:
            cmlc, cmlt, amlc, amlt = (
                float(value)
                for value in mir_eval.beat.continuity(reference_array, estimate_array)
            )
        except (ValueError, ZeroDivisionError):
            cmlc = cmlt = amlc = amlt = 0.0
    return {
        "available": True,
        "reference_events": int(reference_array.size),
        "estimated_events": int(estimate_array.size),
        "f_measure_70ms": round(f_measure, 6),
        "cemgil": round(cemgil, 6),
        "cmlc": round(cmlc, 6),
        "cmlt": round(cmlt, 6),
        "amlc": round(amlc, 6),
        "amlt": round(amlt, 6),
    }


def _key_metrics(reference: str, prediction: dict[str, Any]) -> dict[str, Any]:
    estimate = _prediction_key(prediction)
    if estimate is None:
        return {
            "available": False,
            "reference_key": reference,
            "estimated_key": None,
            "weighted_score": 0.0,
            "relationship": "missing",
            "exact": 0.0,
        }
    score = float(mir_eval.key.weighted_score(reference, estimate))
    relationship = _KEY_RELATION.get(round(score, 1), "other")
    return {
        "available": True,
        "reference_key": reference,
        "estimated_key": estimate,
        "weighted_score": round(score, 6),
        "relationship": relationship,
        "exact": float(score == 1.0),
    }


def score_track(manifest: dict[str, Any], prediction: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": manifest["id"],
        "label_kind": manifest["label_kind"],
        "provenance": manifest["provenance"],
        "status": "infra_error" if prediction.get("error") else "scored",
        "error": prediction.get("error"),
        "metrics": {},
    }
    reference = manifest["reference"]
    metrics = result["metrics"]
    if "bpm" in reference:
        metrics["tempo"] = _tempo_metrics(reference["bpm"], prediction.get("bpm"))
    if "key" in reference:
        metrics["key"] = _key_metrics(reference["key"], prediction)
    if "beats_seconds" in reference:
        metrics["beats"] = _event_metrics(
            reference["beats_seconds"], prediction.get("beats_ms")
        )
    if "downbeats_seconds" in reference:
        metrics["downbeats"] = _event_metrics(
            reference["downbeats_seconds"], prediction.get("downbeats_ms")
        )
    runtime = prediction.get("runtime_seconds")
    if isinstance(runtime, (int, float)) and not isinstance(runtime, bool):
        runtime = float(runtime)
        if math.isfinite(runtime) and runtime >= 0:
            result["runtime_seconds"] = runtime
    result["confidence"] = {
        name: prediction.get(field)
        for name, field in (
            ("tempo", "tempo_confidence"),
            ("key", "key_confidence"),
            ("downbeat", "downbeat_confidence"),
        )
        if isinstance(prediction.get(field), (int, float))
        and not isinstance(prediction.get(field), bool)
    }
    return result


def _summarize_tracks(tracks: list[dict[str, Any]]) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "tracks": len(tracks),
        "infra_errors": sum(track["status"] == "infra_error" for track in tracks),
    }
    runtimes = [
        track["runtime_seconds"] for track in tracks if "runtime_seconds" in track
    ]
    summary["runtime_seconds"] = {
        "p50": _percentile(runtimes, 0.50),
        "p95": _percentile(runtimes, 0.95),
    }
    for task in ("tempo", "beats", "downbeats", "key"):
        task_metrics = [
            track["metrics"][task] for track in tracks if task in track["metrics"]
        ]
        if not task_metrics:
            continue
        task_summary: dict[str, Any] = {
            "references": len(task_metrics),
            "coverage": _mean(
                float(metric.get("available", False)) for metric in task_metrics
            ),
        }
        metric_names = {
            "tempo": ("acc1", "acc2", "absolute_log2_error"),
            "beats": ("f_measure_70ms", "cemgil", "cmlc", "cmlt", "amlc", "amlt"),
            "downbeats": ("f_measure_70ms", "cemgil", "cmlc", "cmlt", "amlc", "amlt"),
            "key": ("exact", "weighted_score"),
        }[task]
        for name in metric_names:
            value = _mean(
                metric[name] for metric in task_metrics if metric.get(name) is not None
            )
            task_summary[name] = value
        if task == "tempo":
            counts = defaultdict(int)
            for metric in task_metrics:
                counts[metric["octave_class"]] += 1
            task_summary["octave_classes"] = dict(sorted(counts.items()))
        if task == "key":
            counts = defaultdict(int)
            for metric in task_metrics:
                counts[metric["relationship"]] += 1
            task_summary["relationships"] = dict(sorted(counts.items()))
        summary[task] = task_summary
    return summary


def build_report(
    manifest: list[dict[str, Any]],
    predictions: dict[str, dict[str, Any]],
    *,
    run: dict[str, Any],
    repo_head: str,
    manifest_sha256: str,
    predictions_sha256: str,
    generated_at: str,
) -> dict[str, Any]:
    tracks = [score_track(item, predictions[item["id"]]) for item in manifest]
    by_kind: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for track in tracks:
        by_kind[track["label_kind"]].append(track)
    return {
        "schema_version": 1,
        "generated_at": generated_at,
        "repo_head": repo_head,
        "manifest_sha256": manifest_sha256,
        "predictions_sha256": predictions_sha256,
        "run": run,
        "counts": {
            "expected": len(manifest),
            "scored": len(tracks),
            "infra_errors": sum(track["status"] == "infra_error" for track in tracks),
        },
        "groups": {
            label_kind: _summarize_tracks(kind_tracks)
            for label_kind, kind_tracks in sorted(by_kind.items())
        },
        "tracks": tracks,
    }
