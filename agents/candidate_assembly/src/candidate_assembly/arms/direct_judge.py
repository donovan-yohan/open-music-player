"""Single-shot judge arm — mirrors the shipped Ollama source-quality judge.

Deterministic ranking runs first (the real Go scorer); then ONE structured model
call re-scores the bounded candidate features, exactly like the production
``SourceQualityJudge``: model score movement is clamped to ±15 around the
deterministic score, and unknown candidate ids are rejected and fall back
deterministically. This arm answers "what does the shipped judge already buy?"
so the deep-agent comparison is honest.

The model stack is imported lazily; this arm only runs in live mode.
"""

from __future__ import annotations

import time
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field

from .. import go_ranker
from ..budgets import Budget
from ..fixture_tools import ToolBox
from ..model_client import (
    ModelConfig,
    ModelAttempt,
    StructuredOutputError,
    build_openai_client,
    coerce_judgments_envelope,
    complete_structured,
    make_json_object_chat,
    schema_prompt,
)
from ..schemas import (
    AssemblyResult,
    AssemblyError,
    BudgetSpent,
    CaseInput,
    Evidence,
    FixtureWorld,
    InterpretedIntent,
    Provenance,
    ProgressEvent,
    Recommendation,
)
from ..validate import canonical_track_duration, is_duration_mismatch
from .deterministic import _desired_kinds, _map_warnings, _platform_preference, _rationale

ORCHESTRATOR_ID = "direct-judge-v1"

# Same ceiling as the production judge: it scores a bounded, small candidate set.
_MAX_JUDGE_CANDIDATES = 8
_MAX_MODEL_SCORE_MOVEMENT = 15

_SYSTEM_PROMPT = (
    "You are a music source-quality judge. You are given a user query and a small "
    "list of already-retrieved candidate sources with deterministic scores. For "
    "each candidate id you MUST return a score from 0 to 100 and a short reason. "
    "Prefer official audio and topic-channel uploads; avoid music videos, live "
    "versions, covers, sped-up/slowed edits, and shorts unless the user asked for "
    "them. You may only score candidate ids that appear in the input. Do not "
    "invent ids, urls, or downloads."
)


class _Judgment(BaseModel):
    model_config = ConfigDict(extra="forbid")
    candidateId: str
    score: int = Field(ge=0, le=100)
    reason: str = Field(default="", max_length=200)


class _JudgeOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    judgments: list[_Judgment] = Field(default_factory=list)


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(value, high))


def _confidence_for_score(score: int) -> float:
    return round(0.35 + (score / 100 * 0.6), 2)


