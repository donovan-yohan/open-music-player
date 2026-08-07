from __future__ import annotations

import math
import statistics
import warnings
from bisect import bisect_left
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
_EVENT_TOLERANCE_SECONDS = 0.07
_CONFIDENCE_THRESHOLDS = tuple(index / 10.0 for index in range(11))
_PHASE_CONFUSION_NAMES = (
    "on_downbeat",
    "one_beat_shift",
    "two_beat_shift",
    "three_beat_shift",
    "other_beat_shift",
    "off_grid",
    "unanchored",
)


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
        try:
            seconds = float(value) / 1000.0
        except OverflowError:
            dropped += 1
            continue
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


def _local_tempo_metrics(
    reference_beats: list[float], estimate_ms: Any
) -> dict[str, Any]:
    """Score local beat intervals only where adjacent reference beats are matched.

    A global BPM can be correct while a grid drifts, skips beats, or loses a
    transition.  This deliberately does not fill those gaps: coverage is the
    fraction of annotation-bounded reference intervals for which both endpoints
    have a one-to-one estimate match.
    """
    estimate, dropped_estimates = _event_estimates(estimate_ms)
    reference = mir_eval.beat.trim_beats(
        np.asarray(reference_beats, dtype=float), min_beat_time=_BEAT_TRIM_SECONDS
    )
    estimated = mir_eval.beat.trim_beats(
        np.asarray(estimate, dtype=float), min_beat_time=_BEAT_TRIM_SECONDS
    )
    reference_intervals = max(int(reference.size) - 1, 0)
    common = {
        "reference_intervals": reference_intervals,
        "estimated_events": int(estimated.size),
        "dropped_estimated_events": dropped_estimates,
        "trim_seconds": _BEAT_TRIM_SECONDS,
    }
    if reference_intervals == 0:
        return {
            "available": False,
            "evaluable": False,
            **common,
            "matched_intervals": 0,
            "coverage": None,
            "mean_absolute_relative_error": None,
            "within_4_percent": None,
        }

    matches = _one_to_one_matches(
        reference, estimated, tolerance_seconds=_EVENT_TOLERANCE_SECONDS
    )
    matched_estimates = {
        reference_index: estimate_index for reference_index, estimate_index in matches
    }
    errors: list[float] = []
    for reference_index in range(reference_intervals):
        first_estimate = matched_estimates.get(reference_index)
        second_estimate = matched_estimates.get(reference_index + 1)
        if first_estimate is None or second_estimate is None:
            continue
        reference_interval = float(
            reference[reference_index + 1] - reference[reference_index]
        )
        estimated_interval = float(
            estimated[second_estimate] - estimated[first_estimate]
        )
        if reference_interval <= 0 or estimated_interval <= 0:
            continue
        errors.append(abs(estimated_interval - reference_interval) / reference_interval)
    matched_intervals = len(errors)
    return {
        "available": bool(matched_intervals),
        "evaluable": True,
        **common,
        "matched_intervals": matched_intervals,
        "coverage": round(matched_intervals / reference_intervals, 6),
        "mean_absolute_relative_error": _mean(errors),
        "within_4_percent": round(
            sum(error <= 0.04 for error in errors) / matched_intervals, 6
        )
        if matched_intervals
        else None,
    }


def _one_to_one_matches(
    reference: np.ndarray, estimate: np.ndarray, *, tolerance_seconds: float
) -> list[tuple[int, int]]:
    """Chronologically match sorted events once without quadratic pair expansion."""
    reference_index = 0
    estimate_index = 0
    matches: list[tuple[int, int]] = []
    while reference_index < reference.size and estimate_index < estimate.size:
        difference = float(reference[reference_index] - estimate[estimate_index])
        if abs(difference) <= tolerance_seconds:
            matches.append((reference_index, estimate_index))
            reference_index += 1
            estimate_index += 1
            continue
        if difference < 0:
            reference_index += 1
        else:
            estimate_index += 1
    return matches


