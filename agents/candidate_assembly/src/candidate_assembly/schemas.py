"""Pydantic v2 schemas — the single source of truth for the candidate-assembly
prototype.

The wire models use camelCase field names so they line up byte-for-byte with the
Go ``discovery.Candidate`` JSON shape and with the recorded artifact fixtures.
Every model is strict (``extra="forbid"``) so an off-schema model completion, a
malformed pool, or a drifted recording fails loudly instead of silently losing a
field.
"""

from __future__ import annotations

import re
from typing import Any, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

# ---------------------------------------------------------------------------
# Versioned schema identifiers (mirrors the Go eval conventions).
# ---------------------------------------------------------------------------

ASSEMBLY_SCHEMA_VERSION = "omp.agent-search.assembly.v1"
CORPUS_SCHEMA_VERSION = "omp.agent-search.eval.corpus.v1"
RUN_SCHEMA_VERSION = "omp.agent-search.eval.run.v3"
PROGRESS_EVENT_SCHEMA_VERSION = "omp.agent-search.eval.progress.v2"
KNOWN_FAILURES_SCHEMA_VERSION = "omp.agent-search.eval.known-failures.v1"
PROMPT_REVISION = "agent-search-system-prompt-v2"

ALLOWED_PROVIDERS: frozenset[str] = frozenset({"youtube", "soundcloud"})

# Source-quality classification vocabulary, reused verbatim from the Go
# discovery.source_quality constants so the Python side never invents a new
# taxonomy.
Classification = Literal[
    "official_audio",
    "topic_audio",
    "artist_upload",
    "music_video",
    "visualizer",
    "live",
    "lyric_video",
    "interview",
    "cover",
    "remix",
    "altered_audio",
    "direct_url",
    "unknown",
]

# Per-candidate warning enum. duration_mismatch/short_version/platform_mismatch
# are assembly-layer signals; the rest map from source-quality classifications.
Warning = Literal[
    "duration_mismatch",
    "music_video",
    "short_version",
    "live",
    "remix",
    "altered_audio",
    "platform_mismatch",
    "cover",
    "lyric_video",
    "interview",
    "visualizer",
    "not_downloadable",
]

