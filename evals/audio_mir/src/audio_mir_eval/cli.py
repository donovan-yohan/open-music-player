from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

from .giantsteps import prepare_manifest as prepare_giantsteps_manifest
from .guitarset import prepare_manifest as prepare_guitarset_manifest
from .io import (
    EvalInputError,
    load_manifest,
    load_predictions,
    repo_head,
    repo_is_clean,
    sha256_file,
    write_json,
)
from .promotion import build_evidence_packet, evaluate_promotion
from .runner import run_analyzer
from .score import build_report


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="audio-mir", description="OMP tempo, beat/downbeat, and key evaluation"
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[4],
        help=argparse.SUPPRESS,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_giantsteps = subparsers.add_parser(
        "prepare-giantsteps",
        help="build a local-only manifest from a GiantSteps checkout",
    )
    prepare_giantsteps.add_argument("--dataset-root", type=Path, required=True)
    prepare_giantsteps.add_argument("--task", choices=["tempo", "key"], required=True)
    prepare_giantsteps.add_argument("--output", type=Path, required=True)
    prepare_giantsteps.add_argument("--limit", type=_positive_int)

    prepare_guitarset = subparsers.add_parser(
        "prepare-guitarset",
        help="build a beats/downbeats/tempo/key manifest from GuitarSet",
    )
    prepare_guitarset.add_argument("--annotation-zip", type=Path, required=True)
    prepare_guitarset.add_argument("--audio-dir", type=Path, required=True)
    prepare_guitarset.add_argument("--output", type=Path, required=True)
    prepare_guitarset.add_argument("--limit", type=_positive_int)

    run = subparsers.add_parser(
        "run", help="invoke the exact OMP analyzer for each manifest item"
    )
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--analyzer-python", type=Path, required=True)
    run.add_argument("--analyzer-script", type=Path, required=True)
    run.add_argument("--model", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--timeout-seconds", type=float, default=120.0)
    run.add_argument(
        "--resume",
        action="store_true",
        help="resume a compatible partial artifact and retry prior infra errors",
    )
    run.add_argument(
        "--experiment-id",
        help="frozen experiment identifier; required with the other experiment fields",
    )
    run.add_argument(
        "--experiment-arm",
        help="baseline or candidate arm label; required with the other experiment fields",
    )
    run.add_argument(
        "--experiment-factor",
        help="single changed factor label; required with the other experiment fields",
    )
    run.add_argument(
        "--freeze-id",
        help="frozen decode/annotation/metric packet identifier; required with experiment fields",
    )

    score = subparsers.add_parser("score", help="score a complete prediction artifact")
    score.add_argument("--manifest", type=Path, required=True)
    score.add_argument("--predictions", type=Path, required=True)
    score.add_argument("--output", type=Path, required=True)

    promote = subparsers.add_parser(
        "promote", help="apply an explicit held-out downbeat promotion policy"
    )
    promote.add_argument("--baseline-report", type=Path, required=True)
    promote.add_argument("--candidate-report", type=Path, required=True)
    promote.add_argument("--policy", type=Path, required=True)
    promote.add_argument("--output", type=Path, required=True)
    promote.add_argument(
        "--evidence-output",
        type=Path,
        required=True,
        help="canonical SHA-256 packet binding policy, reports, and decision",
    )
    return parser


def _repo_path(path: Path, repo_root: Path) -> Path:
    return path if path.is_absolute() else repo_root / path


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    args.repo_root = args.repo_root.resolve()
    try:
        head = repo_head(args.repo_root)
        if args.command in {"run", "score", "promote"} and head == "unknown":
            raise EvalInputError("--repo-root must be an exact Git checkout root")
        worktree_clean = repo_is_clean(args.repo_root)
        if args.command == "prepare-giantsteps":
            count, missing = prepare_giantsteps_manifest(
                args.dataset_root,
                task=args.task,
                output_path=args.output,
                limit=args.limit,
            )
            print(
                f"audio-mir eval: prepared task={args.task} tracks={count} "
                f"missing_audio={missing} manifest={args.output}"
            )
            return 0
        if args.command == "prepare-guitarset":
            count, missing = prepare_guitarset_manifest(
                args.annotation_zip,
                args.audio_dir,
                output_path=args.output,
                limit=args.limit,
            )
            print(
                f"audio-mir eval: prepared task=all tracks={count} "
                f"missing_audio={missing} manifest={args.output}"
            )
            return 0

        if args.command == "promote":
            baseline = json.loads(args.baseline_report.read_text(encoding="utf-8"))
            candidate = json.loads(args.candidate_report.read_text(encoding="utf-8"))
            policy = json.loads(args.policy.read_text(encoding="utf-8"))
            decision = evaluate_promotion(baseline, candidate, policy)
            write_json(args.output, decision)
            evidence = build_evidence_packet(baseline, candidate, policy, decision)
            write_json(args.evidence_output, evidence)
            failed = sum(not gate["passed"] for gate in decision["gates"])
            print(
                f"audio-mir eval: promotion_passed={decision['passed']} "
                f"failed_gates={failed} decision={args.output} evidence={args.evidence_output}"
            )
            return 0 if decision["passed"] else 1

        manifest = load_manifest(args.manifest)
        if args.command == "run":
            experiment_fields = {
                "id": args.experiment_id,
                "arm": args.experiment_arm,
                "factor": args.experiment_factor,
                "freeze_id": args.freeze_id,
            }
            count, errors = run_analyzer(
                manifest,
                manifest_path=args.manifest,
                analyzer_python=_repo_path(args.analyzer_python, args.repo_root),
                analyzer_script=_repo_path(args.analyzer_script, args.repo_root),
                model_path=_repo_path(args.model, args.repo_root),
                output_path=args.output,
                repo_head=head,
                repo_worktree_clean=worktree_clean,
                timeout_seconds=args.timeout_seconds,
                resume=args.resume,
                experiment=experiment_fields
                if any(value is not None for value in experiment_fields.values())
                else None,
            )
            print(
                f"audio-mir eval: run tracks={count} infra_errors={errors} artifact={args.output}"
            )
            return 1 if errors else 0

        run, predictions = load_predictions(args.predictions)
        manifest_sha256 = sha256_file(args.manifest)
        if run["manifest_sha256"] != manifest_sha256:
            raise EvalInputError(
                "prediction artifact was produced from a different manifest"
            )
        expected_ids = {item["id"] for item in manifest}
        prediction_ids = set(predictions)
        missing = sorted(expected_ids - prediction_ids)
        extra = sorted(prediction_ids - expected_ids)
        if missing or extra:
            raise EvalInputError(
                f"prediction set mismatch: missing={missing[:5]} extra={extra[:5]}"
            )
        report = build_report(
            manifest,
            predictions,
            run=run,
            scorer_repo_head=head,
            manifest_sha256=manifest_sha256,
            predictions_sha256=sha256_file(args.predictions),
            generated_at=datetime.now(UTC).isoformat(),
            scorer_worktree_clean=worktree_clean,
        )
        write_json(args.output, report)
        errors = report["counts"]["infra_errors"]
        groups = ",".join(sorted(report["groups"]))
        print(
            f"audio-mir eval: completed={report['counts']['completed']} "
            f"infra_errors={errors} label_groups={groups} report={args.output}"
        )
        return 1 if errors else 0
    except (EvalInputError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"audio-mir eval: FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