def _bar_phase_metrics(
    reference_beats: list[float], reference_downbeats: list[float], estimate_ms: Any
) -> dict[str, Any]:
    estimate, dropped_estimates = _event_estimates(estimate_ms)
    beats = mir_eval.beat.trim_beats(
        np.asarray(reference_beats, dtype=float), min_beat_time=_BEAT_TRIM_SECONDS
    )
    downbeats = mir_eval.beat.trim_beats(
        np.asarray(reference_downbeats, dtype=float), min_beat_time=_BEAT_TRIM_SECONDS
    )
    estimated = mir_eval.beat.trim_beats(
        np.asarray(estimate, dtype=float), min_beat_time=_BEAT_TRIM_SECONDS
    )
    common = {
        "reference_beats": int(beats.size),
        "reference_downbeats": int(downbeats.size),
        "estimated_downbeats": int(estimated.size),
        "dropped_estimated_events": dropped_estimates,
        "trim_seconds": _BEAT_TRIM_SECONDS,
    }
    confusion = dict.fromkeys(_PHASE_CONFUSION_NAMES, 0)
    if beats.size == 0 or downbeats.size == 0:
        return {
            "available": False,
            "evaluable": False,
            **common,
            "phase_precision": None,
            "reference_downbeat_recall": None,
            "phase_f1": None,
            "phase_accuracy": None,
            "matched_to_reference_beats": 0,
            "confusion": confusion,
        }

    downbeat_to_beat = {
        downbeat_index: beat_index
        for beat_index, downbeat_index in _one_to_one_matches(
            beats, downbeats, tolerance_seconds=_EVENT_TOLERANCE_SECONDS
        )
    }
    unanchored_reference_downbeats = downbeats.size - len(downbeat_to_beat)
    if unanchored_reference_downbeats:
        return {
            "available": bool(estimated.size),
            "evaluable": False,
            **common,
            "reference_downbeats_anchored_to_beats": len(downbeat_to_beat),
            "unanchored_reference_downbeats": int(unanchored_reference_downbeats),
            "phase_precision": None,
            "reference_downbeat_recall": None,
            "phase_f1": None,
            "phase_accuracy": None,
            "matched_to_reference_beats": 0,
            "confusion": confusion,
        }
    reference_downbeat_beats = sorted(downbeat_to_beat.values())
    reference_downbeat_beat_set = set(reference_downbeat_beats)
    estimate_to_beat = {
        estimate_index: beat_index
        for beat_index, estimate_index in _one_to_one_matches(
            beats, estimated, tolerance_seconds=_EVENT_TOLERANCE_SECONDS
        )
    }
    for estimate_index in range(estimated.size):
        beat_index = estimate_to_beat.get(estimate_index)
        if beat_index is None:
            confusion["off_grid"] += 1
            continue
        phase_position = bisect_left(reference_downbeat_beats, beat_index)
        if beat_index in reference_downbeat_beat_set:
            confusion["on_downbeat"] += 1
            continue
        if phase_position == 0 or phase_position == len(reference_downbeat_beats):
            confusion["unanchored"] += 1
            continue
        phase_offset = beat_index - reference_downbeat_beats[phase_position - 1]
        if phase_offset == 1:
            confusion["one_beat_shift"] += 1
        elif phase_offset == 2:
            confusion["two_beat_shift"] += 1
        elif phase_offset == 3:
            confusion["three_beat_shift"] += 1
        else:
            # Do not infer a 4/4 phase outside an annotation-bounded bar.
            confusion["other_beat_shift"] += 1

    on_downbeat = confusion["on_downbeat"]
    precision = on_downbeat / estimated.size if estimated.size else 0.0
    recall = on_downbeat / downbeats.size
    phase_f1 = (
        2 * precision * recall / (precision + recall) if precision + recall else 0.0
    )
    matched = len(estimate_to_beat)
    return {
        "available": bool(estimated.size),
        "evaluable": True,
        **common,
        "reference_downbeats_anchored_to_beats": len(downbeat_to_beat),
        "unanchored_reference_downbeats": 0,
        "phase_precision": round(precision, 6),
        "reference_downbeat_recall": round(recall, 6),
        "phase_f1": round(phase_f1, 6),
        "phase_accuracy": round(on_downbeat / matched, 6) if matched else 0.0,
        "matched_to_reference_beats": matched,
        "confusion": confusion,
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
    # mir_eval 0.8.2 only credits an estimated fifth above the reference.
    # MIREX has credited fifths in both directions since 2017. Exact, relative,
    # and parallel relationships are symmetric, so the maximum of both argument
    # orders adds only the missing descending-fifth credit.
    score = max(
        float(mir_eval.key.weighted_score(reference, estimate)),
        float(mir_eval.key.weighted_score(estimate, reference)),
    )
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
        "evaluation_split": manifest.get("evaluation_split", "unspecified"),
        "stratum": manifest.get("stratum", "unspecified"),
        "provenance": manifest["provenance"],
        "status": "infra_error" if prediction.get("error") else "scored",
        "metrics": {},
    }
    if isinstance(prediction.get("audio_sha256"), str):
        result["audio_sha256"] = prediction["audio_sha256"].lower()
    if prediction.get("error"):
        result["error"] = prediction["error"]

    reference = manifest["reference"]
    metrics = result["metrics"]
    if "bpm" in reference:
        metrics["tempo"] = _tempo_metrics(reference["bpm"], prediction.get("bpm"))
    if "key" in reference:
        metrics["key"] = _key_metrics(reference["key"], prediction)
    if "beats_seconds" in reference:
        beats = _event_metrics(reference["beats_seconds"], prediction.get("beats_ms"))
        beats["local_tempo"] = _local_tempo_metrics(
            reference["beats_seconds"], prediction.get("beats_ms")
        )
        metrics["beats"] = beats
    if "downbeats_seconds" in reference:
        downbeats = _event_metrics(
            reference["downbeats_seconds"], prediction.get("downbeats_ms")
        )
        downbeats["bar_phase"] = _bar_phase_metrics(
            reference.get("beats_seconds", []),
            reference["downbeats_seconds"],
            prediction.get("downbeats_ms"),
        )
        metrics["downbeats"] = downbeats

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


