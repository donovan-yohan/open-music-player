"""The prototype under evaluation: a bounded DeepAgents / LangGraph tool loop.

Per the Finn-Nancy spike, the built-in DeepAgents planning + filesystem loop is
non-terminating, so this arm drives ONLY our three read-only tools and enforces
the same budgets as every other arm through the shared ``ToolBox``. The default
transport is a structured-action loop (each step the model emits an
``AgentAction`` via json_object and the runner executes the tool). Native tool
support is probe- and model-dependent, but is recorded as probe evidence only;
native execution is intentionally disabled until it has bounded instrumentation.

The langchain / deepagents stack is imported lazily; this arm only runs live.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any, Optional

from .. import go_ranker
from ..budgets import BUDGET_EXCEEDED_CODE, Budget, BudgetExceeded
from ..fixture_tools import ToolBox, ToolError
from ..model_client import (
    ModelConfig,
    ModelAttempt,
    StructuredOutputError,
    build_openai_client,
    complete_structured,
    make_json_object_chat,
    schema_prompt,
)
from ..schemas import (
    AgentAction,
    AgentFinalOutput,
    AssemblyError,
    AssemblyResult,
    BudgetSpent,
    CaseInput,
    FixtureWorld,
    InterpretedIntent,
    Provenance,
    ProgressEvent,
    Recommendation,
)

ORCHESTRATOR_ID = "deepagents-0.6.12"

_SYSTEM_PROMPT = (
    "You are OMP's candidate-assembly agent for natural-language song search. "
    "You assemble a sorted, structured list of source candidates by CALLING TOOLS; "
    "you never download, play, or verify anything on the open web. Available "
    "tools: search_sources(query, providers, limit), search_catalog(query, kind, "
    "limit), inspect_source_metadata(candidate_id). Call ONE tool per turn, and "
    "only ever recommend candidateIds that a tool actually returned.\n"
    "\n"
    "PROCESS. Issue one or two query variants and dedupe the results. Call "
    "search_catalog with kind=\"track\" (the catalog kinds are exactly track, "
    "artist, album -- never pass a source-quality label like official_audio as "
    "the kind) to read the canonical track and its durationMs; record that "
    "durationMs as your durationTargetMs. If a search_catalog call returns "
    "nothing, retry it ONCE with kind=\"track\" and a simplified query of just "
    "the artist and track title; if it is still empty, add a note to unresolved "
    "that the canonical track duration is unknown and skip the duration "
    "cross-check.\n"
    "\n"
    "RANK. Rank #1 the best match for what the user asked for: prefer official "
    "audio and topic-channel audio uploads when the user wants audio; when the "
    "user explicitly asks for a live, remix, cover, or other specific variant, "
    "the matching variant is the winner. Honor any requested platform: when the "
    "user names a platform, recommend ONLY candidates from that platform and omit "
    "the others entirely.\n"
    "\n"
    "KEEP-AND-TAG, never silently drop. Plausible-but-imperfect near-misses of "
    "the requested song -- music videos, live versions, covers, remixes, sped-up "
    "/ slowed / nightcore / 8D or otherwise altered edits, short or snippet "
    "clips, and off-duration re-uploads (e.g. reaction or commentary uploads) -- "
    "MUST be INCLUDED in the ranked list, ranked BELOW the better matches, each "
    "carrying every applicable warning. Omit a result ONLY when it is genuinely a "
    "different song or a different artist (e.g. a 'type beat' or an unrelated "
    "track).\n"
    "\n"
    "WARNINGS. Draw every warning from EXACTLY this vocabulary: duration_mismatch, "
    "music_video, short_version, live, remix, altered_audio, platform_mismatch, "
    "cover, lyric_video, interview, visualizer, not_downloadable. Tag each "
    "recommendation with all that apply: music_video for official/music videos, "
    "live for live or concert versions, cover for covers, remix for remixes, "
    "altered_audio for sped-up / slowed / nightcore / 8D / pitched edits, "
    "short_version for shorts, snippets, or TikTok cuts, lyric_video / visualizer "
    "/ interview for those formats, not_downloadable when a source cannot be "
    "downloaded, and platform_mismatch for an off-platform source.\n"
    "\n"
    "DURATION RULE. Any recommended candidate whose duration differs from the "
    "canonical catalog track duration by MORE THAN 2 seconds AND MORE THAN 7% "
    "MUST carry the duration_mismatch warning, in addition to any other "
    "applicable warning. This applies to shorts, live versions, and reaction "
    "re-uploads too.\n"
    "\n"
    "COUNT. Return the winner PLUS the flagged near-misses, up to the requested "
    "limit. A single-candidate answer is WRONG whenever the tools surfaced other "
    "plausible versions of the same song -- include and tag them, do not drop "
    "them. Rank EVERY clean official-audio, topic-audio, or artist audio match at "
    "the top, ahead of any music video, lyric video, live, cover, remix, altered, "
    "or off-duration near-miss. When the request limit is smaller than the number "
    "of candidates, keep the clean audio matches and drop the WEAKEST near-misses "
    "first -- never drop a clean audio match to make room for a near-miss.\n"
    "\n"
    "When you have enough evidence, FINALIZE with the structured assembly result: "
    "an interpreted intent, a ranked recommendation list (contiguous ranks from "
    "1, each with a candidateId that a tool returned, a confidence in [0,1], a "
    "short rationale with NO URLs, and warnings drawn from the vocabulary above), "
    "and any unresolved notes."
)

# The finalize step reuses the running action-loop conversation, whose assistant
# turns are all ``{"action": ..., "args": ...}`` objects. A small model is easily
# primed by that pattern to emit yet another action object at finalize instead of
# the assembly result, which then fails AgentFinalOutput validation (and can burn
# the repair retry too). This instruction explicitly closes the tool phase and
# names the exact top-level keys required, so the model switches shapes.
_FINALIZE_INSTRUCTION = (
    "Finalize now. The tool phase is over: do NOT return an action object and do "
    "NOT use the \"action\"/\"args\" shape. Return ONLY a single JSON object whose "
    "top-level keys are exactly interpretedIntent, recommendations, and unresolved, "
    "validating against the schema above. Include the winner AND every plausible "
    "near-miss of the same song you found, ranked below the winner, each tagged "
    "with the warnings that apply (duration_mismatch when its duration is off by "
    "more than 2s and 7%, plus music_video / live / cover / remix / altered_audio "
    "/ short_version as appropriate)."
)


def _max_repair_for_capacity(remaining_calls: int) -> int:
    if remaining_calls < 1:
        raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "no model-call capacity remaining")
    return 1 if remaining_calls >= 2 else 0


def _finalize_messages(prior: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Build the finalize-step message list from the running action-loop convo.

    Pins the AgentFinalOutput schema as the system turn (dropping the original
    system turn, which advertised the AgentAction schema and would keep priming
    action-shaped output), preserves the gathered tool observations, and appends
    the explicit anti-action finalize instruction. Pure — unit-tested without a
    network.
    """

    final_system = _SYSTEM_PROMPT + "\n\n" + schema_prompt(AgentFinalOutput)
    history = prior[1:] if prior and prior[0].get("role") == "system" else prior
    return _append_finalize_instruction([{"role": "system", "content": final_system}, *history])


