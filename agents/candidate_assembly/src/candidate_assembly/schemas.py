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

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

# ---------------------------------------------------------------------------
# Versioned schema identifiers (mirrors the Go eval conventions).
# ---------------------------------------------------------------------------

ASSEMBLY_SCHEMA_VERSION = "omp.agent-search.assembly.v1"
CORPUS_SCHEMA_VERSION = "omp.agent-search.eval.corpus.v1"
RUN_SCHEMA_VERSION = "omp.agent-search.eval.run.v4"
PROGRESS_EVENT_SCHEMA_VERSION = "omp.agent-search.eval.progress.v2"
KNOWN_FAILURES_SCHEMA_VERSION = "omp.agent-search.eval.known-failures.v1"
WORKER_REQUEST_SCHEMA_VERSION = "omp.agent-search.worker.request.v1"
WORKER_REVISION_SCHEMA_VERSION = "omp.agent-search.worker.revision.v1"
WORKER_TERMINAL_SCHEMA_VERSION = "omp.agent-search.worker.terminal.v1"
PROMPT_REVISION = "agent-search-system-prompt-v2"

ALLOWED_PROVIDERS: frozenset[str] = frozenset({"youtube", "soundcloud"})
GATEWAY_EVIDENCE_MAX_BYTES = 4 * 1024

GatewayBackendErrorCode = Literal[
    "SERVICE_UNAUTHORIZED",
    "INVALID_JSON",
    "CAPABILITY_UNAVAILABLE",
    "CAPABILITY_RATE_LIMIT",
    "CAPABILITY_BUSY",
    "CAPABILITY_UNAUTHORIZED",
    "CAPABILITY_EXPIRED",
    "CAPABILITY_UNKNOWN",
    "CAPABILITY_CALL_LIMIT",
    "CAPABILITY_RESOURCE_LIMIT",
    "INVALID_REQUEST",
    "PROVIDER_BUSY",
    "CATALOG_UNAVAILABLE",
    "CANDIDATE_UNKNOWN",
    "EVIDENCE_UNKNOWN",
    "EVIDENCE_UNSAFE",
    "FIRECRAWL_DISABLED",
    "FIRECRAWL_BUSY",
    "FIRECRAWL_RATE_LIMIT",
    "FIRECRAWL_TIMEOUT",
    "FIRECRAWL_FAILED",
    "FIRECRAWL_REDIRECT",
    "FIRECRAWL_BAD_RESPONSE",
    "FIRECRAWL_RESPONSE_TOO_LARGE",
    "RESPONSE_TOO_LARGE",
]

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

ToolName = Literal[
    "search_sources",
    "search_catalog",
    "inspect_source_metadata",
    "extract_web",
]


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
    timeToBaselineMs: Optional[int] = Field(default=None, ge=0)
    timeToFirstValidatedResultMs: Optional[int] = Field(default=None, ge=0)
    timeToFirstUsefulValidatedResultMs: Optional[int] = Field(default=None, ge=0)
    timeToFinalMs: Optional[int] = Field(default=None, ge=0)
    terminalOutcome: Literal["completed", "failed", "cancelled"] = "completed"
    degradation: Literal["none", "arm_error", "validation_failed", "budget_exhausted"] = "none"
    fallback: Literal["none", "deterministic_baseline"] = "none"
    recovery: Literal["not_attempted"] = "not_attempted"
    budgetOutcome: Literal["within_budget", "exhausted"] = "within_budget"


_SAFE_REFERENCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_SECRET_SHAPED_RE = re.compile(r"(?i)(?:^sk-|bearer|api[_-]?key|token|secret)")
_URL_LIKE_RE = re.compile(r"(?i)(?:https?://|w{3}\.|mailto:|ftp://)")
_GATEWAY_SECRET_TEXT_RE = re.compile(
    r"(?i)(?:\b(?:authorization|bearer|api[_-]?key|secret|token|password)\b|\bsk-[A-Za-z0-9_-]+)"
)


def is_safe_progress_reference(value: str) -> bool:
    """Allow only bounded fixture-style IDs, never URLs, secrets, or free text."""

    return bool(
        _SAFE_REFERENCE_RE.fullmatch(value)
        and not _SECRET_SHAPED_RE.search(value)
        and "://" not in value
    )


def is_safe_gateway_text(value: str) -> bool:
    """Return whether text is safe to expose from the Go-owned gateway.

    Gateway results are the model-facing boundary. URLs and credential-shaped
    text are rejected here rather than relying on a downstream prompt rule.
    """

    return bool(
        value
        and not _URL_LIKE_RE.search(value)
        and not _GATEWAY_SECRET_TEXT_RE.search(value)
    )


