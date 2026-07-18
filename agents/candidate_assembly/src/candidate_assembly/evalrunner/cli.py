"""argparse CLI for the agent-search evals — invoked by ``scripts/eval agent-search``.

Replay is the default, network-free CI gate. Live mode executes the selected arms
against the real OpenAI-compatible endpoint (env-only configuration) and can
refresh recordings. The command exits nonzero on any safety-grader failure or
when the graded pass rate is below ``--min-pass-rate``.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Optional

from ..budgets import Budget
from ..orchestrator import ALL_ARMS, resolve_arm_names
from ..schemas import PROMPT_REVISION
from . import corpus as corpus_mod
from . import known_failures as known_failures_mod
from . import runner as runner_mod


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agent-search", description="OMP agent-search candidate-assembly evals")
    parser.add_argument("--mode", choices=["replay", "live", "gateway"], default=os.environ.get("AGENT_SEARCH_EVAL_MODE", "replay"))
    parser.add_argument("--arm", default="", help="comma-separated arm names (default: all)")
    parser.add_argument("--case", default="", help="comma-separated case ids (default: all)")
    parser.add_argument("--min-pass-rate", type=float, default=None, help="required graded pass rate (default: 1.0 replay / advisory live)")
    parser.add_argument("--output", default="", help="JSONL artifact path, or - for stdout")
    parser.add_argument("--run-id", default="", help="artifact run identifier")
    parser.add_argument("--run-state", choices=["cold", "idle", "warm"], default="idle", help="endpoint state label supplied by the operator")
    parser.add_argument("--base-url", default="", help="live-only OpenAI-compatible endpoint override; never stored")
    parser.add_argument("--model", default="", help="live-only model override recorded in provenance")
    parser.add_argument("--skip-probe", action="store_true", help="live-only: make no startup probe requests")
    parser.add_argument("--record-dir", default="", help="base dir for --update-recordings (default: bundled fixtures)")
    parser.add_argument("--update-recordings", action="store_true", help="write recordings for executed arms")
    parser.add_argument("--firecrawl-experiment", action="store_true", help="one explicit, capped gateway extraction; disabled by default")
    parser.add_argument("--limit", type=int, default=5, help="per-case recommendation limit passed to arms")
    # Budget overrides (unset flags keep the defaults).
    parser.add_argument("--max-tool-calls", type=int, default=None)
    parser.add_argument("--max-model-calls", type=int, default=None)
    parser.add_argument("--max-candidates-in", type=int, default=None)
    parser.add_argument("--max-recommendations", type=int, default=None)
    parser.add_argument("--wall-clock-s", type=float, default=None)
    parser.add_argument("--max-tokens", type=int, default=None, dest="max_tokens_per_completion")
    return parser


def _split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def _apply_live_endpoint_overrides(base_url: str, model: str) -> None:
    """Apply nonsecret CLI matrix dimensions to this process only.

    The API key deliberately has no CLI equivalent and remains environment-only.
    Model arms construct their own ``ModelConfig``, so process-local environment
    overrides keep every arm on the exact endpoint/model selected by the runner.
    """

    if base_url.strip():
        os.environ["AGENT_SEARCH_BASE_URL"] = base_url.strip()
    if model.strip():
        os.environ["AGENT_SEARCH_MODEL"] = model.strip()


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    mode = args.mode

    if mode != "live" and (args.base_url.strip() or args.model.strip() or args.skip_probe):
        print(
            "agent-search eval: FAIL: --base-url, --model, and --skip-probe require --mode live",
            file=sys.stderr,
        )
        return 2

    # The gateway dark-launch has its own six fixed, reviewed cases. It never
    # touches fixture recordings or a model endpoint; extraction remains an
    # explicit one-credit experiment.
    if mode == "gateway":
        if args.update_recordings:
            print("agent-search eval: FAIL: gateway mode cannot update recordings", file=sys.stderr)
            return 2
        try:
            from . import gateway as gateway_mod

            gateway_corpus = gateway_mod.load_gateway_corpus()
            requested = _split_csv(args.case)
            known = {case.id for case in gateway_corpus.cases}
            unknown = set(requested) - known
            if unknown:
                raise gateway_mod.GatewayEvalError(
                    "unknown gateway case id(s): " + ", ".join(sorted(unknown))
                )
            cases = [case for case in gateway_corpus.cases if not requested or case.id in requested]
            if not cases:
                raise gateway_mod.GatewayEvalError("gateway case selection is empty")
            budget = Budget.default().with_overrides(
                max_tool_calls=args.max_tool_calls,
                max_model_calls=args.max_model_calls,
                max_candidates_in=args.max_candidates_in,
                max_recommendations=args.max_recommendations,
                wall_clock_s=args.wall_clock_s,
                max_tokens_per_completion=args.max_tokens_per_completion,
            )
            outcomes = []
            for case in cases:
                # A fresh capability and hard budget per case prevents a slow
                # provider from consuming another reviewed case's allowance.
                outcomes.append(gateway_mod.run_gateway_case(case, gateway_mod.build_gateway_toolbox(budget), budget))
            firecrawl = gateway_mod.run_firecrawl_experiment(
                gateway_mod.build_gateway_toolbox(budget),
                cases[0],
                budget,
                enabled=args.firecrawl_experiment,
            )
            records = gateway_mod.build_gateway_records(
                gateway_corpus,
                outcomes,
                firecrawl=firecrawl,
                local_resource=runner_mod.local_resource_observation(),
                run_state=args.run_state,
            )
            run_id = args.run_id.strip() or f"agent-search-gateway-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
            output = args.output.strip() or str(Path(os.environ.get("TMPDIR", "/tmp")) / f"{run_id}.jsonl")
            runner_mod.write_artifact(output, records)
        except Exception as exc:
            # Gateway constructors and typed tool errors redact endpoint and
            # capability values; do not render arbitrary exception data.
            print(f"agent-search eval: FAIL: {type(exc).__name__}", file=sys.stderr)
            return 1
        failed = sum(outcome.terminal == "failed" for outcome in outcomes)
        degraded = sum(outcome.degradation != "none" for outcome in outcomes)
        print(
            f"agent-search eval: mode=gateway cases={len(outcomes)} failed={failed} "
            f"degraded={degraded} firecrawl_requests={(firecrawl or {}).get('firecrawlRequests', 0)} artifact={output}"
        )
        return 1 if failed else 0

    if args.firecrawl_experiment:
        print("agent-search eval: FAIL: --firecrawl-experiment requires --mode gateway", file=sys.stderr)
        return 2

    try:
        corpus = corpus_mod.load_corpus()
    except corpus_mod.CorpusError as exc:
        print(f"agent-search eval: FAIL: {exc}", file=sys.stderr)
        return 1

    try:
        cases = corpus_mod.select_cases(corpus, _split_csv(args.case) or None)
        arms = resolve_arm_names(_split_csv(args.arm) or None)
    except (corpus_mod.CorpusError, KeyError) as exc:
        print(f"agent-search eval: FAIL: {exc}", file=sys.stderr)
        return 1

    budget = Budget.default().with_overrides(
        max_tool_calls=args.max_tool_calls,
        max_model_calls=args.max_model_calls,
        max_candidates_in=args.max_candidates_in,
        max_recommendations=args.max_recommendations,
        wall_clock_s=args.wall_clock_s,
        max_tokens_per_completion=args.max_tokens_per_completion,
    )

    run_id = args.run_id.strip() or f"agent-search-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    default_output = str(Path(os.environ.get("TMPDIR", "/tmp")) / f"{run_id}.jsonl")
    output = args.output.strip() or default_output
    min_pass_rate = args.min_pass_rate if args.min_pass_rate is not None else (1.0 if mode == "replay" else 0.0)

    model = "replay"
    tool_transport = "none"
    probe_evidence = None
    api_key = ""
    run_timeout_s: Optional[float] = None

    if mode == "live":
        try:
            from ..model_client import ModelConfig, probe_structured_output

            _apply_live_endpoint_overrides(args.base_url, args.model)
            config = ModelConfig.from_env()
            model = config.model
            api_key = config.api_key
            run_timeout_s = config.run_timeout_s
            # The probe records json_object enforcement (the transport we use) and
            # native-tool support (evidence only). json_schema is silently ignored
            # by the endpoint, so the transport is always structured_action.
            probe_evidence = (
                {"transport": "structured_action", "status": "skipped"}
                if args.skip_probe
                else probe_structured_output(config)
            )
            tool_transport = probe_evidence.get("transport", "structured_action")
        except Exception:  # pragma: no cover - live only
            print("agent-search eval: FAIL: LiveModelInitializationError", file=sys.stderr)
            return 1

    cfg = runner_mod.RunConfig(
        mode=mode,
        arms=arms,
        run_id=run_id,
        model=model,
        prompt_revision=corpus.promptRevision or PROMPT_REVISION,
        budget=budget,
        tool_transport=tool_transport,
        probe_evidence=probe_evidence,
        record_dir=Path(args.record_dir) if args.record_dir.strip() else None,
        update_recordings=args.update_recordings,
        default_limit=args.limit,
        run_timeout_s=run_timeout_s,
        run_state=args.run_state,
    )

    outcomes = runner_mod.run(corpus, cases, cfg)
    records = runner_mod.build_records(outcomes, cfg)
    runner_mod.write_artifact(output, records, api_key=api_key)

    totals = runner_mod.summarize(outcomes, arms)["overall"]
    print(
        "agent-search eval: mode={mode} arms={arms} graded={graded} passed={passed} "
        "skipped={skipped} pass_rate={rate:.3f} safety_failures={safety} artifact={artifact}".format(
            mode=mode,
            arms=",".join(arms),
            graded=totals["graded"],
            passed=totals["passed"],
            skipped=totals["skipped"],
            rate=totals["passRate"],
            safety=totals["safetyFailures"],
            artifact=output,
        )
    )

    if totals["safetyFailures"] > 0:
        print("agent-search eval: FAIL: one or more safety graders failed", file=sys.stderr)
        return 1
    if totals["graded"] == 0 and mode == "replay":
        # A replay that grades nothing (any arm selection, e.g. only model arms with
        # their recordings absent) is a misconfiguration, not a vacuous pass.
        print("agent-search eval: FAIL: no graded outcomes in replay", file=sys.stderr)
        return 1

    if mode == "replay":
        # Replay is an EXACT-match gate against the pinned known-failures manifest,
        # not a pass-rate threshold: the deep_agent prototype's intended failures
        # stay visible while the gate stays green and meaningful. Any unexpected
        # failure, stale entry, or grader-set mismatch fails the gate. Safety
        # failures are handled above and can never be excused here.
        try:
            manifest = known_failures_mod.load_manifest()
            known_failures_mod.validate_manifest(manifest, corpus, arms=ALL_ARMS)
        except known_failures_mod.KnownFailuresError as exc:
            print(f"agent-search eval: FAIL: {exc}", file=sys.stderr)
            return 1
        comparison = known_failures_mod.compare(outcomes, manifest)
        if not comparison.matched:
            for line in comparison.delta_lines():
                print(line, file=sys.stderr)
            print(
                "agent-search eval: FAIL: known-failures manifest did not match "
                f"({len(comparison.deltas)} delta(s))",
                file=sys.stderr,
            )
            return 1
        print(
            "agent-search eval: replay gate PASS: {passed} passed / "
            "{kf} known-failures matched / {safety} safety "
            "(known_failures={kf} matched)".format(
                passed=totals["passed"],
                kf=comparison.matched_count,
                safety=totals["safetyFailures"],
            )
        )
        return 0

    # Live mode: advisory min-pass-rate gate; the manifest is ignored.
    if totals["passRate"] < min_pass_rate:
        print(
            f"agent-search eval: FAIL: pass rate {totals['passRate']:.3f} below required {min_pass_rate:.3f}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
