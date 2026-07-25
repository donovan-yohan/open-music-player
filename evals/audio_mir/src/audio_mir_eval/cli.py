from __future__ import annotations

import argparse
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
    sha256_file,
    write_json,
)
from .runner import run_analyzer
from .score import build_report


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
    prepare_giantsteps.add_argument("--limit", type=int)

    prepare_guitarset = subparsers.add_parser(
        "prepare-guitarset",
        help="build a beats/downbeats/tempo/key manifest from GuitarSet",
    )
    prepare_guitarset.add_argument("--annotation-zip", type=Path, required=True)
    prepare_guitarset.add_argument("--audio-dir", type=Path, required=True)
    prepare_guitarset.add_argument("--output", type=Path, required=True)
    prepare_guitarset.add_argument("--limit", type=int)

    run = subparsers.add_parser(
        "run", help="invoke the exact OMP analyzer for each manifest item"
    )
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--analyzer-python", type=Path, required=True)
    run.add_argument("--analyzer-script", type=Path, required=True)
    run.add_argument("--model", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--timeout-seconds", type=float, default=120.0)

    score = subparsers.add_parser("score", help="score a complete prediction artifact")
    score.add_argument("--manifest", type=Path, required=True)
    score.add_argument("--predictions", type=Path, required=True)
    score.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        head = repo_head(args.repo_root)
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

        manifest = load_manifest(args.manifest)
        if args.command == "run":
            count, errors = run_analyzer(
                manifest,
                manifest_path=args.manifest,
                analyzer_python=args.analyzer_python,
                analyzer_script=args.analyzer_script,
                model_path=args.model,
                output_path=args.output,
                repo_head=head,
                timeout_seconds=args.timeout_seconds,
            )
            print(
                f"audio-mir eval: run tracks={count} infra_errors={errors} artifact={args.output}"
            )
            return 1 if errors else 0

        run, predictions = load_predictions(args.predictions)
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
            repo_head=head,
            manifest_sha256=sha256_file(args.manifest),
            predictions_sha256=sha256_file(args.predictions),
            generated_at=datetime.now(UTC).isoformat(),
        )
        write_json(args.output, report)
        errors = report["counts"]["infra_errors"]
        groups = ",".join(sorted(report["groups"]))
        print(
            f"audio-mir eval: scored={report['counts']['scored']} infra_errors={errors} "
            f"label_groups={groups} report={args.output}"
        )
        return 1 if errors else 0
    except (EvalInputError, OSError, ValueError) as exc:
        print(f"audio-mir eval: FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
