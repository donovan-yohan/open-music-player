"""Fixture-backed, read-only tools plus deterministic retrieval.

A live agent invents query variants that never exactly match a fixture key, so
the tools rank the case pool by normalized weighted token overlap and return the
top matches. Retrieval is a pure function of ``(query, pool)`` — no RNG, no wall
clock — so it is directly unit-testable and reproducible.

The ``ToolBox`` closes over one ``FixtureWorld`` and one ``Budget``. It is the
single enforcement point: every call increments the tool-call counter, checks the
wall clock, clamps the per-call ``limit``, caps request/response bytes, appends a
trace step, and records the returned candidate ids into the grounding allowlist.
"""

from __future__ import annotations

import hashlib
import json
import time
import unicodedata
from typing import Callable, Optional

from .budgets import (
    BUDGET_EXCEEDED_CODE,
    MAX_LIMIT_PER_CALL,
    Budget,
    BudgetExceeded,
)
from .schemas import (
    CatalogEntry,
    FixtureWorld,
    GatewayEvidence,
    RawCandidate,
    RichMetadata,
    TraceStep,
)

# A candidate must clear this normalized-overlap score to be retrieved. It is low
# on purpose: on-topic decoys (reactions, interviews, 8D edits) should survive
# retrieval so the ranker has to reject them, while wholly unrelated rows drop.
RETRIEVAL_MIN_SCORE = 0.05

# Field weights: a query token matching in the title is worth more than the same
# token appearing only in metadata text.
_TITLE_WEIGHT = 3.0
_ARTIST_WEIGHT = 2.0
_UPLOADER_WEIGHT = 2.0
_TEXT_WEIGHT = 1.0
_METADATA_TEXT_KEYS = ("description", "channel", "track", "album", "tags")


class ToolError(Exception):
    """Typed, agent-safe tool failure (e.g. an unknown candidate id)."""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)


def normalize_tokens(text: str) -> list[str]:
    """Lowercase, strip diacritics and punctuation, split on whitespace."""

    if not text:
        return []
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    out: list[str] = []
    token_chars: list[str] = []
    for ch in stripped.lower():
        if ch.isalnum():
            token_chars.append(ch)
        elif token_chars:
            out.append("".join(token_chars))
            token_chars = []
    if token_chars:
        out.append("".join(token_chars))
    return out


def _weighted_candidate_tokens(candidate: RawCandidate) -> dict[str, float]:
    weighted: dict[str, float] = {}

    def add(text: Optional[str], weight: float) -> None:
        for token in normalize_tokens(text or ""):
            if weighted.get(token, 0.0) < weight:
                weighted[token] = weight

    add(candidate.title, _TITLE_WEIGHT)
    add(candidate.artist, _ARTIST_WEIGHT)
    add(candidate.uploader, _UPLOADER_WEIGHT)
    metadata = candidate.metadata or {}
    for key in _METADATA_TEXT_KEYS:
        value = metadata.get(key)
        if isinstance(value, str):
            add(value, _TEXT_WEIGHT)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, str):
                    add(item, _TEXT_WEIGHT)
    return weighted


def _weighted_catalog_tokens(entry: CatalogEntry) -> dict[str, float]:
    weighted: dict[str, float] = {}

    def add(text: Optional[str], weight: float) -> None:
        for token in normalize_tokens(text or ""):
            if weighted.get(token, 0.0) < weight:
                weighted[token] = weight

    add(entry.title, _TITLE_WEIGHT)
    add(entry.artist, _ARTIST_WEIGHT)
    return weighted


def _score(query_tokens: list[str], weighted: dict[str, float]) -> float:
    """Normalized weighted overlap in ``[0, 1]``.

    A query token matched in the title contributes the full title weight; the
    denominator normalizes by every query token matching at title weight, so a
    perfect title match scores ``1.0`` and a metadata-only match scores lower.
    """

    if not query_tokens:
        return 0.0
    total = 0.0
    for token in query_tokens:
        total += weighted.get(token, 0.0)
    return total / (len(query_tokens) * _TITLE_WEIGHT)


def rank_candidates(
    query: str, candidates: list[RawCandidate], limit: int
) -> list[RawCandidate]:
    """Deterministically rank a candidate pool by retrieval relevance. Pure."""

    query_tokens = normalize_tokens(query)
    scored: list[tuple[float, int, RawCandidate]] = []
    for index, candidate in enumerate(candidates):
        score = _score(query_tokens, _weighted_candidate_tokens(candidate))
        if score > RETRIEVAL_MIN_SCORE:
            scored.append((score, index, candidate))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [candidate for _, _, candidate in scored[: max(0, limit)]]


def rank_catalog(
    query: str, entries: list[CatalogEntry], kind: str, limit: int
) -> list[CatalogEntry]:
    query_tokens = normalize_tokens(query)
    scored: list[tuple[float, int, CatalogEntry]] = []
    for index, entry in enumerate(entries):
        if kind and entry.kind != kind:
            continue
        score = _score(query_tokens, _weighted_catalog_tokens(entry))
        if score > RETRIEVAL_MIN_SCORE:
            scored.append((score, index, entry))
    # Catalog ties break toward the higher upstream score, then pool order.
    scored.sort(key=lambda item: (-item[0], -item[2].score, item[1]))
    return [entry for _, _, entry in scored[: max(0, limit)]]