ToolName = Literal["search_sources", "search_catalog", "inspect_source_metadata"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


# ---------------------------------------------------------------------------
# Tool I/O + fixture world models.
# ---------------------------------------------------------------------------


class RawCandidate(StrictModel):
    """Mirror of the Go ``discovery.Candidate`` JSON contract. Fixture pools use
    this exact shape so the ``sourcequality-rank`` Go CLI consumes them
    unmodified."""

    candidateId: str
    provider: str
    sourceUrl: str
    title: str
    downloadable: bool
    playable: bool = False
    sourceId: Optional[str] = None
    artist: Optional[str] = None
    uploader: Optional[str] = None
    durationMs: Optional[int] = None
    thumbnailUrl: Optional[str] = None
    explicit: Optional[bool] = None
    metadata: Optional[dict[str, Any]] = None


class CatalogEntry(StrictModel):
    kind: Literal["track", "artist", "album"]
    id: str
    title: str
    artist: Optional[str] = None
    durationMs: Optional[int] = None
    score: int = 0


class RichMetadata(StrictModel):
    """Returned by ``inspect_source_metadata`` — the deeper, per-candidate
    signals an agent inspects before committing to a recommendation."""

    candidateId: str
    description: Optional[str] = None
    channel: Optional[str] = None
    channelVerified: Optional[bool] = None
    uploadDate: Optional[str] = None
    tags: list[str] = Field(default_factory=list)


class FixtureWorld(StrictModel):
    """The per-case candidate/catalog/metadata world the read-only tools close
    over. Loaded from ``fixtures/pools/<case-id>.json``."""

    candidates: list[RawCandidate]
    catalog: list[CatalogEntry] = Field(default_factory=list)
    metadata: dict[str, RichMetadata] = Field(default_factory=dict)

    def by_id(self, candidate_id: str) -> Optional[RawCandidate]:
        for candidate in self.candidates:
            if candidate.candidateId == candidate_id:
                return candidate
        return None

    def candidate_ids(self) -> set[str]:
        return {candidate.candidateId for candidate in self.candidates}


# ---------------------------------------------------------------------------
# Assembly result contract (what every arm returns).
# ---------------------------------------------------------------------------


class Evidence(StrictModel):
    tool: ToolName
    ref: str


class Recommendation(StrictModel):
    candidateId: str
    rank: int = Field(ge=1)
    confidence: float = Field(ge=0.0, le=1.0)
    rationale: str = Field(max_length=240)
    classification: Optional[Classification] = None
    evidence: list[Evidence] = Field(default_factory=list)
    warnings: list[Warning] = Field(default_factory=list)


class InterpretedIntent(StrictModel):
    searchQueries: list[str] = Field(default_factory=list)
    platformPreference: list[str] = Field(default_factory=list)
    desiredKinds: list[str] = Field(default_factory=list)
    durationTargetMs: Optional[int] = None
    notes: str = Field(default="", max_length=200)


class TraceStep(StrictModel):
    step: int
    tool: str
    argsDigest: str
    resultCount: int
    elapsedMs: int


class BudgetSpent(StrictModel):
    toolCalls: int = 0
    modelCalls: int = 0
    elapsedMs: int = 0


# These models belong to the eval-run artifact, not AssemblyResult. They are
# runner-owned so a model is never asked to emit timing, progress, or error
# accounting data that it could fabricate or contaminate with reasoning text.
class ModelCallAttempt(StrictModel):
    attempt: int = Field(ge=1)
    durationMs: int = Field(ge=0)
    repair: bool = False
    status: Literal["success", "parse_error", "transport_error"]


class ArmTelemetry(StrictModel):
    startupProbeMs: Optional[int] = Field(default=None, ge=0)
    modelAttempts: list[ModelCallAttempt] = Field(default_factory=list)
    # Measures dispatch execution only. TraceStep.elapsedMs is cumulative and
    # intentionally not used for model-vs-tool attribution.
    toolDispatchLatencyMs: int = Field(default=0, ge=0)
    finalizationMs: Optional[int] = Field(default=None, ge=0)
    validationMs: Optional[int] = Field(default=None, ge=0)
    totalArmWallMs: int = Field(default=0, ge=0)
    firstPartialRevisionMs: Optional[int] = Field(default=None, ge=0)
    timeToFirstUsefulValidatedResultMs: Optional[int] = Field(default=None, ge=0)


_SAFE_REFERENCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_SECRET_SHAPED_RE = re.compile(r"(?i)(?:^sk-|bearer|api[_-]?key|token|secret)")


def is_safe_progress_reference(value: str) -> bool:
    """Allow only bounded fixture-style IDs, never URLs, secrets, or free text."""

    return bool(
        _SAFE_REFERENCE_RE.fullmatch(value)
        and not _SECRET_SHAPED_RE.search(value)
        and "://" not in value
    )


class SafeEvidenceRef(StrictModel):
    tool: ToolName
    # Candidate and catalog ids are stable fixture references. URLs, arbitrary
    # model text, and prompts are not valid progress payloads.
    ref: str = Field(min_length=1, max_length=128)

    @field_validator("ref")
    @classmethod
    def _safe_ref(cls, value: str) -> str:
        if not is_safe_progress_reference(value):
            raise ValueError("unsafe evidence reference")
        return value


class DeterministicBaseline(StrictModel):
    elapsedMs: int = Field(ge=0)
    validationMs: int = Field(ge=0)
    candidateIds: list[str] = Field(default_factory=list, max_length=25)
    evidenceRefs: list[SafeEvidenceRef] = Field(default_factory=list, max_length=50)

    @field_validator("candidateIds")
    @classmethod
    def _safe_candidate_ids(cls, values: list[str]) -> list[str]:
        if not all(is_safe_progress_reference(value) for value in values):
            raise ValueError("unsafe candidate id")
        return values


class ProgressEvent(StrictModel):
    """Safe, ordered metadata for a future asynchronous eval progress stream.

    The contract intentionally has no free-form text, prompt, URL, token, or
    provider fields. Only lifecycle, tool, and validated-result metadata may be
    emitted by the current deep-agent arm.
    """

    schemaVersion: Literal["omp.agent-search.eval.progress.v2"] = (
        PROGRESS_EVENT_SCHEMA_VERSION
    )
    sequence: int = Field(ge=1)
    kind: Literal["baseline", "lifecycle", "tool", "validated_result"]
    phase: Literal[
        "started",
        "model_call",
        "tool_completed",
        "finalizing",
        "failed",
        "baseline_validated",
        "validated",
    ]
    elapsedMs: int = Field(ge=0)
    attempt: Optional[int] = Field(default=None, ge=1)
    repair: Optional[bool] = None
    status: Optional[Literal["success", "parse_error", "transport_error", "passed", "failed"]] = None
    tool: Optional[ToolName] = None
    resultCount: Optional[int] = Field(default=None, ge=0)
    candidateIds: list[str] = Field(default_factory=list, max_length=25)
    evidenceRefs: list[SafeEvidenceRef] = Field(default_factory=list, max_length=50)

    @field_validator("candidateIds")
    @classmethod
    def _safe_candidate_ids(cls, values: list[str]) -> list[str]:
        if not all(is_safe_progress_reference(value) for value in values):
            raise ValueError("unsafe candidate id")
        return values


class Provenance(StrictModel):
    orchestrator: str
    model: str = ""
    toolTransport: Literal["native", "structured_action", "none"] = "none"
    # True when the arm drove the endpoint with response_format json_object (the
    # only enforcement the endpoint honors). Left unset (None, dropped from the
    # artifact) for the model-free deterministic arm.
    jsonMode: Optional[bool] = None
    # Provenance notes from defensive parsing, e.g. "coerced_envelope" when a bare
    # judgments array was wrapped before validation. None when there is nothing to
    # note, so model-free recordings stay byte-stable.
    notes: Optional[list[str]] = None


class AssemblyError(StrictModel):
    code: str
    message: str
    detail: Optional[str] = None


class AssemblyResult(StrictModel):
    """The contract every arm returns and every grader consumes."""

    schemaVersion: Literal["omp.agent-search.assembly.v1"] = ASSEMBLY_SCHEMA_VERSION
    arm: str
    interpretedIntent: InterpretedIntent
    recommendations: list[Recommendation] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)
    trace: list[TraceStep] = Field(default_factory=list)
    budgetSpent: BudgetSpent
    provenance: Provenance
    error: Optional[AssemblyError] = None


