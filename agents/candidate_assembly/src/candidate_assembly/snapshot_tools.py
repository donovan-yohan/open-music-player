"""Read-only, URL-free tools backed by one Go-owned worker snapshot."""

from __future__ import annotations

import hashlib
import json
import time
from typing import Optional

from .budgets import BUDGET_EXCEEDED_CODE, MAX_LIMIT_PER_CALL, Budget, BudgetExceeded
from .fixture_tools import ToolError
from .schemas import (
    GatewayCatalogEntry,
    GatewayMetadata,
    TraceStep,
    WorkerCandidate,
)


INVALID_ARGUMENT = "INVALID_ARGUMENT"
CANDIDATE_UNKNOWN = "CANDIDATE_UNKNOWN"


class SnapshotWorld:
    """Small world adapter consumed by the shared validator and DeepAgent arm."""

    def __init__(
        self,
        candidates: list[WorkerCandidate],
        catalog: list[GatewayCatalogEntry],
        metadata: dict[str, GatewayMetadata],
    ) -> None:
        self.candidates = candidates
        self.catalog = catalog
        self.metadata = metadata
        self.source_quality_by_id = {
            candidate.candidateId: candidate.sourceQuality for candidate in candidates
        }

    def by_id(self, candidate_id: str) -> Optional[WorkerCandidate]:
        return next(
            (candidate for candidate in self.candidates if candidate.candidateId == candidate_id),
            None,
        )

    def candidate_ids(self) -> set[str]:
        return set(self.source_quality_by_id)


class SnapshotToolBox:
    """Bounded read-only tools over one immutable request projection.

    Search calls never leave the supplied snapshot. Their query arguments only
    select/filter deterministic local results, keeping candidate IDs durable.
    """

    def __init__(
        self, world: SnapshotWorld, budget: Budget, *, deadline: Optional[float] = None
    ) -> None:
        self.world = world
        self.budget = budget
        self.trace: list[TraceStep] = []
        self.tool_calls = 0
        self.request_bytes = 0
        self.response_bytes = 0
        self.allowlist: set[str] = set()
        self.input_allowlist = world.candidate_ids()
        self._started = time.monotonic()
        self._deadline = deadline

    def _encode(self, args: dict) -> bytes:
        return json.dumps(args, sort_keys=True, separators=(",", ":")).encode("utf-8")

    def _limit(self, limit: int) -> int:
        try:
            numeric = int(limit)
        except (TypeError, ValueError):
            numeric = MAX_LIMIT_PER_CALL
        return max(1, min(numeric, MAX_LIMIT_PER_CALL, self.budget.max_candidates_in))

    def _guard(self, args: dict) -> bytes:
        if self.tool_calls >= self.budget.max_tool_calls:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "exceeded max tool calls")
        now = time.monotonic()
        if now - self._started > self.budget.wall_clock_s or (
            self._deadline is not None and now >= self._deadline
        ):
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "exceeded wall clock budget")
        encoded = self._encode(args)
        if self.request_bytes + len(encoded) > self.budget.max_request_bytes:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "tool request exceeded byte budget")
        self.request_bytes += len(encoded)
        self.tool_calls += 1
        return encoded

    def _record(self, tool: str, args: dict, result_count: int) -> None:
        digest = hashlib.sha256(self._encode(args)).hexdigest()[:12]
        self.trace.append(
            TraceStep(
                step=len(self.trace) + 1,
                tool=tool,
                argsDigest=digest,
                resultCount=result_count,
                elapsedMs=max(0, int(round((time.monotonic() - self._started) * 1000))),
            )
        )

    def _bounded_response(self, value: object) -> None:
        encoded = self._encode(value if isinstance(value, dict) else {"result": value})
        if self.response_bytes + len(encoded) > self.budget.max_response_bytes:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "tool response exceeded byte budget")
        self.response_bytes += len(encoded)

    def search_sources(
        self, query: str, providers: Optional[list[str]] = None, limit: int = 10
    ) -> list[WorkerCandidate]:
        args = {"query": query, "providers": providers or [], "limit": self._limit(limit)}
        self._guard(args)
        if not isinstance(query, str) or not query.strip():
            self._record("search_sources", args, 0)
            raise ToolError(INVALID_ARGUMENT, "tool argument is invalid")
        selected = self.world.candidates
        if providers:
            provider_set = {provider.lower() for provider in providers if isinstance(provider, str)}
            selected = [candidate for candidate in selected if candidate.provider in provider_set]
        ordered = sorted(
            selected,
            key=lambda candidate: (-candidate.sourceQuality.score, candidate.candidateId),
        )[: args["limit"]]
        try:
            self._bounded_response([candidate.model_dump(exclude_none=True) for candidate in ordered])
        except BudgetExceeded:
            self._record("search_sources", args, 0)
            raise
        self._record("search_sources", args, len(ordered))
        self.allowlist.update(candidate.candidateId for candidate in ordered)
        return ordered

    def search_catalog(
        self, query: str, kind: str = "track", limit: int = 8
    ) -> list[GatewayCatalogEntry]:
        args = {"query": query, "kind": kind, "limit": self._limit(limit)}
        self._guard(args)
        if not isinstance(query, str) or not query.strip() or kind not in {"track", "artist", "album"}:
            self._record("search_catalog", args, 0)
            raise ToolError(INVALID_ARGUMENT, "tool argument is invalid")
        selected = [entry for entry in self.world.catalog if entry.kind == kind]
        ordered = sorted(selected, key=lambda entry: (-entry.score, entry.id))[: args["limit"]]
        try:
            self._bounded_response([entry.model_dump(exclude_none=True) for entry in ordered])
        except BudgetExceeded:
            self._record("search_catalog", args, 0)
            raise
        self._record("search_catalog", args, len(ordered))
        return ordered

    def inspect_source_metadata(self, candidate_id: str) -> GatewayMetadata:
        args = {"candidate_id": candidate_id}
        self._guard(args)
        metadata = self.world.metadata.get(candidate_id)
        if metadata is None:
            self._record("inspect_source_metadata", args, 0)
            raise ToolError(CANDIDATE_UNKNOWN, "candidate is unavailable")
        try:
            self._bounded_response(metadata.model_dump(exclude_none=True))
        except BudgetExceeded:
            self._record("inspect_source_metadata", args, 0)
            raise
        self._record("inspect_source_metadata", args, 1)
        self.allowlist.add(candidate_id)
        return metadata
