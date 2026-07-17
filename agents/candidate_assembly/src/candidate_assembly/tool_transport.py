"""Shared protocol and model-safe observation adapters for read-only tools."""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from .schemas import (
    CatalogEntry,
    GatewayCandidate,
    GatewayCatalogEntry,
    GatewayEvidence,
    GatewayMetadata,
    RawCandidate,
    RichMetadata,
)


@runtime_checkable
class ReadOnlyToolTransport(Protocol):
    """The bounded surface future async workers may use.

    Fixture ``ToolBox`` conforms structurally and remains the default for all
    current evals. Gateway construction is an explicit caller decision.
    """

    def search_sources(
        self, query: str, providers: list[str] | None = None, limit: int = 10
    ) -> list[Any]: ...

    def search_catalog(
        self, query: str, kind: str = "track", limit: int = 8
    ) -> list[Any]: ...

    def inspect_source_metadata(self, candidate_id: str) -> Any: ...

    def extract_web(self, evidence_ref: str) -> GatewayEvidence: ...


def model_safe_observation(value: Any) -> Any:
    """Convert fixture or gateway results to URL/secret-free model payloads."""

    if isinstance(value, RawCandidate):
        return GatewayCandidate.model_validate(
            value.model_dump(
                exclude={"sourceUrl", "thumbnailUrl", "metadata"}, exclude_none=True
            )
        ).model_dump(exclude_none=True)
    if isinstance(value, CatalogEntry):
        return GatewayCatalogEntry.model_validate(
            value.model_dump(exclude_none=True)
        ).model_dump(exclude_none=True)
    if isinstance(value, RichMetadata):
        return GatewayMetadata.model_validate(
            value.model_dump(exclude_none=True)
        ).model_dump(exclude_none=True)
    if isinstance(
        value, (GatewayCandidate, GatewayCatalogEntry, GatewayMetadata, GatewayEvidence)
    ):
        return value.model_dump(exclude_none=True)
    if isinstance(value, list):
        return [model_safe_observation(item) for item in value]
    raise TypeError("unsupported tool observation")