class ToolBox:
    """Read-only tool surface + budget enforcement for one arm run."""

    def __init__(
        self,
        world: FixtureWorld,
        budget: Budget,
        now: Callable[[], float] = time.monotonic,
    ) -> None:
        self.world = world
        self.budget = budget
        self._now = now
        self._start = now()
        self.tool_calls = 0
        self.trace: list[TraceStep] = []
        self.allowlist: set[str] = set()

    # -- enforcement ------------------------------------------------------

    def _clamp_limit(self, limit: int) -> int:
        try:
            value = int(limit)
        except (TypeError, ValueError):
            value = MAX_LIMIT_PER_CALL
        ceiling = min(MAX_LIMIT_PER_CALL, self.budget.max_candidates_in)
        return max(1, min(value, ceiling))

    def _guard_before_call(self, args: dict) -> None:
        if self.tool_calls >= self.budget.max_tool_calls:
            raise BudgetExceeded(
                BUDGET_EXCEEDED_CODE,
                f"exceeded max tool calls ({self.budget.max_tool_calls})",
            )
        elapsed = self._now() - self._start
        if elapsed > self.budget.wall_clock_s:
            raise BudgetExceeded(
                BUDGET_EXCEEDED_CODE,
                f"exceeded wall clock budget ({self.budget.wall_clock_s}s)",
            )
        request_bytes = len(json.dumps(args, sort_keys=True).encode("utf-8"))
        if request_bytes > self.budget.max_request_bytes:
            raise BudgetExceeded(
                BUDGET_EXCEEDED_CODE,
                f"tool request exceeded {self.budget.max_request_bytes} bytes",
            )

    def _record(
        self, tool: str, args: dict, serialized: str, result_count: int
    ) -> None:
        response_bytes = len(serialized.encode("utf-8"))
        if response_bytes > self.budget.max_response_bytes:
            raise BudgetExceeded(
                BUDGET_EXCEEDED_CODE,
                f"tool response exceeded {self.budget.max_response_bytes} bytes",
            )
        digest = hashlib.sha256(
            json.dumps(args, sort_keys=True).encode("utf-8")
        ).hexdigest()[:12]
        elapsed_ms = int(round((self._now() - self._start) * 1000))
        self.trace.append(
            TraceStep(
                step=len(self.trace) + 1,
                tool=tool,
                argsDigest=digest,
                resultCount=result_count,
                elapsedMs=elapsed_ms,
            )
        )

    # -- tools ------------------------------------------------------------

    def search_sources(
        self, query: str, providers: Optional[list[str]] = None, limit: int = 10
    ) -> list[RawCandidate]:
        args = {"query": query, "providers": providers or [], "limit": limit}
        self._guard_before_call(args)
        self.tool_calls += 1
        clamped = self._clamp_limit(limit)
        wanted = {p.strip().lower() for p in (providers or []) if p and p.strip()}
        pool = self.world.candidates
        if wanted:
            pool = [c for c in pool if c.provider.lower() in wanted]
        results = rank_candidates(query, pool, clamped)
        serialized = json.dumps(
            [c.model_dump(exclude_none=True) for c in results], sort_keys=True
        )
        self._record("search_sources", args, serialized, len(results))
        for candidate in results:
            self.allowlist.add(candidate.candidateId)
        return results

    def search_catalog(
        self, query: str, kind: str = "track", limit: int = 8
    ) -> list[CatalogEntry]:
        args = {"query": query, "kind": kind, "limit": limit}
        self._guard_before_call(args)
        self.tool_calls += 1
        clamped = self._clamp_limit(limit)
        results = rank_catalog(query, self.world.catalog, kind, clamped)
        serialized = json.dumps(
            [e.model_dump(exclude_none=True) for e in results], sort_keys=True
        )
        self._record("search_catalog", args, serialized, len(results))
        return results

    def inspect_source_metadata(self, candidate_id: str) -> RichMetadata:
        args = {"candidateId": candidate_id}
        self._guard_before_call(args)
        self.tool_calls += 1
        metadata = self.world.metadata.get(candidate_id)
        if metadata is None:
            # A missing id still counts as a tool call and a trace step, then
            # surfaces as a typed error the agent can react to.
            self._record("inspect_source_metadata", args, "{}", 0)
            raise ToolError(
                "UNKNOWN_CANDIDATE",
                f"no metadata for candidate {candidate_id!r}",
            )
        serialized = json.dumps(metadata.model_dump(exclude_none=True), sort_keys=True)
        self._record("inspect_source_metadata", args, serialized, 1)
        return metadata

    def extract_web(self, evidence_ref: str) -> GatewayEvidence:
        """Keep fixture replay hermetic; evidence extraction is gateway-only."""

        args = {"evidenceRef": evidence_ref}
        self._guard_before_call(args)
        self.tool_calls += 1
        self._record("extract_web", args, "{}", 0)
        raise ToolError(
            "TOOL_DISABLED", "web extraction is disabled for fixture replay"
        )