class AgentFinalOutput(StrictModel):
    """The subset schema a model arm emits via structured output. The runner owns
    trace/budgetSpent/provenance, so the model is never asked to fabricate
    them."""

    interpretedIntent: InterpretedIntent
    recommendations: list[Recommendation] = Field(default_factory=list)
    unresolved: list[str] = Field(default_factory=list)


class AgentAction(StrictModel):
    """Structured-action transport step selected explicitly for the live arm."""

    action: Literal[
        "search_sources", "search_catalog", "inspect_source_metadata", "finalize"
    ]
    args: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Orchestrator input.
# ---------------------------------------------------------------------------


class CaseInput(StrictModel):
    prompt: str
    limit: int = Field(default=5, ge=1, le=25)


# ---------------------------------------------------------------------------
# Corpus models (mirrors the Go eval corpus envelope conventions).
# ---------------------------------------------------------------------------


class ForbiddenInTopK(StrictModel):
    k: int = Field(ge=1)
    candidateIds: list[str] = Field(default_factory=list)
    classifications: list[str] = Field(default_factory=list)


class Expectations(StrictModel):
    topCandidateId: Optional[str] = None
    topClassificationAnyOf: list[str] = Field(default_factory=list)
    forbiddenInTopK: Optional[ForbiddenInTopK] = None
    requiredWarnings: dict[str, list[str]] = Field(default_factory=dict)
    platform: list[str] = Field(default_factory=list)
    minRecommendations: Optional[int] = None
    maxRecommendations: Optional[int] = None
    minUnresolved: Optional[int] = None


class Case(StrictModel):
    id: str
    prompt: str
    poolRef: str
    expected: Expectations


class Corpus(StrictModel):
    schemaVersion: Literal["omp.agent-search.eval.corpus.v1"] = CORPUS_SCHEMA_VERSION
    promptRevision: str
    cases: list[Case]


# ---------------------------------------------------------------------------
# Pinned known-failures manifest (replay-only gate input).
# ---------------------------------------------------------------------------


class KnownFailure(StrictModel):
    """One pinned, intended grader failure: a (caseId, arm) whose recording is
    expected to fail exactly ``graders``. ``reason`` documents why the failure is
    a visible prototype finding rather than a regression to fix."""

    caseId: str
    arm: str
    graders: list[str] = Field(default_factory=list)
    reason: str = ""


class KnownFailuresManifest(StrictModel):
    """Versioned envelope pinning the exact set of intended replay failures so the
    CI gate stays green AND meaningful — failures are pinned, not hidden."""

    schemaVersion: Literal["omp.agent-search.eval.known-failures.v1"] = (
        KNOWN_FAILURES_SCHEMA_VERSION
    )
    entries: list[KnownFailure] = Field(default_factory=list)