def _phase_confusion(metrics: list[dict[str, Any]]) -> dict[str, int]:
    counts = dict.fromkeys(_PHASE_CONFUSION_NAMES, 0)
    for metric in metrics:
        for name, value in metric.get("confusion", {}).items():
            if (
                name in counts
                and isinstance(value, int)
                and not isinstance(value, bool)
            ):
                counts[name] += value
    return counts


def _downbeat_confidence_summary(
    tracks: list[dict[str, Any]], metrics: list[dict[str, Any]]
) -> dict[str, Any]:
    entries: list[tuple[float, dict[str, Any], dict[str, Any]]] = []
    missing = 0
    invalid = 0
    for track, metric in zip(tracks, metrics, strict=True):
        phase = metric.get("bar_phase")
        if not isinstance(phase, dict) or not phase.get("evaluable", False):
            continue
        value = track.get("confidence", {}).get("downbeat")
        if value is None:
            missing += 1
            continue
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or not 0.0 <= float(value) <= 1.0
        ):
            invalid += 1
            continue
        entries.append((float(value), metric, phase))

    def summary_for(
        items: list[tuple[float, dict[str, Any], dict[str, Any]]],
    ) -> dict[str, Any]:
        return {
            "tracks": len(items),
            "mean_confidence": _mean(value for value, _metric, _phase in items),
            "mean_phase_precision": _mean(
                phase["phase_precision"] for _value, _metric, phase in items
            ),
            "mean_downbeat_cmlc": _mean(
                metric["cmlc"]
                for _value, metric, _phase in items
                if metric.get("cmlc") is not None
            ),
            "mean_phase_risk": _mean(
                1.0 - phase["phase_precision"] for _value, _metric, phase in items
            ),
        }

    bins = []
    for lower_index in range(10):
        lower = lower_index / 10.0
        upper = (lower_index + 1) / 10.0
        in_bin = [
            entry
            for entry in entries
            if lower <= entry[0] < upper or (upper == 1.0 and entry[0] == 1.0)
        ]
        bins.append({"lower": lower, "upper": upper, **summary_for(in_bin)})
    eligible = len(entries) + missing + invalid
    curves = []
    for threshold in _CONFIDENCE_THRESHOLDS:
        covered = [entry for entry in entries if entry[0] >= threshold]
        curves.append(
            {
                "threshold": threshold,
                "coverage": round(len(covered) / eligible, 6) if eligible else None,
                **summary_for(covered),
            }
        )
    return {
        "phase_eligible_tracks": eligible,
        "reported_confidence_tracks": len(entries),
        "missing_confidence_tracks": missing,
        "invalid_confidence_tracks": invalid,
        "reliability_bins": bins,
        "risk_coverage": curves,
    }


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
        elif task == "downbeats":
            phase_metrics = [
                metric["bar_phase"]
                for metric in metrics
                if isinstance(metric.get("bar_phase"), dict)
            ]
            phase_evaluable = [
                metric for metric in phase_metrics if metric.get("evaluable", False)
            ]
            phase_available = [
                metric for metric in phase_evaluable if metric.get("available", False)
            ]
            task_summary["bar_phase"] = {
                "references": len(phase_metrics),
                "evaluated": len(phase_evaluable),
                "abstentions": len(phase_evaluable) - len(phase_available),
                "coverage": round(len(phase_available) / len(phase_evaluable), 6)
                if phase_evaluable
                else None,
                "phase_precision": _mean(
                    metric["phase_precision"]
                    for metric in phase_evaluable
                    if metric.get("phase_precision") is not None
                ),
                "reference_downbeat_recall": _mean(
                    metric["reference_downbeat_recall"]
                    for metric in phase_evaluable
                    if metric.get("reference_downbeat_recall") is not None
                ),
                "phase_f1": _mean(
                    metric["phase_f1"]
                    for metric in phase_evaluable
                    if metric.get("phase_f1") is not None
                ),
                "phase_accuracy": _mean(
                    metric["phase_accuracy"]
                    for metric in phase_evaluable
                    if metric.get("phase_accuracy") is not None
                ),
                "confusion": _phase_confusion(phase_evaluable),
            }
            task_summary["confidence"] = _downbeat_confidence_summary(eligible, metrics)
        elif task == "beats":
            local_tempo_metrics = [
                metric["local_tempo"]
                for metric in metrics
                if isinstance(metric.get("local_tempo"), dict)
            ]
            local_tempo_evaluable = [
                metric
                for metric in local_tempo_metrics
                if metric.get("evaluable", False)
            ]
            local_tempo_available = [
                metric
                for metric in local_tempo_evaluable
                if metric.get("available", False)
            ]
            reference_intervals = sum(
                metric["reference_intervals"] for metric in local_tempo_evaluable
            )
            matched_intervals = sum(
                metric["matched_intervals"] for metric in local_tempo_evaluable
            )
            task_summary["local_tempo"] = {
                "references": len(local_tempo_metrics),
                "evaluated": len(local_tempo_evaluable),
                "abstentions": len(local_tempo_evaluable) - len(local_tempo_available),
                "reference_intervals": reference_intervals,
                "matched_intervals": matched_intervals,
                "coverage": round(matched_intervals / reference_intervals, 6)
                if reference_intervals
                else None,
                "mean_absolute_relative_error": _mean(
                    metric["mean_absolute_relative_error"]
                    for metric in local_tempo_available
                    if metric.get("mean_absolute_relative_error") is not None
                ),
                "within_4_percent": _mean(
                    metric["within_4_percent"]
                    for metric in local_tempo_available
                    if metric.get("within_4_percent") is not None
                ),
            }
        summary[task] = task_summary
    return summary


