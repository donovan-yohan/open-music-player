from __future__ import annotations

import math
import re
from typing import Any

from .io import EvalInputError, validate_experiment_context

_REPORT_SCHEMA_VERSION = 3
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_HIGHER_IS_BETTER_REGRESSION_GATES = (
    (
        "downbeat_f_measure_non_regression",
        ("downbeats", "f_measure_70ms"),
        "downbeats",
        "maximum_f_measure_regression",
    ),
    (
        "downbeat_cemgil_non_regression",
        ("downbeats", "cemgil"),
        "downbeats",
        "maximum_cemgil_regression",
    ),
    (
        "downbeat_cmlc_non_regression",
        ("downbeats", "cmlc"),
        "downbeats",
        "maximum_cmlc_regression",
    ),
    (
        "downbeat_cmlt_non_regression",
        ("downbeats", "cmlt"),
        "downbeats",
        "maximum_cmlt_regression",
    ),
    (
        "downbeat_reference_recall_non_regression",
        ("downbeats", "bar_phase", "reference_downbeat_recall"),
        "downbeats",
        "maximum_reference_downbeat_recall_regression",
    ),
    (
        "downbeat_phase_f1_non_regression",
        ("downbeats", "bar_phase", "phase_f1"),
        "downbeats",
        "maximum_phase_f1_regression",
    ),
    (
        "beat_f_measure_non_regression",
        ("beats", "f_measure_70ms"),
        "beats",
        "maximum_f_measure_regression",
    ),
    (
        "beat_cemgil_non_regression",
        ("beats", "cemgil"),
        "beats",
        "maximum_cemgil_regression",
    ),
    ("beat_cmlc_non_regression", ("beats", "cmlc"), "beats", "maximum_cmlc_regression"),
    ("beat_cmlt_non_regression", ("beats", "cmlt"), "beats", "maximum_cmlt_regression"),
    (
        "local_tempo_coverage_non_regression",
        ("beats", "local_tempo", "coverage"),
        "beats",
        "maximum_local_tempo_coverage_regression",
    ),
)
_LOWER_IS_BETTER_REGRESSION_GATES = (
    (
        "local_tempo_error_budget",
        ("beats", "local_tempo", "mean_absolute_relative_error"),
        "beats",
        "maximum_local_tempo_error_increase",
    ),
)


def _mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvalInputError(f"{name} must be an object")
    return value