def _append_finalize_instruction(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Preserve the conversation while keeping roles alternating after system."""

    messages = [dict(message) for message in messages]
    # The provider rejects adjacent user turns. If the last gathered observation
    # is already a user turn, retain it and append the instruction to that turn;
    # otherwise add the final user instruction as its own alternating turn.
    if messages[-1]["role"] == "user":
        messages[-1] = {
            **messages[-1],
            "content": messages[-1].get("content", "") + "\n\n" + _FINALIZE_INSTRUCTION,
        }
    else:
        messages.append({"role": "user", "content": _FINALIZE_INSTRUCTION})
    return messages


class DeepAgentArm:
    name = "deep_agent"

    def assemble(
        self, case_input: CaseInput, world: FixtureWorld, budget: Budget
    ) -> AssemblyResult:
        started = time.monotonic()
        self._started = started
        self.model_attempts: list[ModelAttempt] = []
        self.progress_events: list[ProgressEvent] = []
        self.finalization_ms: Optional[int] = None
        self.tool_dispatch_latency_ms = 0
        self._emit("lifecycle", "started")
        toolbox = ToolBox(world, budget)
        # Expose the tool-returned id allowlist for the grounding validator.
        self.allowlist = toolbox.allowlist
        transport = os.environ.get("AGENT_SEARCH_TOOL_TRANSPORT", "structured_action").strip()
        if transport == "native":
            self._emit("lifecycle", "failed", status="failed")
            return self._unsupported_transport_error(toolbox)
        try:
            config = ModelConfig.from_env()
        except Exception:
            self._emit("lifecycle", "failed", status="failed")
            return self._init_error(toolbox)
        try:
            transport = "structured_action"
            final, model_calls, notes = self._run_structured_action(
                case_input, toolbox, config, budget
            )
        except BudgetExceeded as exc:
            self._emit("lifecycle", "failed", status="failed")
            return self._budget_error(exc, toolbox, config, transport)
        except StructuredOutputError:
            self._emit("lifecycle", "failed", status="failed")
            return self._model_error(toolbox, config, transport)
        except Exception:
            # Do not copy raw endpoint exception text into artifacts. The trace,
            # spent attempts, and safe category remain useful for diagnosis.
            self._emit("lifecycle", "failed", status="failed")
            return self._model_error(toolbox, config, transport, code="MODEL_FAILURE")

        result = self._finalize(
            final, case_input, toolbox, config, transport, model_calls, notes
        )
        return result

    # -- transports -------------------------------------------------------

    def _run_structured_action(
        self, case_input: CaseInput, toolbox: ToolBox, config: ModelConfig, budget: Budget
    ) -> tuple[AgentFinalOutput, int, list[str]]:  # pragma: no cover - live only
        # json_object transport: the endpoint honors response_format json_object
        # (not json_schema). This explicit transport emits an AgentAction JSON
        # object, the runner executes the tool, and the observation is appended.
        # complete_structured does one bounded repair retry
        # per step; a second failure raises StructuredOutputError, which propagates
        # to the runner's typed-failure path. Every attempt (primary + repair)
        # counts against the model-call budget.
        client = build_openai_client(config)
        chat = make_json_object_chat(client, config, budget.max_tokens_per_completion)
        action_system = _SYSTEM_PROMPT + "\n\n" + schema_prompt(AgentAction)
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": action_system},
            {
                "role": "user",
                "content": _json({"prompt": case_input.prompt, "limit": case_input.limit}),
            },
        ]
        model_calls = 0
        notes: list[str] = []
        # Reserve at least one model call for the finalize step. A repair is only
        # permitted when it fits within the capacity left after that reservation.
        while model_calls < budget.max_model_calls - 1:
            action_capacity = budget.max_model_calls - model_calls - 1
            max_repair = _max_repair_for_capacity(action_capacity)
            try:
                step = complete_structured(
                    chat, messages, AgentAction, max_repair=max_repair
                )
            except StructuredOutputError as exc:
                self._record_attempts(exc.attempts)
                raise
            self._record_attempts(step.attempts)
            model_calls += step.calls_used
            notes.extend(step.provenance_notes)
            action: AgentAction = step.value
            if action.action == "finalize":
                break
            observation = self._dispatch(toolbox, action)
            messages.append({"role": "assistant", "content": _json(action.model_dump())})
            messages.append({"role": "user", "content": _json({"observation": observation})})

        final_messages = _finalize_messages(messages)
        self._emit("lifecycle", "finalizing", status="success")
        final_started = time.monotonic()
        max_repair = _max_repair_for_capacity(budget.max_model_calls - model_calls)
        try:
            final_step = complete_structured(
                chat, final_messages, AgentFinalOutput, max_repair=max_repair
            )
        except StructuredOutputError as exc:
            self._record_attempts(exc.attempts)
            self.finalization_ms = int(round((time.monotonic() - final_started) * 1000))
            raise
        self._record_attempts(final_step.attempts)
        self.finalization_ms = int(round((time.monotonic() - final_started) * 1000))
        model_calls += final_step.calls_used
        notes.extend(final_step.provenance_notes)
        return final_step.value, model_calls, notes

    # -- tool dispatch ----------------------------------------------------

    def _dispatch(self, toolbox: ToolBox, action: AgentAction) -> Any:  # pragma: no cover - live only
        args = action.args or {}
        trace_len = len(toolbox.trace)
        dispatched_at = time.monotonic()
        try:
            if action.action == "search_sources":
                results = toolbox.search_sources(
                    args.get("query", ""), args.get("providers"), args.get("limit", 10)
                )
                return [r.model_dump(exclude_none=True) for r in results]
            if action.action == "search_catalog":
                results = toolbox.search_catalog(
                    args.get("query", ""), args.get("kind", "track"), args.get("limit", 8)
                )
                return [r.model_dump(exclude_none=True) for r in results]
            if action.action == "inspect_source_metadata":
                return toolbox.inspect_source_metadata(args.get("candidate_id", "")).model_dump(
                    exclude_none=True
                )
        except ToolError as exc:
            return {"error": {"code": exc.code, "message": exc.message}}
        finally:
            if len(toolbox.trace) > trace_len:
                trace = toolbox.trace[-1]
                self.tool_dispatch_latency_ms += int(
                    round((time.monotonic() - dispatched_at) * 1000)
                )
                self._emit(
                    "tool", "tool_completed", tool=trace.tool, result_count=trace.resultCount
                )
        return {"error": {"code": "UNKNOWN_ACTION", "message": action.action}}

    # -- finalize ---------------------------------------------------------

    def _finalize(
        self,
        final: AgentFinalOutput,
        case_input: CaseInput,
        toolbox: ToolBox,
        config: ModelConfig,
        transport: str,
        model_calls: int,
        notes: list[str],
    ) -> AssemblyResult:  # pragma: no cover - live only
        recommendations = _coerce_recommendations(
            final.recommendations, case_input.limit
        )
        # The model does not (reliably) emit a source-quality classification, and
        # the classification-based graders would otherwise fail even on a correct
        # pick. Derive it objectively from the real Go scorer per recommended id,
        # exactly as the baseline arms do, so the A/B comparison judges the pick.
        _attach_classifications(recommendations, case_input.prompt, toolbox.world)
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=final.interpretedIntent,
            recommendations=recommendations,
            unresolved=final.unresolved,
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls,
                modelCalls=min(model_calls, toolbox.budget.max_model_calls),
                elapsedMs=0,
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model,
                toolTransport=transport,  # type: ignore[arg-type]
                jsonMode=True,
                notes=notes or None,
            ),
        )

    def _budget_error(
        self, exc: BudgetExceeded, toolbox: ToolBox, config: ModelConfig, transport: str
    ) -> AssemblyResult:  # pragma: no cover - live only
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=InterpretedIntent(notes="budget exceeded before finalize"),
            recommendations=[],
            unresolved=[],
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls,
                modelCalls=min(len(self.model_attempts), toolbox.budget.max_model_calls),
                elapsedMs=0,
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model,
                toolTransport=transport,  # type: ignore[arg-type]
                jsonMode=True,
            ),
            error=AssemblyError(code=BUDGET_EXCEEDED_CODE, message=exc.message),
        )

    def _model_error(
        self,
        toolbox: ToolBox,
        config: ModelConfig,
        transport: str,
        code: str = "STRUCTURED_OUTPUT_ERROR",
    ) -> AssemblyResult:  # pragma: no cover - live only
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=InterpretedIntent(notes="model failed before finalize"),
            recommendations=[],
            unresolved=[],
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls,
                modelCalls=min(len(self.model_attempts), toolbox.budget.max_model_calls),
                elapsedMs=0,
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model,
                toolTransport=transport,  # type: ignore[arg-type]
                jsonMode=True,
            ),
            error=AssemblyError(
                code=code,
                message="model execution failed before a final assembly result",
                detail="partial telemetry and tool trace retained",
            ),
        )

    def _init_error(self, toolbox: ToolBox) -> AssemblyResult:
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=InterpretedIntent(notes="model configuration unavailable"),
            recommendations=[],
            unresolved=[],
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(),
            provenance=Provenance(orchestrator=ORCHESTRATOR_ID, toolTransport="none"),
            error=AssemblyError(
                code="MODEL_CONFIG_ERROR",
                message="model configuration unavailable before execution",
            ),
        )

    def _unsupported_transport_error(self, toolbox: ToolBox) -> AssemblyResult:
        return AssemblyResult(
            arm=self.name,
            interpretedIntent=InterpretedIntent(notes="native transport unavailable"),
            recommendations=[],
            unresolved=[],
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(),
            provenance=Provenance(orchestrator=ORCHESTRATOR_ID, toolTransport="native"),
            error=AssemblyError(
                code="UNSUPPORTED_TRANSPORT",
                message="native transport is not enabled for this evaluation",
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
            self._emit(
                "lifecycle",
                "model_call",
                attempt=recorded.attempt,
                repair=recorded.repair,
                status=recorded.status,
            )

    def _emit(
        self,
        kind: str,
        phase: str,
        *,
        attempt: Optional[int] = None,
        repair: Optional[bool] = None,
        status: Optional[str] = None,
        tool: Optional[str] = None,
        result_count: Optional[int] = None,
    ) -> None:
        self.progress_events.append(
            ProgressEvent(
                sequence=len(self.progress_events) + 1,
                kind=kind,  # type: ignore[arg-type]
                phase=phase,  # type: ignore[arg-type]
                elapsedMs=int(round((time.monotonic() - self._started) * 1000)),
                attempt=attempt,
                repair=repair,
                status=status,  # type: ignore[arg-type]
                tool=tool,  # type: ignore[arg-type]
                resultCount=result_count,
            )
        )


def _attach_classifications(
    recommendations: list[Recommendation], prompt: str, world: FixtureWorld
) -> None:  # pragma: no cover - live only
    """Set each recommendation's classification from the real Go source-quality
    scorer (per-candidate, query-aware) so classification-based graders judge the
    picked candidate objectively rather than trusting the model's self-report. On
    any scorer failure the classification is left as the model returned it."""

    if not recommendations:
        return
    candidate_dicts = []
    for rec in recommendations:
        candidate = world.by_id(rec.candidateId)
        if candidate is not None:
            candidate_dicts.append(candidate.model_dump(exclude_none=True))
    if not candidate_dicts:
        return
    try:
        ranked = go_ranker.rank(prompt, candidate_dicts)
    except go_ranker.GoRankerError:
        return
    class_by_id: dict[str, str] = {}
    for candidate in ranked:
        quality = (candidate.get("metadata") or {}).get("sourceQuality") or {}
        classification = quality.get("classification")
        if classification:
            class_by_id[candidate["candidateId"]] = classification
    for rec in recommendations:
        derived = class_by_id.get(rec.candidateId)
        if derived:
            rec.classification = derived  # type: ignore[assignment]


def _coerce_recommendations(
    recommendations: list[Recommendation], limit: int
) -> list[Recommendation]:  # pragma: no cover - live only
    """Trim to the requested limit and force contiguous 1..N ranks. The validator
    still rejects ungrounded ids and duration warnings the model missed."""

    trimmed = recommendations[:limit]
    for index, rec in enumerate(trimmed, start=1):
        rec.rank = index
    return trimmed


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=False)
