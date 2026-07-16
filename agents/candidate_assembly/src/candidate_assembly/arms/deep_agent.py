"""The prototype under evaluation: a bounded DeepAgents / LangGraph tool loop.

Per the Finn-Nancy spike, the built-in DeepAgents planning + filesystem loop is
non-terminating, so this arm drives ONLY our three read-only tools and enforces
the same budgets as every other arm through the shared ``ToolBox``. Native
tool-calling on the llama-swap endpoint is unverified, so the default transport
is a structured-action loop (each step the model emits an ``AgentAction`` via
json_schema and the runner executes the tool); a ``native`` transport is
attempted when the probe reports tool-call support. Either way the orchestrator
interface hides the transport and records which one was used.

The langchain / deepagents stack is imported lazily; this arm only runs live.
"""

from __future__ import annotations

import json
import os
from typing import Any, Optional

from .. import go_ranker
from ..budgets import BUDGET_EXCEEDED_CODE, Budget, BudgetExceeded
from ..fixture_tools import ToolBox, ToolError
from ..model_client import (
    ModelConfig,
    build_chat_model,
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
    Recommendation,
)

ORCHESTRATOR_ID = "deepagents-0.6.12"

_SYSTEM_PROMPT = (
    "You are OMP's candidate-assembly agent for natural-language song search. "
    "You assemble a sorted, structured list of source candidates by CALLING TOOLS; "
    "you never download, play, or verify anything on the open web. Available "
    "tools: search_sources(query, providers, limit), search_catalog(query, kind, "
    "limit), inspect_source_metadata(candidate_id).\n"
    "Process: issue one or two query variants; dedupe; compare each candidate's "
    "duration against the catalog track duration; prefer official audio and "
    "topic-channel uploads when the user wants audio; avoid music videos, live "
    "versions, covers, remixes, and sped-up/slowed edits unless the user asked "
    "for them; honor any requested platform. Call ONE tool per turn. When you "
    "have enough evidence, FINALIZE with the structured assembly result: an "
    "interpreted intent, a ranked recommendation list (contiguous ranks from 1, "
    "each with a candidateId that a tool returned, a confidence in [0,1], a short "
    "rationale with no URLs, and warnings), and any unresolved notes. Only "
    "recommend candidate ids that a tool actually returned."
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
    "validating against the schema above."
)


