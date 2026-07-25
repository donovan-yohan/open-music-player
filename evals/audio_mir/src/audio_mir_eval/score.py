from __future__ import annotations

import math
import statistics
import warnings
from collections import defaultdict
from collections.abc import Iterable
from typing import Any

import mir_eval
import numpy as np

from .io import MIR_EVAL_MAX_EVENT_SECONDS

_PITCHES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")
_KEY_RELATION = {
    1.0: "exact",
    0.5: "perfect_fifth",
    0.3: "relative",
    0.2: "parallel",
    0.0: "other",
}
_TEMPO_FACTORS = {
    "one_third": 1.0 / 3.0,
    "half": 0.5,
    "exact": 1.0,
    "double": 2.0,
    "triple": 3.0,
}
_EVENT_METRIC_NAMES = ("f_measure_70ms", "cemgil", "cmlc", "cmlt", "amlc", "amlt")
_TASK_METRIC_NAMES = {
    "tempo": ("acc1", "acc2", "absolute_log2_error"),
    "beats": _EVENT_METRIC_NAMES,
    "downbeats": _EVENT_METRIC_NAMES,
    "key": ("exact", "weighted_score"),
}
_BEAT_TRIM_SECONDS = 5.0


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
    if (
        isinstance(estimate, bool)
        or not isinstance(estimate, (int, float))
        or not math.isfinite(float(estimate))
        or float(estimate) <= 0
    ):
        return {
            "available": False,
            "acc1": 0.0,
            "acc2": 0.0,
            "tempo_class": "missing",
            "absolute_log2_error": None,
        }

    estimate = float(estimate)
    relative_errors = {
        name: abs(estimate - reference * factor) / (reference * factor)
        for name, factor in _TEMPO_FACTORS.items()
    }
    closest = min(relative_errors, key=relative_errors.__getitem__)
    return {
        "available": True,
        "reference_bpm": reference,
        "estimated_bpm": estimate,
        "ratio": round(estimate / reference, 6),
        "acc1": float(relative_errors["exact"] <= 0.04),
        "acc2": float(min(relative_errors.values()) <= 0.04),
        "tempo_class": closest if relative_errors[closest] <= 0.04 else "other",
        "absolute_log2_error": round(abs(math.log2(estimate / reference)), 6),
    }


def _event_estimates(estimate_ms: Any) -> tuple[list[float], int]:
    if not isinstance(estimate_ms, list):
        return [], 0
    estimate = []
    dropped = 0
    for value in estimate_ms:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            dropped += 1
            continue
        seconds = float(value) / 1000.0
        if (
            not math.isfinite(seconds)
            or seconds < 0
            or seconds > MIR_EVAL_MAX_EVENT_SECONDS
        ):
            dropped += 1
            continue
        estimate.append(seconds)
    return sorted(set(estimate)), dropped


def _event_metrics(reference: list[float], estimate_ms: Any) -> dict[str, Any]:
    estimate, dropped_estimates = _event_estimates(estimate_ms)
    reference_array = np.asarray(reference, dtype=float)
    estimate_array = np.asarray(estimate, dtype=float)
    evaluated_reference = mir_eval.beat.trim_beats(
        reference_array, min_beat_time=_BEAT_TRIM_SECONDS
    )
    evaluated_estimate = mir_eval.beat.trim_beats(
        estimate_array, min_beat_time=_BEAT_TRIM_SECONDS
    )
    common = {
        "reference_events": int(reference_array.size),
        "estimated_events": int(estimate_array.size),
        "evaluated_reference_events": int(evaluated_reference.size),
        "evaluated_estimated_events": int(evaluated_estimate.size),
        "dropped_estimated_events": dropped_estimates,
        "trim_seconds": _BEAT_TRIM_SECONDS,
    }
    if evaluated_reference.size == 0:
        return {
            "available": False,
            "evaluable": False,
            **common,
            **dict.fromkeys(_EVENT_METRIC_NAMES),
        }
    if evaluated_estimate.size == 0:
        return {
            "available": False,
            "evaluable": True,
            **common,
            **dict.fromkeys(_EVENT_METRIC_NAMES, 0.0),
        }

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        f_measure = float(
            mir_eval.beat.f_measure(evaluated_reference, evaluated_estimate)
        )
        cemgil = float(mir_eval.beat.cemgil(evaluated_reference, evaluated_estimate)[0])
        cmlc, cmlt, amlc, amlt = (
            float(value)
            for value in mir_eval.beat.continuity(
                evaluated_reference, evaluated_estimate
            )
        )
    result = {
        "available": True,
        "evaluable": True,
        **common,
        "f_measure_70ms": round(f_measure, 6),
        "cemgil": round(cemgil, 6),
        "cmlc": round(cmlc, 6),
        "cmlt": round(cmlt, 6),
        "amlc": round(amlc, 6),
        "amlt": round(amlt, 6),
    }
    warning_messages = sorted({str(item.message) for item in caught})
    if warning_messages:
        result["warnings"] = warning_messages
    return result


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
    return {
        "available": True,
        "reference_key": reference,
        "estimated_key": estimate,
        "weighted_score": round(score, 6),
        "relationship": _KEY_RELATION.get(round(score, 1), "other"),
        "exact": float(score == 1.0),
    }


