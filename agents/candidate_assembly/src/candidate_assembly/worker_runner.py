"""Bounded stdin/stdout JSONL runner for durable candidate-assembly jobs.

The Go lifecycle runner owns persistence, retries, and process lifetime. This
module owns only one immutable request snapshot and never opens a URL, reads a
credential from stdin, or writes anything except strict JSONL records to stdout.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import Optional, TextIO

from .arms import direct_judge as direct_logic
from .arms.deep_agent import DeepAgentArm
from .budgets import BUDGET_EXCEEDED_CODE, Budget, BudgetExceeded
from .fixture_tools import ToolError
from .model_client import (
    ModelAttempt,
    ModelConfig,
    StructuredOutputError,
    build_openai_client,
    coerce_judgments_envelope,
    complete_structured,
    make_json_object_chat,
    schema_prompt,
)
from .schemas import (
    AssemblyResult,
    BudgetSpent,
    CaseInput,
    Evidence,
    InterpretedIntent,
    Provenance,
    Recommendation,
    WorkerDegradation,
    WorkerModelAttempt,
    WorkerRequest,
    WorkerRevision,
    WorkerStageTiming,
    WorkerTerminal,
    WorkerTiming,
)
from .snapshot_tools import SnapshotToolBox, SnapshotWorld
from .validate import canonical_track_duration, is_duration_mismatch, validate_result

def _now() -> float:
    return time.monotonic()


_PROCESS_STARTED = _now()
_MAX_STDIN_BYTES = 128 * 1024
_MAX_RESULT_BYTES = 24 * 1024
_MAX_MODEL_LIST_ITEMS = 8


class WorkerCancelled(Exception):
    """Signal-safe cancellation boundary; no partially constructed record emits."""


def _raise_cancelled(_signum, _frame) -> None:
    raise WorkerCancelled()


@dataclass
class StageRun:
    result: Optional[AssemblyResult]
    attempts: list[ModelAttempt]
    tool_calls: int
    request_bytes: int
    response_bytes: int
    latency_ms: int
    failure_code: Optional[str] = None


@dataclass
class RequestBudgetLedger:
    """One shared budget across direct and DeepAgent revisions."""

    budget: Budget
    request_started_at: float
    tool_calls: int = 0
    model_calls: int = 0
    request_bytes: int = 0
    response_bytes: int = 0

    @property
    def deadline(self) -> float:
        return self.request_started_at + self.budget.wall_clock_s

    def remaining_budget(self) -> Budget:
        return Budget(
            max_tool_calls=max(0, self.budget.max_tool_calls - self.tool_calls),
            max_model_calls=max(0, self.budget.max_model_calls - self.model_calls),
            recursion_limit=self.budget.recursion_limit,
            max_candidates_in=self.budget.max_candidates_in,
            max_recommendations=self.budget.max_recommendations,
            wall_clock_s=max(0.0, self.deadline - _now()),
            max_request_bytes=max(0, self.budget.max_request_bytes - self.request_bytes),
            max_response_bytes=max(0, self.budget.max_response_bytes - self.response_bytes),
            max_tokens_per_completion=self.budget.max_tokens_per_completion,
        )

    def can_start(self, *, min_tool_calls: int, min_model_calls: int) -> bool:
        remaining = self.remaining_budget()
        return (
            remaining.max_tool_calls >= min_tool_calls
            and remaining.max_model_calls >= min_model_calls
            and remaining.wall_clock_s > 0
            and remaining.max_request_bytes > 0
            and remaining.max_response_bytes > 0
        )

    def consume(self, stage: StageRun) -> None:
        self.tool_calls += stage.tool_calls
        self.model_calls += len(stage.attempts)
        self.request_bytes += stage.request_bytes
        self.response_bytes += stage.response_bytes


def _budget(request: WorkerRequest) -> Budget:
    value = request.budgets
    return Budget(
        max_tool_calls=value.maxToolCalls,
        max_model_calls=value.maxModelCalls,
        recursion_limit=value.recursionLimit,
        max_candidates_in=value.maxCandidatesIn,
        max_recommendations=value.maxRecommendations,
        wall_clock_s=value.wallClockMs / 1000,
        max_request_bytes=value.maxRequestBytes,
        max_response_bytes=value.maxResponseBytes,
        max_tokens_per_completion=value.maxTokensPerCompletion,
    )


def _load_model_config() -> ModelConfig:
    if os.environ.get("OMP_CANDIDATE_WORKER_LIVE") != "1":
        raise RuntimeError("MODEL_DISABLED")
    return ModelConfig.from_env()


def _safe_failure_code(code: str) -> str:
    allowed = {
        "MODEL_DISABLED",
        "MODEL_UNAVAILABLE",
        "MODEL_CONFIG_ERROR",
        "MODEL_FAILURE",
        "STRUCTURED_OUTPUT_ERROR",
        "VALIDATION_FAILED",
        "BUDGET_EXCEEDED",
        "CANCELLED",
        "INVALID_REQUEST",
    }
    return code if code in allowed else "MODEL_FAILURE"


def _run_direct(
    request: WorkerRequest,
    world: SnapshotWorld,
    budget: Budget,
    config: ModelConfig,
    deadline: float,
) -> StageRun:
    started = _now()
    attempts: list[ModelAttempt] = []
    toolbox = SnapshotToolBox(world, budget, deadline=deadline)

    def record_attempt(attempt: ModelAttempt) -> None:
        attempts.append(
            ModelAttempt(
                attempt=len(attempts) + 1,
                duration_ms=attempt.duration_ms,
                repair=attempt.repair,
                status=attempt.status,
            )
        )

    try:
        preference = direct_logic._platform_preference(request.query)
        retrieved = toolbox.search_sources(
            request.query,
            providers=preference or None,
            limit=budget.max_candidates_in,
        )
        catalog_tracks = toolbox.search_catalog(request.query, kind="track", limit=8)
        canonical = canonical_track_duration(world)
        catalog_ref = catalog_tracks[0].id if catalog_tracks else None

        features = [
            {
                "candidateId": candidate.candidateId,
                "title": candidate.title,
                "artist": candidate.artist,
                "uploader": candidate.uploader,
                "durationMs": candidate.durationMs,
                "deterministicScore": candidate.sourceQuality.score,
                "deterministicClassification": candidate.sourceQuality.classification,
            }
            for candidate in retrieved[: direct_logic._MAX_JUDGE_CANDIDATES]
        ]
        if budget.max_model_calls < 1:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "no model-call capacity remaining")
        client = build_openai_client(config)
        chat = make_json_object_chat(client, config, budget.max_tokens_per_completion)
        structured = complete_structured(
            chat,
            [
                {
                    "role": "system",
                    "content": direct_logic._SYSTEM_PROMPT
                    + "\n\n"
                    + schema_prompt(direct_logic._JudgeOutput),
                },
                {
                    "role": "user",
                    "content": json.dumps(
                        {"query": request.query, "candidates": features}, ensure_ascii=False
                    ),
                },
            ],
            direct_logic._JudgeOutput,
            coerce=coerce_judgments_envelope,
            max_repair=1 if budget.max_model_calls >= 2 else 0,
            attempt_callback=record_attempt,
        )
    except BudgetExceeded:
        return StageRun(
            None, attempts, toolbox.tool_calls, toolbox.request_bytes,
            toolbox.response_bytes, _elapsed_ms(started), "BUDGET_EXCEEDED",
        )
    except StructuredOutputError:
        return StageRun(
            None, attempts, toolbox.tool_calls, toolbox.request_bytes,
            toolbox.response_bytes, _elapsed_ms(started), "STRUCTURED_OUTPUT_ERROR",
        )
    except ToolError:
        return StageRun(
            None, attempts, toolbox.tool_calls, toolbox.request_bytes,
            toolbox.response_bytes, _elapsed_ms(started), "MODEL_FAILURE",
        )
    except WorkerCancelled:
        raise
    except Exception:
        return StageRun(
            None, attempts, toolbox.tool_calls, toolbox.request_bytes,
            toolbox.response_bytes, _elapsed_ms(started), "MODEL_FAILURE",
        )

    known = {candidate.candidateId: candidate for candidate in retrieved}
    blended = {candidate.candidateId: candidate.sourceQuality.score for candidate in retrieved}
    reasons: dict[str, str] = {}
    for judgment in structured.value.judgments:
        candidate = known.get(judgment.candidateId)
        if candidate is None:
            continue
        blended[judgment.candidateId] = direct_logic._clamp(
            judgment.score,
            candidate.sourceQuality.score - direct_logic._MAX_MODEL_SCORE_MOVEMENT,
            candidate.sourceQuality.score + direct_logic._MAX_MODEL_SCORE_MOVEMENT,
        )
        if judgment.reason.strip():
            reasons[judgment.candidateId] = judgment.reason.strip()

    ordered_ids = sorted(known, key=lambda candidate_id: (-blended[candidate_id], candidate_id))
    recommendations: list[Recommendation] = []
    for rank, candidate_id in enumerate(ordered_ids[: request.limit], start=1):
        candidate = known[candidate_id]
        mismatch = bool(canonical) and is_duration_mismatch(candidate.durationMs, canonical)
        evidence = [Evidence(tool="search_sources", ref=candidate_id)]
        if canonical and catalog_ref:
            evidence.append(Evidence(tool="search_catalog", ref=catalog_ref))
        recommendations.append(
            Recommendation(
                candidateId=candidate_id,
                rank=rank,
                confidence=direct_logic._confidence_for_score(blended[candidate_id]),
                rationale=(
                    reasons.get(candidate_id)
                    or direct_logic._rationale(candidate.sourceQuality.classification, [])
                )[:240],
                classification=candidate.sourceQuality.classification,
                evidence=evidence,
                warnings=direct_logic._map_warnings(
                    candidate.sourceQuality.warnings, mismatch
                ),
            )
        )
    result = AssemblyResult(
        arm="direct_judge",
        interpretedIntent=InterpretedIntent(
            searchQueries=[request.query],
            platformPreference=direct_logic._platform_preference(request.query),
            desiredKinds=direct_logic._desired_kinds(request.query),
            durationTargetMs=canonical,
            notes="Single-shot judge re-ranking of the supplied snapshot.",
        ),
        recommendations=recommendations,
        unresolved=[],
        trace=list(toolbox.trace),
        budgetSpent=BudgetSpent(
            toolCalls=toolbox.tool_calls,
            modelCalls=min(structured.calls_used, budget.max_model_calls),
            elapsedMs=_elapsed_ms(started),
        ),
        provenance=Provenance(
            orchestrator=direct_logic.ORCHESTRATOR_ID,
            model=config.model,
            toolTransport="none",
            jsonMode=True,
            notes=structured.provenance_notes or None,
        ),
    )
    return StageRun(
        result, attempts, toolbox.tool_calls, toolbox.request_bytes,
        toolbox.response_bytes, _elapsed_ms(started),
    )


def _run_deep(
    request: WorkerRequest,
    world: SnapshotWorld,
    budget: Budget,
    config: ModelConfig,
    deadline: float,
) -> StageRun:
    started = _now()
    toolbox = SnapshotToolBox(world, budget, deadline=deadline)
    arm = DeepAgentArm()
    result = arm.assemble_snapshot(
        CaseInput(prompt=request.query, limit=request.limit), toolbox, world, budget, config
    )
    latency_ms = _elapsed_ms(started)
    result.budgetSpent.elapsedMs = latency_ms
    failure = _safe_failure_code(result.error.code) if result.error else None
    return StageRun(
        result if result.error is None else None, list(arm.model_attempts),
        toolbox.tool_calls, toolbox.request_bytes, toolbox.response_bytes,
        latency_ms, failure,
    )


def _elapsed_ms(started: float) -> int:
    return max(0, int(round((_now() - started) * 1000)))


def _stage_timing(stage: StageRun) -> WorkerStageTiming:
    return WorkerStageTiming(
        latencyMs=stage.latency_ms,
        toolCalls=stage.tool_calls,
        modelAttempts=[
            {
                "attempt": attempt.attempt,
                "durationMs": attempt.duration_ms,
                "repair": attempt.repair,
                "status": attempt.status,
            }
            for attempt in stage.attempts
        ],
    )


def _validated_revision(
    request: WorkerRequest,
    stage: str,
    stage_run: StageRun,
    world: SnapshotWorld,
    budget: Budget,
    deadline: float,
) -> Optional[WorkerRevision]:
    if stage_run.result is None:
        return None
    if _now() >= deadline:
        stage_run.failure_code = "BUDGET_EXCEEDED"
        return None
    # Validate the original structured model result before projecting it. A URL,
    # secret, invented id, or unbounded model payload is a degradation, never a
    # revision, even though the later projection would otherwise discard it.
    raw_report = validate_result(
        stage_run.result, world, budget, allowlist=world.candidate_ids()
    )
    if not raw_report.passed or not _bounded_model_result(stage_run.result):
        stage_run.failure_code = "VALIDATION_FAILED"
        return None
    _project_safe_revision_fields(stage_run.result, request, world)
    projected_report = validate_result(
        stage_run.result, world, budget, allowlist=world.candidate_ids()
    )
    if not projected_report.passed:
        stage_run.failure_code = "VALIDATION_FAILED"
        return None
    return WorkerRevision(
        jobId=request.jobId,
        runId=request.runId,
        stage=stage,
        result=stage_run.result,
        timing=_stage_timing(stage_run),
    )


def _bounded_model_result(result: AssemblyResult) -> bool:
    """Apply worker-specific output ceilings absent from the eval artifact schema."""

    intent = result.interpretedIntent
    if any(
        len(values) > _MAX_MODEL_LIST_ITEMS
        for values in (intent.searchQueries, intent.platformPreference, intent.desiredKinds)
    ):
        return False
    if len(result.unresolved) > _MAX_MODEL_LIST_ITEMS:
        return False
    if any(
        len(recommendation.evidence) > _MAX_MODEL_LIST_ITEMS
        or len(recommendation.warnings) > _MAX_MODEL_LIST_ITEMS
        for recommendation in result.recommendations
    ):
        return False
    return len(result.model_dump_json(exclude_none=True).encode("utf-8")) <= _MAX_RESULT_BYTES


def _project_safe_revision_fields(
    result: AssemblyResult, request: WorkerRequest, world: SnapshotWorld
) -> None:
    """Keep revision text server-owned except for validated bounded rationales."""

    result.interpretedIntent = InterpretedIntent(
        searchQueries=[request.query],
        platformPreference=direct_logic._platform_preference(request.query),
        desiredKinds=direct_logic._desired_kinds(request.query),
        durationTargetMs=canonical_track_duration(world),
        notes="",
    )
    result.unresolved = []
    for recommendation in result.recommendations:
        recommendation.evidence = [
            Evidence(tool="search_sources", ref=recommendation.candidateId)
        ]


def _write_record(output: TextIO, record: WorkerRevision | WorkerTerminal) -> None:
    payload = record.model_dump_json(exclude_none=True)
    # A complete serialized record is constructed before stdout is touched.
    output.write(payload + "\n")
    output.flush()


def _terminal(
    request: Optional[WorkerRequest],
    accepted_at: Optional[float],
    *,
    outcome: str,
    revisions: int,
    degradations: list[WorkerDegradation],
    direct_first_ms: Optional[int],
    stage_runs: list[tuple[str, StageRun]],
) -> WorkerTerminal:
    attempts = [
        WorkerModelAttempt(
            stage=stage,
            attempt=attempt.attempt,
            durationMs=attempt.duration_ms,
            repair=attempt.repair,
            status=attempt.status,
        )
        for stage, run in stage_runs
        for attempt in run.attempts
    ]
    return WorkerTerminal(
        jobId=request.jobId if request else None,
        runId=request.runId if request else None,
        outcome=outcome,
        revisionsEmitted=revisions,
        degradations=degradations,
        timing=WorkerTiming(
            processStartupToRequestAcceptedMs=(
                max(0, int(round((accepted_at - _PROCESS_STARTED) * 1000)))
                if accepted_at is not None
                else None
            ),
            requestAcceptedToDirectFirstRevisionMs=direct_first_ms,
            requestAcceptedToFinalMs=(
                _elapsed_ms(accepted_at) if accepted_at is not None else None
            ),
            toolCalls=sum(run.tool_calls for _, run in stage_runs),
            modelAttempts=attempts,
        ),
    )


def run_stream(input_stream: TextIO, output: TextIO) -> int:
    """Read exactly one JSON request and write zero or more revisions plus terminal."""

    request_started_at = _now()
    accepted_at: Optional[float] = None
    request: Optional[WorkerRequest] = None
    try:
        raw = input_stream.read(_MAX_STDIN_BYTES + 1)
        if len(raw.encode("utf-8")) > _MAX_STDIN_BYTES:
            raise ValueError("request too large")
        lines = [line for line in raw.splitlines() if line.strip()]
        if len(lines) != 1:
            raise ValueError("expected exactly one JSONL request")
        request = WorkerRequest.model_validate_json(lines[0])
        # Request acceptance means stdin is fully consumed and the strict schema
        # has passed, not merely that the child process started reading.
        accepted_at = _now()
    except WorkerCancelled:
        _write_record(
            output,
            _terminal(
                None,
                None,
                outcome="cancelled",
                revisions=0,
                degradations=[WorkerDegradation(stage="protocol", code="CANCELLED")],
                direct_first_ms=None,
                stage_runs=[],
            ),
        )
        return 143
    except Exception:
        _write_record(
            output,
            _terminal(
                None,
                None,
                outcome="invalid_request",
                revisions=0,
                degradations=[WorkerDegradation(stage="protocol", code="INVALID_REQUEST")],
                direct_first_ms=None,
                stage_runs=[],
            ),
        )
        return 2

    try:
        config = _load_model_config()
    except WorkerCancelled:
        _write_record(
            output,
            _terminal(
                request,
                accepted_at,
                outcome="cancelled",
                revisions=0,
                degradations=[WorkerDegradation(stage="protocol", code="CANCELLED")],
                direct_first_ms=None,
                stage_runs=[],
            ),
        )
        return 143
    except Exception as exc:
        code = "MODEL_DISABLED" if str(exc) == "MODEL_DISABLED" else "MODEL_CONFIG_ERROR"
        first_stage = "direct_judge" if request.stages.directJudge else "deep_agent"
        _write_record(
            output,
            _terminal(
                request,
                accepted_at,
                outcome="unavailable",
                revisions=0,
                degradations=[WorkerDegradation(stage=first_stage, code=code)],
                direct_first_ms=None,
                stage_runs=[],
            ),
        )
        return 0

    assert accepted_at is not None
    budget = _budget(request)
    ledger = RequestBudgetLedger(budget, request_started_at)
    world = SnapshotWorld(request.candidates, request.catalog, request.metadata)
    stage_runs: list[tuple[str, StageRun]] = []
    degradations: list[WorkerDegradation] = []
    revisions = 0
    direct_first_ms: Optional[int] = None
    try:
        if request.stages.directJudge:
            direct_budget = ledger.remaining_budget()
            if ledger.can_start(min_tool_calls=2, min_model_calls=1):
                try:
                    direct = _run_direct(
                        request, world, direct_budget, config, ledger.deadline
                    )
                except WorkerCancelled:
                    raise
                except Exception:
                    direct = StageRun(None, [], 0, 0, 0, 0, "MODEL_FAILURE")
            else:
                direct = StageRun(None, [], 0, 0, 0, 0, "BUDGET_EXCEEDED")
            ledger.consume(direct)
            stage_runs.append(("direct_judge", direct))
            revision = _validated_revision(
                request, "direct_judge", direct, world, direct_budget, ledger.deadline
            )
            if revision is not None:
                _write_record(output, revision)
                revisions += 1
                direct_first_ms = _elapsed_ms(accepted_at)
            else:
                degradations.append(
                    WorkerDegradation(
                        stage="direct_judge",
                        code=_safe_failure_code(direct.failure_code or "MODEL_FAILURE"),
                    )
                )
        if request.stages.deepAgent:
            deep_budget = ledger.remaining_budget()
            if ledger.can_start(min_tool_calls=1, min_model_calls=1):
                try:
                    deep = _run_deep(
                        request, world, deep_budget, config, ledger.deadline
                    )
                except WorkerCancelled:
                    raise
                except Exception:
                    deep = StageRun(None, [], 0, 0, 0, 0, "MODEL_FAILURE")
            else:
                deep = StageRun(None, [], 0, 0, 0, 0, "BUDGET_EXCEEDED")
            ledger.consume(deep)
            stage_runs.append(("deep_agent", deep))
            revision = _validated_revision(
                request, "deep_agent", deep, world, deep_budget, ledger.deadline
            )
            if revision is not None:
                _write_record(output, revision)
                revisions += 1
            else:
                degradations.append(
                    WorkerDegradation(
                        stage="deep_agent",
                        code=_safe_failure_code(deep.failure_code or "MODEL_FAILURE"),
                    )
                )
    except WorkerCancelled:
        cancel_stage = "protocol"
        if request.stages.deepAgent and stage_runs:
            cancel_stage = "deep_agent"
        elif request.stages.directJudge:
            cancel_stage = "direct_judge"
        _write_record(
            output,
            _terminal(
                request,
                accepted_at,
                outcome="cancelled",
                revisions=revisions,
                degradations=[WorkerDegradation(stage=cancel_stage, code="CANCELLED")],
                direct_first_ms=direct_first_ms,
                stage_runs=stage_runs,
            ),
        )
        return 143

    outcome = "completed" if not degradations else "degraded"
    _write_record(
        output,
        _terminal(
            request,
            accepted_at,
            outcome=outcome,
            revisions=revisions,
            degradations=degradations,
            direct_first_ms=direct_first_ms,
            stage_runs=stage_runs,
        ),
    )
    return 0


def main() -> int:
    signal.signal(signal.SIGTERM, _raise_cancelled)
    signal.signal(signal.SIGINT, _raise_cancelled)
    return run_stream(sys.stdin, sys.stdout)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