class DirectJudgeArm:
    name = "direct_judge"

    def assemble(
        self, case_input: CaseInput, world: FixtureWorld, budget: Budget
    ) -> AssemblyResult:
        self._started = time.monotonic()
        self.model_attempts: list[ModelAttempt] = []
        self.progress_events: list[ProgressEvent] = []
        self.tool_dispatch_latency_ms = 0
        self.finalization_ms: Optional[int] = None
        self._emit("lifecycle", "started")
        toolbox = ToolBox(world, budget)
        # Expose the tool-returned id allowlist for the grounding validator.
        self.allowlist = toolbox.allowlist
        try:
            config = ModelConfig.from_env()
        except Exception:
            self._emit("lifecycle", "failed", status="failed")
            return self._error_result(toolbox, None, "MODEL_CONFIG_ERROR")
        preference = _platform_preference(case_input.prompt)
        retrieved = self._dispatch_tool(
            toolbox, "search_sources", case_input.prompt,
            providers=preference or None, limit=budget.max_candidates_in,
        )
        catalog_tracks = self._dispatch_tool(
            toolbox, "search_catalog", case_input.prompt, kind="track", limit=8
        )
        canonical = canonical_track_duration(world)
        catalog_ref = catalog_tracks[0].id if catalog_tracks else None

        candidate_dicts = [c.model_dump(exclude_none=True) for c in retrieved]
        ranked = go_ranker.rank(case_input.prompt, candidate_dicts)

        # Deterministic score/classification per id, from the Go scorer.
        det_score: dict[str, int] = {}
        det_class: dict[str, str] = {}
        det_warnings: dict[str, list[str]] = {}
        for candidate in ranked:
            quality = (candidate.get("metadata") or {}).get("sourceQuality") or {}
            cid = candidate["candidateId"]
            det_score[cid] = int(quality.get("score", 55))
            det_class[cid] = quality.get("classification", "unknown")
            det_warnings[cid] = list(quality.get("warnings") or [])

        features = []
        for candidate in ranked[:_MAX_JUDGE_CANDIDATES]:
            cid = candidate["candidateId"]
            features.append(
                {
                    "candidateId": cid,
                    "title": candidate.get("title", ""),
                    "artist": candidate.get("artist", ""),
                    "uploader": candidate.get("uploader", ""),
                    "durationMs": candidate.get("durationMs"),
                    "deterministicScore": det_score.get(cid),
                    "deterministicClassification": det_class.get(cid),
                }
            )

        # json_object transport: the endpoint honors response_format json_object
        # (not json_schema), returning grammar-enforced JSON in message.content and
        # chain-of-thought separately in reasoning_content (which we never read).
        # complete_structured does one bounded repair retry on a parse/validation
        # failure; a second failure raises StructuredOutputError, which propagates
        # to the runner's typed-failure path. A bare judgments array is wrapped
        # before strict validation (recorded as a "coerced_envelope" note).
        client = build_openai_client(config)
        chat = make_json_object_chat(client, config, budget.max_tokens_per_completion)
        system = _SYSTEM_PROMPT + "\n\n" + schema_prompt(_JudgeOutput)
        user = {"query": case_input.prompt, "candidates": features}
        if budget.max_model_calls < 1:
            self._emit("lifecycle", "failed", status="failed")
            return self._error_result(toolbox, config, "BUDGET_EXCEEDED")
        self._emit("lifecycle", "finalizing", status="success")
        final_started = time.monotonic()
        try:
            structured = complete_structured(
                chat,
                [
                    {"role": "system", "content": system},
                    {"role": "user", "content": _json(user)},
                ],
                _JudgeOutput,
                coerce=coerce_judgments_envelope,
                max_repair=1 if budget.max_model_calls >= 2 else 0,
            )
        except StructuredOutputError as exc:
            self._record_attempts(exc.attempts)
            self.finalization_ms = int(round((time.monotonic() - final_started) * 1000))
            self._emit("lifecycle", "failed", status="failed")
            return self._error_result(toolbox, config, "STRUCTURED_OUTPUT_ERROR")
        self._record_attempts(structured.attempts)
        self.finalization_ms = int(round((time.monotonic() - final_started) * 1000))
        output: _JudgeOutput = structured.value
        model_calls = structured.calls_used
        provenance_notes = structured.provenance_notes

        known = set(det_score)
        blended: dict[str, int] = dict(det_score)
        reasons: dict[str, str] = {}
        for judgment in output.judgments:
            if judgment.candidateId not in known:
                continue  # unknown-id rejection: fall back deterministically.
            base = det_score[judgment.candidateId]
            blended[judgment.candidateId] = _clamp(
                judgment.score, base - _MAX_MODEL_SCORE_MOVEMENT, base + _MAX_MODEL_SCORE_MOVEMENT
            )
            if judgment.reason.strip():
                reasons[judgment.candidateId] = judgment.reason.strip()

        reranked = sorted(
            (c["candidateId"] for c in ranked),
            key=lambda cid: (-blended.get(cid, det_score.get(cid, 0)), cid),
        )

        top_n = min(case_input.limit, budget.max_recommendations, len(reranked))
        recommendations: list[Recommendation] = []
        for position, cid in enumerate(reranked[:top_n], start=1):
            candidate = world.by_id(cid)
            duration_ms = candidate.durationMs if candidate else None
            mismatch = bool(canonical) and is_duration_mismatch(duration_ms, canonical)
            classification = det_class.get(cid, "unknown")
            evidence = [Evidence(tool="search_sources", ref=cid)]
            if canonical and catalog_ref:
                evidence.append(Evidence(tool="search_catalog", ref=catalog_ref))
            rationale = reasons.get(cid) or _rationale(classification, [])
            recommendations.append(
                Recommendation(
                    candidateId=cid,
                    rank=position,
                    confidence=_confidence_for_score(blended.get(cid, det_score.get(cid, 55))),
                    rationale=rationale[:240],
                    classification=classification,
                    evidence=evidence,
                    warnings=_map_warnings(det_warnings.get(cid, []), mismatch),
                )
            )

        unresolved: list[str] = []
        if canonical is None and any(entry.kind == "track" for entry in world.catalog):
            unresolved.append(
                "Catalog has no canonical duration for the interpreted track; duration cross-check skipped."
            )

        intent = InterpretedIntent(
            searchQueries=[case_input.prompt],
            platformPreference=preference,
            desiredKinds=_desired_kinds(case_input.prompt),
            durationTargetMs=canonical,
            notes="Single-shot judge re-ranking of the deterministic pool.",
        )

        return AssemblyResult(
            arm=self.name,
            interpretedIntent=intent,
            recommendations=recommendations,
            unresolved=unresolved,
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls,
                modelCalls=min(model_calls, budget.max_model_calls),
                elapsedMs=0,
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model,
                toolTransport="none",
                jsonMode=True,
                notes=provenance_notes or None,
            ),
        )

    def _dispatch_tool(self, toolbox: ToolBox, tool: str, *args: Any, **kwargs: Any) -> Any:
        before = len(toolbox.trace)
        started = time.monotonic()
        try:
            return getattr(toolbox, tool)(*args, **kwargs)
        finally:
            if len(toolbox.trace) > before:
                self.tool_dispatch_latency_ms += int(round((time.monotonic() - started) * 1000))
                trace = toolbox.trace[-1]
                self._emit("tool", "tool_completed", tool=trace.tool, result_count=trace.resultCount)

    def _error_result(
        self, toolbox: ToolBox, config: Optional[ModelConfig], code: str
    ) -> AssemblyResult:
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=InterpretedIntent(notes="direct judge unavailable"),
            recommendations=[],
            unresolved=[],
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls,
                modelCalls=min(len(self.model_attempts), toolbox.budget.max_model_calls),
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model if config else "",
                toolTransport="none",
                jsonMode=True if config else None,
            ),
            error=AssemblyError(
                code=code,
                message="direct judge did not produce a structured result",
            ),
        )

    def _record_attempts(self, attempts: list[ModelAttempt]) -> None:
        for attempt in attempts:
            recorded = ModelAttempt(
                attempt=len(self.model_attempts) + 1,
                duration_ms=attempt.duration_ms,
                repair=attempt.repair,
                status=attempt.status,
            )
            self.model_attempts.append(recorded)
            self._emit("lifecycle", "model_call", attempt=recorded.attempt,
                       repair=recorded.repair, status=recorded.status)

    def _emit(
        self, kind: str, phase: str, *, attempt: Optional[int] = None,
        repair: Optional[bool] = None, status: Optional[str] = None,
        tool: Optional[str] = None, result_count: Optional[int] = None,
    ) -> None:
        self.progress_events.append(
            ProgressEvent(
                sequence=len(self.progress_events) + 1,
                kind=kind, phase=phase,
                elapsedMs=int(round((time.monotonic() - self._started) * 1000)),
                attempt=attempt, repair=repair, status=status, tool=tool,
                resultCount=result_count,
            )
        )


def _json(value) -> str:
    import json

    return json.dumps(value, ensure_ascii=False)