def _validate_gateway_text(value: Optional[str]) -> Optional[str]:
    if value is not None and not is_safe_gateway_text(value):
        raise ValueError("unsafe gateway text")
    return value


class GatewayCandidate(StrictModel):
    """Sanitized, model-facing source candidate returned by the Go gateway.

    The fixture ``RawCandidate`` intentionally retains source URLs for the Go
    scorer. This model has no URL or arbitrary metadata fields by design.
    """

    candidateId: str = Field(min_length=1, max_length=128)
    provider: Literal["youtube", "soundcloud"]
    title: str = Field(min_length=1, max_length=240)
    downloadable: bool
    playable: bool = False
    sourceId: Optional[str] = Field(default=None, max_length=128)
    artist: Optional[str] = Field(default=None, max_length=180)
    uploader: Optional[str] = Field(default=None, max_length=180)
    durationMs: Optional[int] = Field(default=None, ge=0, le=86_400_000)
    explicit: Optional[bool] = None
    evidenceRefs: list[str] = Field(default_factory=list, max_length=24)

    @field_validator("candidateId", "sourceId")
    @classmethod
    def _opaque_ids(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not is_safe_progress_reference(value):
            raise ValueError("unsafe opaque id")
        return value

    @field_validator("title", "artist", "uploader")
    @classmethod
    def _safe_text(cls, value: Optional[str]) -> Optional[str]:
        return _validate_gateway_text(value)

    @field_validator("evidenceRefs")
    @classmethod
    def _safe_evidence_refs(cls, values: list[str]) -> list[str]:
        if not all(is_safe_progress_reference(value) for value in values):
            raise ValueError("unsafe evidence reference")
        return values


class GatewayWireCandidate(GatewayCandidate):
    """Strict Go wire candidate. ``metadata`` is validated then projected out."""

    metadata: dict[str, str] = Field(default_factory=dict, max_length=16)

    @field_validator("metadata")
    @classmethod
    def _safe_metadata(cls, value: dict[str, str]) -> dict[str, str]:
        if any(
            not is_safe_gateway_text(key) or not is_safe_gateway_text(item)
            for key, item in value.items()
        ):
            raise ValueError("unsafe gateway metadata")
        return value


class GatewayCatalogEntry(StrictModel):
    kind: Literal["track", "artist", "album"]
    id: str = Field(min_length=1, max_length=128)
    title: str = Field(min_length=1, max_length=240)
    artist: Optional[str] = Field(default=None, max_length=180)
    durationMs: Optional[int] = Field(default=None, ge=0, le=86_400_000)
    score: int = Field(default=0, ge=0, le=100)

    @field_validator("id")
    @classmethod
    def _opaque_id(cls, value: str) -> str:
        if not is_safe_progress_reference(value):
            raise ValueError("unsafe opaque id")
        return value

    @field_validator("title", "artist")
    @classmethod
    def _safe_text(cls, value: Optional[str]) -> Optional[str]:
        return _validate_gateway_text(value)


class GatewayWireCatalogEntry(StrictModel):
    """Strict Go ``SearchItem`` wire shape, projected to ``GatewayCatalogEntry``."""

    kind: Literal["track", "artist", "album"]
    id: Optional[str] = Field(default=None, max_length=128)
    title: str = Field(min_length=1, max_length=240)
    subtitle: Optional[str] = Field(default=None, max_length=240)
    artist: Optional[str] = Field(default=None, max_length=180)
    artistMbid: Optional[str] = Field(default=None, max_length=128)
    album: Optional[str] = Field(default=None, max_length=240)
    albumMbid: Optional[str] = Field(default=None, max_length=128)
    durationMs: Optional[int] = Field(default=None, ge=0, le=86_400_000)
    releaseDate: Optional[str] = Field(default=None, max_length=32)
    score: int = Field(default=0, ge=0, le=100)

    @field_validator("id", "artistMbid", "albumMbid")
    @classmethod
    def _opaque_ids(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not is_safe_progress_reference(value):
            raise ValueError("unsafe opaque id")
        return value

    @field_validator("title", "subtitle", "artist", "album", "releaseDate")
    @classmethod
    def _safe_text(cls, value: Optional[str]) -> Optional[str]:
        return _validate_gateway_text(value)


class GatewayMetadata(StrictModel):
    candidateId: str = Field(min_length=1, max_length=128)
    description: Optional[str] = Field(default=None, max_length=1_000)
    channel: Optional[str] = Field(default=None, max_length=180)
    channelVerified: Optional[bool] = None
    uploadDate: Optional[str] = Field(default=None, max_length=32)
    tags: list[str] = Field(default_factory=list, max_length=24)
    evidenceRefs: list[str] = Field(default_factory=list, max_length=24)
    attributes: list["GatewayMetadataAttribute"] = Field(
        default_factory=list, max_length=16
    )

    @field_validator("candidateId", "evidenceRefs")
    @classmethod
    def _opaque_values(cls, value):
        values = value if isinstance(value, list) else [value]
        if not all(
            isinstance(item, str) and is_safe_progress_reference(item)
            for item in values
        ):
            raise ValueError("unsafe opaque id")
        return value

    @field_validator("description", "channel", "uploadDate", "tags")
    @classmethod
    def _safe_text(cls, value):
        values = value if isinstance(value, list) else [value]
        if any(
            item is not None
            and (not isinstance(item, str) or not is_safe_gateway_text(item))
            for item in values
        ):
            raise ValueError("unsafe gateway text")
        return value


class GatewayMetadataAttribute(StrictModel):
    key: str = Field(min_length=1, max_length=64)
    value: str = Field(min_length=1, max_length=512)

    @field_validator("key", "value")
    @classmethod
    def _safe_text(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


class GatewayEvidence(StrictModel):
    evidenceRef: str = Field(min_length=1, max_length=128)
    title: Optional[str] = Field(default=None, max_length=240)
    text: str = Field(min_length=1, max_length=GATEWAY_EVIDENCE_MAX_BYTES)

    @field_validator("evidenceRef")
    @classmethod
    def _opaque_ref(cls, value: str) -> str:
        if not is_safe_progress_reference(value):
            raise ValueError("unsafe evidence reference")
        return value

    @field_validator("title")
    @classmethod
    def _safe_title(cls, value: Optional[str]) -> Optional[str]:
        return _validate_gateway_text(value)

    @field_validator("text")
    @classmethod
    def _safe_evidence(cls, value: str) -> str:
        if len(value.encode("utf-8")) > GATEWAY_EVIDENCE_MAX_BYTES:
            raise ValueError("gateway evidence exceeded byte limit")
        validated = _validate_gateway_text(value)
        assert validated is not None
        return validated


class GatewayCapabilityResponse(StrictModel):
    capability: str = Field(min_length=1, max_length=512, repr=False)
    expiresAt: str = Field(min_length=1, max_length=64)
    maxCalls: int = Field(ge=1, le=1000)


class GatewayBackendError(StrictModel):
    code: GatewayBackendErrorCode
    message: str = Field(min_length=1, max_length=1_024)


class GatewayErrorEnvelope(StrictModel):
    error: GatewayBackendError


class GatewayProviderError(StrictModel):
    code: str = Field(min_length=1, max_length=64)
    message: str = Field(min_length=1, max_length=240)

    @field_validator("code", "message")
    @classmethod
    def _safe_text(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


class GatewayProviderSummary(StrictModel):
    provider: str = Field(min_length=1, max_length=32)
    status: str = Field(min_length=1, max_length=64)
    resultCount: int = Field(ge=0, le=25)
    elapsedMs: int = Field(ge=0, le=300_000)
    error: Optional[GatewayProviderError] = None

    @field_validator("provider", "status")
    @classmethod
    def _safe_text(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


class GatewaySearchSourcesWireResponse(StrictModel):
    query: str = Field(min_length=1, max_length=512)
    candidates: list[GatewayWireCandidate] = Field(default_factory=list, max_length=12)
    providers: list[GatewayProviderSummary] = Field(default_factory=list, max_length=2)

    @field_validator("query")
    @classmethod
    def _safe_query(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


class GatewaySearchCatalogWireResponse(StrictModel):
    query: str = Field(min_length=1, max_length=512)
    kind: Literal["track", "artist", "album"]
    items: list[GatewayWireCatalogEntry] = Field(default_factory=list, max_length=8)

    @field_validator("query")
    @classmethod
    def _safe_query(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


class GatewayEvidenceWireResponse(StrictModel):
    evidenceRef: str = Field(min_length=1, max_length=128)
    markdown: str = Field(min_length=1, max_length=GATEWAY_EVIDENCE_MAX_BYTES)

    @field_validator("evidenceRef")
    @classmethod
    def _safe_ref(cls, value: str) -> str:
        if not is_safe_progress_reference(value):
            raise ValueError("unsafe evidence reference")
        return value

    @field_validator("markdown")
    @classmethod
    def _safe_markdown(cls, value: str) -> str:
        if len(value.encode("utf-8")) > GATEWAY_EVIDENCE_MAX_BYTES:
            raise ValueError("gateway evidence exceeded byte limit")
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe gateway text")
        return value


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
    emitted by the current model arms.
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
    status: Optional[
        Literal["success", "parse_error", "transport_error", "passed", "failed"]
    ] = None
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

    @model_validator(mode="after")
    def _valid_event_shape(self) -> "ProgressEvent":
        allowed_phases = {
            "baseline": {"baseline_validated", "failed"},
            "lifecycle": {"started", "model_call", "finalizing", "failed"},
            "tool": {"tool_completed"},
            "validated_result": {"validated"},
        }
        if self.phase not in allowed_phases[self.kind]:
            raise ValueError(f"phase {self.phase!r} is invalid for kind {self.kind!r}")

        if self.phase != "model_call" and (
            self.attempt is not None or self.repair is not None
        ):
            raise ValueError("attempt and repair are only valid for model_call events")
        if self.phase != "tool_completed" and self.tool is not None:
            raise ValueError("tool is only valid for tool_completed events")
        if self.kind not in {"tool", "baseline", "validated_result"}:
            if self.resultCount is not None:
                raise ValueError("resultCount is invalid for this event kind")
        if self.kind not in {"baseline", "validated_result"} and (
            self.candidateIds or self.evidenceRefs
        ):
            raise ValueError(
                "candidateIds and evidenceRefs are only valid for result events"
            )

        if self.kind == "lifecycle":
            if self.phase == "started" and self.status is not None:
                raise ValueError("started events forbid status")
            if self.phase == "model_call":
                if self.attempt is None or self.status is None:
                    raise ValueError("model_call requires attempt and status")
                if self.status not in {"success", "parse_error", "transport_error"}:
                    raise ValueError("model_call has an invalid status")
            if self.phase == "finalizing" and self.status != "success":
                raise ValueError("finalizing requires success status")
            if self.phase == "failed" and self.status != "failed":
                raise ValueError("failed lifecycle events require failed status")
            return self

        if self.kind == "tool":
            if self.tool is None or self.resultCount is None:
                raise ValueError("tool_completed requires tool and resultCount")
            if self.status is not None:
                raise ValueError("tool_completed forbids status")
            return self

        if self.resultCount is None or self.status is None:
            raise ValueError(f"{self.kind} requires status and resultCount")
        if self.kind == "baseline":
            expected_status = (
                "passed" if self.phase == "baseline_validated" else "failed"
            )
            if self.status != expected_status:
                raise ValueError(f"{self.phase} requires {expected_status} status")
        elif self.status not in {"passed", "failed"}:
            raise ValueError("validated_result requires passed or failed status")
        if self.status == "failed" and (self.candidateIds or self.evidenceRefs):
            raise ValueError("failed result events forbid candidate and evidence refs")
        return self


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
# Durable worker protocol. The Go runner owns request construction; this
# process receives only bounded, URL-free snapshot projections.
# ---------------------------------------------------------------------------


class WorkerSourceQuality(StrictModel):
    score: int = Field(ge=0, le=100)
    classification: Classification
    warnings: list[Warning] = Field(default_factory=list, max_length=12)


class WorkerCandidate(GatewayCandidate):
    """Server-owned candidate projection for the production JSONL worker."""

    sourceQuality: WorkerSourceQuality


class WorkerBudgets(StrictModel):
    maxToolCalls: int = Field(ge=1, le=32)
    maxModelCalls: int = Field(ge=1, le=12)
    recursionLimit: int = Field(ge=2, le=16)
    maxCandidatesIn: int = Field(ge=1, le=64)
    maxRecommendations: int = Field(ge=1, le=10)
    wallClockMs: int = Field(ge=1_000, le=300_000)
    maxRequestBytes: int = Field(ge=1_024, le=64 * 1024)
    maxResponseBytes: int = Field(ge=1_024, le=128 * 1024)
    maxTokensPerCompletion: int = Field(ge=64, le=8_192)


class WorkerStages(StrictModel):
    directJudge: bool
    deepAgent: bool

    @model_validator(mode="after")
    def _at_least_one_stage(self) -> "WorkerStages":
        if not self.directJudge and not self.deepAgent:
            raise ValueError("at least one worker stage must be enabled")
        return self


class WorkerRequest(StrictModel):
    schemaVersion: Literal["omp.agent-search.worker.request.v1"] = (
        WORKER_REQUEST_SCHEMA_VERSION
    )
    jobId: str = Field(min_length=1, max_length=128)
    runId: str = Field(min_length=1, max_length=128)
    query: str = Field(min_length=1, max_length=512)
    limit: int = Field(ge=1, le=10)
    candidates: list[WorkerCandidate] = Field(min_length=1, max_length=64)
    catalog: list[GatewayCatalogEntry] = Field(default_factory=list, max_length=16)
    metadata: dict[str, GatewayMetadata] = Field(default_factory=dict, max_length=64)
    budgets: WorkerBudgets
    stages: WorkerStages

    @field_validator("jobId", "runId")
    @classmethod
    def _safe_ids(cls, value: str) -> str:
        if not is_safe_progress_reference(value):
            raise ValueError("unsafe worker id")
        return value

    @field_validator("query")
    @classmethod
    def _safe_query(cls, value: str) -> str:
        if not is_safe_gateway_text(value):
            raise ValueError("unsafe worker query")
        return value

    @model_validator(mode="after")
    def _consistent_snapshot(self) -> "WorkerRequest":
        candidate_ids = [candidate.candidateId for candidate in self.candidates]
        if len(candidate_ids) != len(set(candidate_ids)):
            raise ValueError("candidate ids must be unique")
        if self.limit > self.budgets.maxRecommendations:
            raise ValueError("limit exceeds maxRecommendations")
        if len(self.candidates) > self.budgets.maxCandidatesIn:
            raise ValueError("candidate count exceeds maxCandidatesIn")
        for key, metadata in self.metadata.items():
            if key not in candidate_ids or metadata.candidateId != key:
                raise ValueError("metadata must be keyed by an input candidate id")
        return self


class WorkerStageTiming(StrictModel):
    latencyMs: int = Field(ge=0)
    toolCalls: int = Field(ge=0)
    modelAttempts: list[ModelCallAttempt] = Field(default_factory=list, max_length=12)


class WorkerRevision(StrictModel):
    schemaVersion: Literal["omp.agent-search.worker.revision.v1"] = (
        WORKER_REVISION_SCHEMA_VERSION
    )
    recordType: Literal["revision"] = "revision"
    jobId: str
    runId: str
    stage: Literal["direct_judge", "deep_agent"]
    result: AssemblyResult
    timing: WorkerStageTiming


class WorkerModelAttempt(StrictModel):
    stage: Literal["direct_judge", "deep_agent"]
    attempt: int = Field(ge=1)
    durationMs: int = Field(ge=0)
    repair: bool = False
    status: Literal["success", "parse_error", "transport_error"]


class WorkerTiming(StrictModel):
    # Present only once the complete stdin record has passed strict validation.
    processStartupToRequestAcceptedMs: Optional[int] = Field(default=None, ge=0)
    requestAcceptedToDirectFirstRevisionMs: Optional[int] = Field(default=None, ge=0)
    requestAcceptedToFinalMs: Optional[int] = Field(default=None, ge=0)
    toolCalls: int = Field(ge=0)
    modelAttempts: list[WorkerModelAttempt] = Field(default_factory=list, max_length=24)


class WorkerDegradation(StrictModel):
    stage: Literal["direct_judge", "deep_agent", "protocol"]
    code: Literal[
        "MODEL_DISABLED",
        "MODEL_UNAVAILABLE",
        "MODEL_CONFIG_ERROR",
        "MODEL_FAILURE",
        "STRUCTURED_OUTPUT_ERROR",
        "VALIDATION_FAILED",
        "BUDGET_EXCEEDED",
        "CANCELLED",
        "INVALID_REQUEST",
    ]


class WorkerTerminal(StrictModel):
    schemaVersion: Literal["omp.agent-search.worker.terminal.v1"] = (
        WORKER_TERMINAL_SCHEMA_VERSION
    )
    recordType: Literal["terminal"] = "terminal"
    jobId: Optional[str] = Field(default=None, max_length=128)
    runId: Optional[str] = Field(default=None, max_length=128)
    outcome: Literal["completed", "degraded", "unavailable", "invalid_request", "cancelled"]
    revisionsEmitted: int = Field(ge=0, le=2)
    degradations: list[WorkerDegradation] = Field(default_factory=list, max_length=2)
    timing: WorkerTiming


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