def _group_summary(tracks: list[dict[str, Any]]) -> dict[str, Any]:
    summary = _summarize_tracks(tracks)
    by_split: dict[str, list[dict[str, Any]]] = defaultdict(list)
    by_stratum: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for track in tracks:
        by_split[track["evaluation_split"]].append(track)
        by_stratum[track["stratum"]].append(track)
    summary["splits"] = {
        name: _summarize_tracks(group_tracks)
        for name, group_tracks in sorted(by_split.items())
    }
    strata: dict[str, dict[str, Any]] = {}
    for name, group_tracks in sorted(by_stratum.items()):
        stratum_summary = _summarize_tracks(group_tracks)
        by_stratum_split: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for track in group_tracks:
            by_stratum_split[track["evaluation_split"]].append(track)
        stratum_summary["splits"] = {
            split: _summarize_tracks(split_tracks)
            for split, split_tracks in sorted(by_stratum_split.items())
        }
        strata[name] = stratum_summary
    summary["strata"] = strata
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
    scorer_worktree_clean: bool = False,
) -> dict[str, Any]:
    tracks = [score_track(item, predictions[item["id"]]) for item in manifest]
    by_kind: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for track in tracks:
        by_kind[track["label_kind"]].append(track)
    completed = sum(track["status"] == "scored" for track in tracks)
    return {
        "schema_version": 3,
        "generated_at": generated_at,
        "scorer_repo_head": scorer_repo_head,
        "scorer_worktree_clean": scorer_worktree_clean,
        "manifest_sha256": manifest_sha256,
        "predictions_sha256": predictions_sha256,
        "scoring_contract": {
            "beat_trim_seconds": _BEAT_TRIM_SECONDS,
            "event_tolerance_seconds": _EVENT_TOLERANCE_SECONDS,
            "confidence_thresholds": list(_CONFIDENCE_THRESHOLDS),
            "bar_phase": "reference-beat-relative, annotation-bounded",
        },
        "run": {key: value for key, value in run.items() if key != "record_type"},
        "counts": {
            "expected": len(manifest),
            "predictions": len(tracks),
            "completed": completed,
            "infra_errors": len(tracks) - completed,
        },
        "groups": {
            label_kind: _group_summary(kind_tracks)
            for label_kind, kind_tracks in sorted(by_kind.items())
        },
        "tracks": tracks,
    }