def _finalize_messages(prior: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Build the finalize-step message list from the running action-loop convo.

    Pins the AgentFinalOutput schema as the system turn (dropping the original
    system turn, which advertised the AgentAction schema and would keep priming
    action-shaped output), preserves the gathered tool observations, and appends
    the explicit anti-action finalize instruction. Pure — unit-tested without a
    network.
    """

    final_system = _SYSTEM_PROMPT + "\n\n" + schema_prompt(AgentFinalOutput)
    return [
        {"role": "system", "content": final_system},
        *prior[1:],
        {"role": "user", "content": _FINALIZE_INSTRUCTION},
    ]


class DeepAgentArm:
    name = "deep_agent"

    def assemble(
        self, case_input: CaseInput, world: FixtureWorld, budget: Budget
    ) -> AssemblyResult:
        config = ModelConfig.from_env()
        toolbox = ToolBox(world, budget)
        # Expose the tool-returned id allowlist for the grounding validator.
        self.allowlist = toolbox.allowlist
        transport = os.environ.get("AGENT_SEARCH_TOOL_TRANSPORT", "structured_action").strip()

        try:
            if transport == "native":
                final, model_calls, notes = self._run_native(case_input, toolbox, config, budget)
            else:
                transport = "structured_action"
                final, model_calls, notes = self._run_structured_action(
                    case_input, toolbox, config, budget
                )
        except BudgetExceeded as exc:
            return self._budget_error(exc, toolbox, config, transport)

        return self._finalize(
            final, case_input, toolbox, config, transport, model_calls, notes
        )

    # -- transports -------------------------------------------------------

    def _run_structured_action(
        self, case_input: CaseInput, toolbox: ToolBox, config: ModelConfig, budget: Budget
    ) -> tuple[AgentFinalOutput, int, list[str]]:  # pragma: no cover - live only
        # json_object transport: the endpoint honors response_format json_object
        # (not json_schema) and has no native tool-calling, so each step the model
        # emits an AgentAction JSON object, the runner executes the tool, and the
        # observation is appended. complete_structured does one bounded repair retry
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
        # Reserve at least one model call for the finalize step.
        while model_calls < budget.max_model_calls - 1:
            step = complete_structured(chat, messages, AgentAction)
            model_calls += step.calls_used
            notes.extend(step.provenance_notes)
            action: AgentAction = step.value
            if action.action == "finalize":
                break
            observation = self._dispatch(toolbox, action)
            messages.append({"role": "assistant", "content": _json(action.model_dump())})
            messages.append({"role": "user", "content": _json({"observation": observation})})

        final_messages = _finalize_messages(messages)
        final_step = complete_structured(chat, final_messages, AgentFinalOutput)
        model_calls += final_step.calls_used
        notes.extend(final_step.provenance_notes)
        return final_step.value, model_calls, notes

    def _run_native(
        self, case_input: CaseInput, toolbox: ToolBox, config: ModelConfig, budget: Budget
    ) -> tuple[AgentFinalOutput, int, list[str]]:  # pragma: no cover - live only
        # Native path: drive deepagents with ONLY our custom tools (no built-in
        # planning/filesystem loop) and a bounded recursion limit. Selected only if
        # a caller forces AGENT_SEARCH_TOOL_TRANSPORT=native; the probe reports the
        # endpoint has no native tool-calling, so this stays off by default. The
        # final assembly output still uses the json_object transport.
        from deepagents import create_deep_agent  # type: ignore

        model = build_chat_model(config, budget.max_tokens_per_completion)
        tools = _native_tools(toolbox)
        agent = create_deep_agent(
            tools=tools,
            model=model,
            instructions=_SYSTEM_PROMPT,
            builtin_tools=[],
        )
        result = agent.invoke(
            {"messages": [{"role": "user", "content": case_input.prompt}]},
            config={"recursion_limit": budget.recursion_limit},
        )
        transcript = _last_text(result)
        client = build_openai_client(config)
        chat = make_json_object_chat(client, config, budget.max_tokens_per_completion)
        final_system = _SYSTEM_PROMPT + "\n\n" + schema_prompt(AgentFinalOutput)
        final_step = complete_structured(
            chat,
            [
                {"role": "system", "content": final_system},
                {"role": "user", "content": transcript or case_input.prompt},
                {"role": "user", "content": _FINALIZE_INSTRUCTION},
            ],
            AgentFinalOutput,
        )
        model_calls = max(1, len(tools)) + final_step.calls_used  # best-effort; runner also caps
        return final_step.value, model_calls, final_step.provenance_notes

    # -- tool dispatch ----------------------------------------------------

    def _dispatch(self, toolbox: ToolBox, action: AgentAction) -> Any:  # pragma: no cover - live only
        args = action.args or {}
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
                modelCalls=model_calls,
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
            budgetSpent=BudgetSpent(toolCalls=toolbox.tool_calls, modelCalls=0, elapsedMs=0),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID,
                model=config.model,
                toolTransport=transport,  # type: ignore[arg-type]
                jsonMode=True,
            ),
            error=AssemblyError(code=BUDGET_EXCEEDED_CODE, message=exc.message),
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


def _native_tools(toolbox: ToolBox):  # pragma: no cover - live only
    from langchain_core.tools import StructuredTool  # type: ignore

    def search_sources(query: str, providers: Optional[list[str]] = None, limit: int = 10):
        return [r.model_dump(exclude_none=True) for r in toolbox.search_sources(query, providers, limit)]

    def search_catalog(query: str, kind: str = "track", limit: int = 8):
        return [r.model_dump(exclude_none=True) for r in toolbox.search_catalog(query, kind, limit)]

    def inspect_source_metadata(candidate_id: str):
        return toolbox.inspect_source_metadata(candidate_id).model_dump(exclude_none=True)

    return [
        StructuredTool.from_function(search_sources),
        StructuredTool.from_function(search_catalog),
        StructuredTool.from_function(inspect_source_metadata),
    ]


def _last_text(result: Any) -> Optional[str]:  # pragma: no cover - live only
    messages = result.get("messages") if isinstance(result, dict) else None
    if not messages:
        return None
    last = messages[-1]
    return getattr(last, "content", None) or (last.get("content") if isinstance(last, dict) else None)


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=False)