def score_track(manifest: dict[str, Any], prediction: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": manifest["id"],
        "label_kind": manifest["label_kind"],
        "provenance": manifest["provenance"],
        "status": "infra_error" if prediction.get("error") else "scored",
        "metrics": {},
    }
    if prediction.get("error"):
        result["error"] = prediction["error"]

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
        name: prediction[field]
        for name, field in (
            ("tempo", "tempo_confidence"),
            ("key", "key_confidence"),
            ("downbeat", "downbeat_confidence"),
        )
        if isinstance(prediction.get(field), (int, float))
        and not isinstance(prediction[field], bool)
        and math.isfinite(float(prediction[field]))
    }
    return result


def _histogram(metrics: list[dict[str, Any]], field: str) -> dict[str, int]:
    counts = defaultdict(int)
    for metric in metrics:
        counts[str(metric[field])] += 1
    return dict(sorted(counts.items()))


def _summarize_tracks(tracks: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [track for track in tracks if track["status"] == "scored"]
    summary: dict[str, Any] = {
        "tracks": len(tracks),
        "completed": len(completed),
        "infra_errors": len(tracks) - len(completed),
    }
    runtimes = [
        track["runtime_seconds"] for track in completed if "runtime_seconds" in track
    ]
    summary["runtime_seconds"] = {
        "p50": _percentile(runtimes, 0.50),
        "p95": _percentile(runtimes, 0.95),
    }

    for task, metric_names in _TASK_METRIC_NAMES.items():
        task_tracks = [track for track in tracks if task in track["metrics"]]
        if not task_tracks:
            continue
        eligible = [track for track in task_tracks if track["status"] == "scored"]
        metrics = [track["metrics"][task] for track in eligible]
        evaluable = [metric for metric in metrics if metric.get("evaluable", True)]
        available = [metric for metric in evaluable if metric.get("available", False)]
        task_summary: dict[str, Any] = {
            "references": len(task_tracks),
            "evaluated": len(evaluable),
            "infra_errors": len(task_tracks) - len(eligible),
            "unevaluable_references": len(metrics) - len(evaluable),
            "abstentions": len(evaluable) - len(available),
            "coverage": round(len(available) / len(evaluable), 6)
            if evaluable
            else None,
        }
        for name in metric_names:
            task_summary[name] = _mean(
                metric[name] for metric in evaluable if metric.get(name) is not None
            )
        if task == "tempo":
            task_summary["tempo_classes"] = _histogram(evaluable, "tempo_class")
        elif task == "key":
            task_summary["relationships"] = _histogram(evaluable, "relationship")
        summary[task] = task_summary
    return summary


def build_report(
    manifest: list[dict[str, Any]],
    predictions: dict[str, dict[str, Any]],
    *,
    run: dict[str, Any],
    scorer_repo_head: str,
    manifest_sha256: str,
    predictions_sha256: str,
    generated_at: str,
) -> dict[str, Any]:
    tracks = [score_track(item, predictions[item["id"]]) for item in manifest]
    by_kind: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for track in tracks:
        by_kind[track["label_kind"]].append(track)
    completed = sum(track["status"] == "scored" for track in tracks)
    return {
        "schema_version": 2,
        "generated_at": generated_at,
        "scorer_repo_head": scorer_repo_head,
        "manifest_sha256": manifest_sha256,
        "predictions_sha256": predictions_sha256,
        "run": {key: value for key, value in run.items() if key != "record_type"},
        "counts": {
            "expected": len(manifest),
            "predictions": len(tracks),
            "completed": completed,
            "infra_errors": len(tracks) - completed,
        },
        "groups": {
            label_kind: _summarize_tracks(kind_tracks)
            for label_kind, kind_tracks in sorted(by_kind.items())
        },
        "tracks": tracks,
    }