def _number(
    value: Any,
    name: str,
    *,
    minimum: float | None = None,
    maximum: float | None = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvalInputError(f"{name} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise EvalInputError(f"{name} must be finite")
    if minimum is not None and result < minimum:
        raise EvalInputError(f"{name} must be at least {minimum:g}")
    if maximum is not None and result > maximum:
        raise EvalInputError(f"{name} must be at most {maximum:g}")
    return result


def _integer(value: Any, name: str, *, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise EvalInputError(f"{name} must be an integer of at least {minimum}")
    return value


def _regression_budgets(
    raw: dict[str, Any], name: str, fields: tuple[str, ...]
) -> dict[str, float]:
    return {
        field: _number(raw.get(field), f"{name}.{field}", minimum=0.0, maximum=1.0)
        for field in fields
    }


def _require(report: dict[str, Any], path: tuple[str, ...]) -> Any:
    value: Any = report
    for name in path:
        if not isinstance(value, dict) or name not in value:
            raise EvalInputError(f"report is missing {'.'.join(path)}")
        value = value[name]
    return value


def _metric(summary: dict[str, Any], path: tuple[str, ...]) -> float:
    return _number(_require(summary, path), f"report {'.'.join(path)}")


def _sha256(value: Any, name: str) -> str:
    if not isinstance(value, str) or not _SHA256_RE.fullmatch(value.lower()):
        raise EvalInputError(f"{name} must be a SHA-256 digest")
    return value.lower()


def _validate_report(report: Any, name: str) -> dict[str, Any]:
    report = _mapping(report, name)
    if report.get("schema_version") != _REPORT_SCHEMA_VERSION:
        raise EvalInputError(
            f"{name} schema_version must be {_REPORT_SCHEMA_VERSION}; rescore the artifact"
        )
    for path in (
        ("manifest_sha256",),
        ("scorer_repo_head",),
        ("run",),
        ("groups",),
        ("tracks",),
    ):
        value = _require(report, path)
        if path[0] in {"manifest_sha256", "scorer_repo_head"} and (
            not isinstance(value, str) or not value
        ):
            raise EvalInputError(f"{name} has an invalid {path[0]}")
    _mapping(report["run"], f"{name}.run")
    _mapping(report["groups"], f"{name}.groups")
    _mapping(report.get("counts"), f"{name}.counts")
    if not isinstance(report["tracks"], list):
        raise EvalInputError(f"{name}.tracks must be an array")
    _sha256(report["manifest_sha256"], f"{name}.manifest_sha256")
    _sha256(report.get("predictions_sha256"), f"{name}.predictions_sha256")
    for field in ("model_sha256", "analyzer_script_sha256"):
        _sha256(report["run"].get(field), f"{name}.run.{field}")
    if (
        not isinstance(report["run"].get("repo_head"), str)
        or not report["run"]["repo_head"]
    ):
        raise EvalInputError(f"{name}.run.repo_head must be a non-empty string")
    _integer(
        report["counts"].get("infra_errors"),
        f"{name}.counts.infra_errors",
        minimum=0,
    )
    if not isinstance(report.get("scorer_worktree_clean"), bool):
        raise EvalInputError(f"{name}.scorer_worktree_clean must be a boolean")
    if not isinstance(report["run"].get("repo_worktree_clean"), bool):
        raise EvalInputError(f"{name}.run.repo_worktree_clean must be a boolean")
    return report


def _experiment(run: dict[str, Any], name: str) -> dict[str, str] | None:
    value = run.get("experiment")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise EvalInputError(f"{name}.run.experiment must be an object")
    try:
        return validate_experiment_context(value)
    except EvalInputError as exc:
        raise EvalInputError(f"{name}.run.experiment is invalid: {exc}") from exc


def _policy(raw: Any) -> dict[str, Any]:
    raw = _mapping(raw, "promotion policy")
    if raw.get("schema_version") != 1:
        raise EvalInputError("promotion policy schema_version must be 1")
    if raw.get("label_kind") != "ground_truth":
        raise EvalInputError("promotion policy label_kind must be ground_truth")
    if raw.get("evaluation_split") != "holdout":
        raise EvalInputError("promotion policy evaluation_split must be holdout")

    downbeats = _mapping(raw.get("downbeats"), "promotion policy downbeats")
    beats = _mapping(raw.get("beats"), "promotion policy beats")
    resources = _mapping(raw.get("resources"), "promotion policy resources")
    automation = _mapping(raw.get("automation"), "promotion policy automation")
    if automation.get("threshold_source") != "calibration":
        raise EvalInputError(
            "promotion policy automation.threshold_source must be calibration"
        )

    return {
        "schema_version": 1,
        "label_kind": "ground_truth",
        "evaluation_split": "holdout",
        "minimum_holdout_tracks": _integer(
            raw.get("minimum_holdout_tracks"),
            "promotion policy minimum_holdout_tracks",
            minimum=1,
        ),
        "downbeats": {
            "minimum_phase_precision_delta": _number(
                downbeats.get("minimum_phase_precision_delta"),
                "promotion policy downbeats.minimum_phase_precision_delta",
                minimum=0.0,
                maximum=1.0,
            ),
            **_regression_budgets(
                downbeats,
                "promotion policy downbeats",
                (
                    "maximum_f_measure_regression",
                    "maximum_cemgil_regression",
                    "maximum_cmlc_regression",
                    "maximum_cmlt_regression",
                    "maximum_reference_downbeat_recall_regression",
                    "maximum_phase_f1_regression",
                ),
            ),
        },
        "beats": {
            **_regression_budgets(
                beats,
                "promotion policy beats",
                (
                    "maximum_f_measure_regression",
                    "maximum_cemgil_regression",
                    "maximum_cmlc_regression",
                    "maximum_cmlt_regression",
                    "maximum_local_tempo_coverage_regression",
                ),
            ),
            "maximum_local_tempo_error_increase": _number(
                beats.get("maximum_local_tempo_error_increase"),
                "promotion policy beats.maximum_local_tempo_error_increase",
                minimum=0.0,
            ),
        },
        "resources": {
            "maximum_runtime_p95_ratio": _number(
                resources.get("maximum_runtime_p95_ratio"),
                "promotion policy resources.maximum_runtime_p95_ratio",
                minimum=1.0,
            ),
            "maximum_peak_rss_ratio": _number(
                resources.get("maximum_peak_rss_ratio"),
                "promotion policy resources.maximum_peak_rss_ratio",
                minimum=1.0,
            ),
        },
        "automation": {
            "threshold_source": "calibration",
            "confidence_threshold": _number(
                automation.get("confidence_threshold"),
                "promotion policy automation.confidence_threshold",
                minimum=0.0,
                maximum=1.0,
            ),
            "minimum_calibration_tracks": _integer(
                automation.get("minimum_calibration_tracks"),
                "promotion policy automation.minimum_calibration_tracks",
                minimum=1,
            ),
            "minimum_calibration_coverage": _number(
                automation.get("minimum_calibration_coverage"),
                "promotion policy automation.minimum_calibration_coverage",
                minimum=0.0,
                maximum=1.0,
            ),
            "minimum_holdout_coverage": _number(
                automation.get("minimum_holdout_coverage"),
                "promotion policy automation.minimum_holdout_coverage",
                minimum=0.0,
                maximum=1.0,
            ),
            "minimum_track_phase_precision": _number(
                automation.get("minimum_track_phase_precision"),
                "promotion policy automation.minimum_track_phase_precision",
                minimum=0.0,
                maximum=1.0,
            ),
            "maximum_holdout_false_lock_rate": _number(
                automation.get("maximum_holdout_false_lock_rate"),
                "promotion policy automation.maximum_holdout_false_lock_rate",
                minimum=0.0,
                maximum=1.0,
            ),
            "maximum_calibration_false_lock_rate": _number(
                automation.get("maximum_calibration_false_lock_rate"),
                "promotion policy automation.maximum_calibration_false_lock_rate",
                minimum=0.0,
                maximum=1.0,
            ),
        },
    }


def _split_summary(
    report: dict[str, Any], label_kind: str, split: str
) -> dict[str, Any]:
    groups = _mapping(report["groups"], "report groups")
    group = _mapping(groups.get(label_kind), f"report groups.{label_kind}")
    splits = _mapping(group.get("splits"), f"report groups.{label_kind}.splits")
    return _mapping(splits.get(split), f"report groups.{label_kind}.splits.{split}")


def _resource_peak(report: dict[str, Any]) -> float:
    usage = _mapping(report["run"].get("resource_usage"), "report run.resource_usage")
    if usage.get("scope") != "runner_process_children_lifetime":
        raise EvalInputError("report resource usage has an unsupported scope")
    return _number(
        usage.get("peak_rss_kib"), "report run.resource_usage.peak_rss_kib", minimum=0.0
    )


def _audio_hashes(report: dict[str, Any], name: str) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for index, track in enumerate(report["tracks"], 1):
        if not isinstance(track, dict):
            raise EvalInputError(f"{name}.tracks[{index}] must be an object")
        track_id = track.get("id")
        if not isinstance(track_id, str) or not track_id:
            raise EvalInputError(
                f"{name}.tracks[{index}].id must be a non-empty string"
            )
        if track_id in hashes:
            raise EvalInputError(f"{name}.tracks contains duplicate id: {track_id}")
        hashes[track_id] = _sha256(
            track.get("audio_sha256"), f"{name}.tracks[{index}].audio_sha256"
        )
    return hashes


def _split_audio_hashes(
    report: dict[str, Any], name: str
) -> tuple[dict[str, set[str]], int]:
    """Return exact audio identities by split plus duplicate rows to reject."""
    result: dict[str, set[str]] = {}
    seen: set[str] = set()
    duplicates = 0
    for index, track in enumerate(report["tracks"], 1):
        if not isinstance(track, dict):
            raise EvalInputError(f"{name}.tracks[{index}] must be an object")
        split = track.get("evaluation_split")
        if not isinstance(split, str):
            raise EvalInputError(
                f"{name}.tracks[{index}].evaluation_split must be a string"
            )
        digest = _sha256(
            track.get("audio_sha256"), f"{name}.tracks[{index}].audio_sha256"
        )
        if digest in seen:
            duplicates += 1
        seen.add(digest)
        result.setdefault(split, set()).add(digest)
    return result, duplicates


def _promotion_split_gate(report: dict[str, Any], name: str) -> dict[str, Any]:
    split_hashes, duplicates = _split_audio_hashes(report, name)
    permitted = {"calibration", "holdout"}
    unexpected = sorted(set(split_hashes) - permitted)
    overlap = sorted(
        split_hashes.get("calibration", set()) & split_hashes.get("holdout", set())
    )
    return _gate(
        f"{name}_sealed_splits",
        not unexpected and not overlap and duplicates == 0,
        unexpected_splits=unexpected,
        calibration_holdout_audio_overlap=len(overlap),
        duplicate_audio_rows=duplicates,
    )


def _automation_metrics(
    report: dict[str, Any],
    *,
    label_kind: str,
    split: str,
    confidence_threshold: float,
    minimum_phase_precision: float,
) -> dict[str, Any]:
    eligible = 0
    confidence_reported = 0
    locked = 0
    false_locks = 0
    unknown_phase_tracks = 0
    unknown_phase_locked_tracks = 0
    for track in report["tracks"]:
        if (
            not isinstance(track, dict)
            or track.get("label_kind") != label_kind
            or track.get("evaluation_split") != split
            or track.get("status") != "scored"
        ):
            continue
        metrics = track.get("metrics")
        downbeats = metrics.get("downbeats") if isinstance(metrics, dict) else None
        confidence = track.get("confidence", {}).get("downbeat")
        confidence_is_valid = not (
            isinstance(confidence, bool)
            or not isinstance(confidence, (int, float))
            or not math.isfinite(float(confidence))
            or not 0.0 <= float(confidence) <= 1.0
        )
        phase = downbeats.get("bar_phase") if isinstance(downbeats, dict) else None
        if not isinstance(phase, dict) or not phase.get("evaluable", False):
            unknown_phase_tracks += 1
            if confidence_is_valid and float(confidence) >= confidence_threshold:
                unknown_phase_locked_tracks += 1
            continue
        eligible += 1
        if not confidence_is_valid:
            continue
        confidence_reported += 1
        if float(confidence) < confidence_threshold:
            continue
        locked += 1
        phase_precision = _number(
            phase.get("phase_precision"),
            "report track downbeats.bar_phase.phase_precision",
        )
        if phase_precision < minimum_phase_precision:
            false_locks += 1
    return {
        "eligible_tracks": eligible,
        "reported_confidence_tracks": confidence_reported,
        "locked_tracks": locked,
        "coverage": round(locked / eligible, 6) if eligible else None,
        "false_locks": false_locks,
        "false_lock_rate": round(false_locks / locked, 6) if locked else None,
        "unknown_phase_tracks": unknown_phase_tracks,
        "unknown_phase_locked_tracks": unknown_phase_locked_tracks,
    }


def _gate(name: str, passed: bool, **details: Any) -> dict[str, Any]:
    return {"name": name, "passed": passed, **details}


def _no_regression_gates(
    baseline: dict[str, Any], candidate: dict[str, Any], policy: dict[str, Any]
) -> list[dict[str, Any]]:
    gates = []
    for name, metric_path, section, budget_name in _HIGHER_IS_BETTER_REGRESSION_GATES:
        baseline_value = _metric(baseline, metric_path)
        candidate_value = _metric(candidate, metric_path)
        budget = policy[section][budget_name]
        gates.append(
            _gate(
                name,
                baseline_value - candidate_value <= budget,
                baseline=baseline_value,
                candidate=candidate_value,
                regression=round(baseline_value - candidate_value, 6),
                maximum_regression=budget,
            )
        )
    for name, metric_path, section, budget_name in _LOWER_IS_BETTER_REGRESSION_GATES:
        baseline_value = _metric(baseline, metric_path)
        candidate_value = _metric(candidate, metric_path)
        budget = policy[section][budget_name]
        gates.append(
            _gate(
                name,
                candidate_value - baseline_value <= budget,
                baseline=baseline_value,
                candidate=candidate_value,
                increase=round(candidate_value - baseline_value, 6),
                maximum_increase=budget,
            )
        )
    return gates


def _comparison_gates(
    baseline: dict[str, Any], candidate: dict[str, Any]
) -> list[dict[str, Any]]:
    gates = []
    for field in ("manifest_sha256", "scorer_repo_head"):
        gates.append(
            _gate(
                f"frozen_{field}",
                baseline[field] == candidate[field],
                baseline=baseline[field],
                candidate=candidate[field],
            )
        )
    baseline_audio_hashes = _audio_hashes(baseline, "baseline report")
    candidate_audio_hashes = _audio_hashes(candidate, "candidate report")
    gates.append(
        _gate(
            "frozen_audio_hashes",
            baseline_audio_hashes == candidate_audio_hashes,
            baseline_tracks=len(baseline_audio_hashes),
            candidate_tracks=len(candidate_audio_hashes),
        )
    )
    for field in ("repo_head", "model_sha256"):
        gates.append(
            _gate(
                f"frozen_{field}",
                baseline["run"].get(field) == candidate["run"].get(field),
                baseline=baseline["run"].get(field),
                candidate=candidate["run"].get(field),
            )
        )
    gates.extend(
        [
            _gate(
                "baseline_clean_checkout",
                baseline["scorer_worktree_clean"]
                and baseline["run"]["repo_worktree_clean"],
            ),
            _gate(
                "candidate_clean_checkout",
                candidate["scorer_worktree_clean"]
                and candidate["run"]["repo_worktree_clean"],
            ),
            _promotion_split_gate(baseline, "baseline"),
            _promotion_split_gate(candidate, "candidate"),
        ]
    )
    baseline_experiment = _experiment(baseline["run"], "baseline report")
    candidate_experiment = _experiment(candidate["run"], "candidate report")
    experiment_complete = (
        baseline_experiment is not None and candidate_experiment is not None
    )
    gates.append(
        _gate(
            "experiment_context_declared",
            experiment_complete,
            baseline=baseline_experiment,
            candidate=candidate_experiment,
        )
    )
    if experiment_complete:
        assert baseline_experiment is not None and candidate_experiment is not None
        for field in ("id", "factor", "freeze_id"):
            gates.append(
                _gate(
                    f"frozen_experiment_{field}",
                    baseline_experiment[field] == candidate_experiment[field],
                    baseline=baseline_experiment[field],
                    candidate=candidate_experiment[field],
                )
            )
        gates.append(
            _gate(
                "experiment_arms_differ",
                baseline_experiment["arm"] != candidate_experiment["arm"],
                baseline=baseline_experiment["arm"],
                candidate=candidate_experiment["arm"],
            )
        )
    return gates


def evaluate_promotion(
    baseline_report: Any, candidate_report: Any, policy: Any
) -> dict[str, Any]:
    """Compare one frozen baseline/candidate pair and fail closed on missing evidence."""
    baseline = _validate_report(baseline_report, "baseline report")
    candidate = _validate_report(candidate_report, "candidate report")
    policy = _policy(policy)
    label_kind = policy["label_kind"]
    split = policy["evaluation_split"]
    baseline_summary = _split_summary(baseline, label_kind, split)
    candidate_summary = _split_summary(candidate, label_kind, split)
    calibration_summary = _split_summary(candidate, label_kind, "calibration")

    baseline_phase = _metric(
        baseline_summary, ("downbeats", "bar_phase", "phase_precision")
    )
    candidate_phase = _metric(
        candidate_summary, ("downbeats", "bar_phase", "phase_precision")
    )
    baseline_runtime = _metric(baseline_summary, ("runtime_seconds", "p95"))
    candidate_runtime = _metric(candidate_summary, ("runtime_seconds", "p95"))
    baseline_rss = _resource_peak(baseline)
    candidate_rss = _resource_peak(candidate)
    baseline_phase_tracks = _integer(
        _require(baseline_summary, ("downbeats", "bar_phase", "evaluated")),
        "baseline holdout phase tracks",
        minimum=0,
    )
    candidate_phase_tracks = _integer(
        _require(candidate_summary, ("downbeats", "bar_phase", "evaluated")),
        "candidate holdout phase tracks",
        minimum=0,
    )
    calibration_tracks = _integer(
        _require(
            calibration_summary, ("downbeats", "confidence", "phase_eligible_tracks")
        ),
        "candidate calibration phase tracks",
        minimum=0,
    )

    calibration_automation = _automation_metrics(
        candidate,
        label_kind=label_kind,
        split="calibration",
        confidence_threshold=policy["automation"]["confidence_threshold"],
        minimum_phase_precision=policy["automation"]["minimum_track_phase_precision"],
    )
    automation = _automation_metrics(
        candidate,
        label_kind=label_kind,
        split=split,
        confidence_threshold=policy["automation"]["confidence_threshold"],
        minimum_phase_precision=policy["automation"]["minimum_track_phase_precision"],
    )
    gates = _comparison_gates(baseline, candidate)
    gates.extend(
        [
            _gate(
                "holdout_sample_count",
                baseline_phase_tracks >= policy["minimum_holdout_tracks"]
                and candidate_phase_tracks >= policy["minimum_holdout_tracks"],
                required=policy["minimum_holdout_tracks"],
                baseline=baseline_phase_tracks,
                candidate=candidate_phase_tracks,
            ),
            _gate(
                "zero_infrastructure_errors",
                baseline["counts"].get("infra_errors") == 0
                and candidate["counts"].get("infra_errors") == 0,
                baseline=baseline["counts"].get("infra_errors"),
                candidate=candidate["counts"].get("infra_errors"),
            ),
            _gate(
                "downbeat_phase_precision",
                candidate_phase - baseline_phase
                >= policy["downbeats"]["minimum_phase_precision_delta"],
                baseline=baseline_phase,
                candidate=candidate_phase,
                delta=round(candidate_phase - baseline_phase, 6),
                minimum_delta=policy["downbeats"]["minimum_phase_precision_delta"],
            ),
            _gate(
                "runtime_p95_budget",
                baseline_runtime > 0
                and candidate_runtime / baseline_runtime
                <= policy["resources"]["maximum_runtime_p95_ratio"],
                baseline_seconds=baseline_runtime,
                candidate_seconds=candidate_runtime,
                ratio=round(candidate_runtime / baseline_runtime, 6)
                if baseline_runtime
                else None,
                maximum_ratio=policy["resources"]["maximum_runtime_p95_ratio"],
            ),
            _gate(
                "peak_rss_budget",
                baseline_rss > 0
                and candidate_rss / baseline_rss
                <= policy["resources"]["maximum_peak_rss_ratio"],
                baseline_kib=baseline_rss,
                candidate_kib=candidate_rss,
                ratio=round(candidate_rss / baseline_rss, 6) if baseline_rss else None,
                maximum_ratio=policy["resources"]["maximum_peak_rss_ratio"],
            ),
            _gate(
                "calibration_sample_count",
                calibration_tracks
                >= policy["automation"]["minimum_calibration_tracks"],
                required=policy["automation"]["minimum_calibration_tracks"],
                candidate=calibration_tracks,
            ),
            _gate(
                "holdout_automation_coverage",
                automation["coverage"] is not None
                and automation["coverage"]
                >= policy["automation"]["minimum_holdout_coverage"],
                actual=automation["coverage"],
                minimum=policy["automation"]["minimum_holdout_coverage"],
            ),
            _gate(
                "holdout_false_lock_rate",
                automation["false_lock_rate"] is not None
                and automation["false_lock_rate"]
                <= policy["automation"]["maximum_holdout_false_lock_rate"],
                actual=automation["false_lock_rate"],
                maximum=policy["automation"]["maximum_holdout_false_lock_rate"],
            ),
            _gate(
                "calibration_false_lock_rate",
                calibration_automation["false_lock_rate"] is not None
                and calibration_automation["false_lock_rate"]
                <= policy["automation"]["maximum_calibration_false_lock_rate"],
                actual=calibration_automation["false_lock_rate"],
                maximum=policy["automation"]["maximum_calibration_false_lock_rate"],
            ),
            _gate(
                "calibration_automation_coverage",
                calibration_automation["coverage"] is not None
                and calibration_automation["coverage"]
                >= policy["automation"]["minimum_calibration_coverage"],
                actual=calibration_automation["coverage"],
                minimum=policy["automation"]["minimum_calibration_coverage"],
            ),
            _gate(
                "calibration_unknown_phase_remains_unlocked",
                calibration_automation["unknown_phase_locked_tracks"] == 0,
                unknown_phase_tracks=calibration_automation["unknown_phase_tracks"],
                locked_unknown_phase_tracks=calibration_automation[
                    "unknown_phase_locked_tracks"
                ],
            ),
            _gate(
                "unknown_phase_remains_unlocked",
                automation["unknown_phase_locked_tracks"] == 0,
                unknown_phase_tracks=automation["unknown_phase_tracks"],
                locked_unknown_phase_tracks=automation["unknown_phase_locked_tracks"],
            ),
        ]
    )
    gates.extend(_no_regression_gates(baseline_summary, candidate_summary, policy))
    return {
        "schema_version": 1,
        "policy": policy,
        "comparison": {
            "baseline_manifest_sha256": baseline["manifest_sha256"],
            "candidate_manifest_sha256": candidate["manifest_sha256"],
            "baseline_predictions_sha256": baseline.get("predictions_sha256"),
            "candidate_predictions_sha256": candidate.get("predictions_sha256"),
            "baseline_analyzer_script_sha256": baseline["run"][
                "analyzer_script_sha256"
            ],
            "candidate_analyzer_script_sha256": candidate["run"][
                "analyzer_script_sha256"
            ],
        },
        "automation": automation,
        "calibration_automation": calibration_automation,
        "gates": gates,
        "passed": all(gate["passed"] for gate in gates),
    }
