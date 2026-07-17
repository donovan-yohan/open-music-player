"""Explicit HTTP transport for the Go-owned agent-tools gateway.

This module is deliberately not imported by the eval runner. Fixture replay
stays hermetic unless a future async worker explicitly constructs this adapter.
The gateway resolves sources and extracts evidence; Python never receives or
forwards source URLs, provider credentials, or arbitrary response data.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Mapping, Optional, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from pydantic import BaseModel, ValidationError

from .budgets import BUDGET_EXCEEDED_CODE, MAX_LIMIT_PER_CALL, Budget, BudgetExceeded
from .fixture_tools import ToolError
from .schemas import (
    GatewayCapabilityResponse,
    GatewayCatalogEntry,
    GatewayErrorEnvelope,
    GatewayEvidence,
    GatewayEvidenceWireResponse,
    GATEWAY_EVIDENCE_MAX_BYTES,
    GatewayMetadata,
    GatewaySearchCatalogWireResponse,
    GatewaySearchSourcesWireResponse,
    GatewayCandidate,
    GatewayWireCandidate,
    TraceStep,
    is_safe_gateway_text,
    is_safe_progress_reference,
)

GATEWAY_PREFIX = "/internal/agent-tools/v1"
GATEWAY_DISABLED = "GATEWAY_DISABLED"
GATEWAY_CONFIG = "GATEWAY_CONFIG"
GATEWAY_TIMEOUT = "GATEWAY_TIMEOUT"
GATEWAY_HTTP = "GATEWAY_HTTP"
GATEWAY_MALFORMED = "GATEWAY_MALFORMED"
GATEWAY_OVERSIZE = "GATEWAY_OVERSIZE"
GATEWAY_QUOTA = "GATEWAY_QUOTA"
CAPABILITY_EXPIRED = "CAPABILITY_EXPIRED"
UNKNOWN_CANDIDATE = "UNKNOWN_CANDIDATE"
UNKNOWN_EVIDENCE = "UNKNOWN_EVIDENCE"
TOOL_DISABLED = "TOOL_DISABLED"
INVALID_ARGUMENT = "INVALID_ARGUMENT"

_ALLOW_INSECURE_HTTP_ENV = "AGENT_TOOL_GATEWAY_ALLOW_INSECURE_HTTP"
_SAFE_BACKEND_ERROR_MESSAGES = {
    "CAPABILITY_RATE_LIMIT": "gateway capability issuance rate limit reached",
    "CAPABILITY_BUSY": "gateway capability service is busy",
    "CAPABILITY_EXPIRED": "gateway capability has expired",
    "CAPABILITY_UNKNOWN": "gateway capability is unknown",
    "CAPABILITY_UNAUTHORIZED": "gateway capability was rejected",
    "CAPABILITY_CALL_LIMIT": "gateway capability call limit reached",
    "CAPABILITY_RESOURCE_LIMIT": "gateway capability resource limit reached",
    "PROVIDER_BUSY": "gateway provider service is busy",
    "CANDIDATE_UNKNOWN": "candidate id is unavailable",
    "EVIDENCE_UNKNOWN": "evidence ref is unavailable",
    "EVIDENCE_UNSAFE": "web evidence is unavailable",
    "FIRECRAWL_DISABLED": "web extraction is disabled",
    "FIRECRAWL_BUSY": "web extraction service is busy",
    "FIRECRAWL_RATE_LIMIT": "web extraction rate limit reached",
    "FIRECRAWL_TIMEOUT": "web extraction timed out",
    "FIRECRAWL_FAILED": "web extraction failed",
    "FIRECRAWL_REDIRECT": "web extraction redirect was rejected",
    "FIRECRAWL_BAD_RESPONSE": "web extraction response was invalid",
    "FIRECRAWL_RESPONSE_TOO_LARGE": "web extraction response exceeded byte limit",
    "RESPONSE_TOO_LARGE": "gateway response exceeded byte limit",
}


@dataclass(frozen=True)
class GatewayConfig:
    """Environment-only configuration. repr intentionally omits every value."""

    base_url: str = field(repr=False)
    service_token: str = field(repr=False)
    timeout_s: float = field(repr=False)
    allow_insecure_http: bool = field(default=False, repr=False)

    def __post_init__(self) -> None:
        if not isinstance(self.base_url, str) or not isinstance(
            self.service_token, str
        ):
            raise ToolError(GATEWAY_CONFIG, "gateway configuration is invalid")
        if not isinstance(self.allow_insecure_http, bool):
            raise ToolError(GATEWAY_CONFIG, "gateway configuration is invalid")
        base_url = self.base_url.strip().rstrip("/")
        service_token = self.service_token.strip()
        parsed = urlsplit(base_url)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or not service_token
            or "\r" in service_token
            or "\n" in service_token
            or isinstance(self.timeout_s, bool)
        ):
            raise ToolError(GATEWAY_CONFIG, "gateway configuration is invalid")
        try:
            timeout_s = float(self.timeout_s)
        except (TypeError, ValueError):
            raise ToolError(
                GATEWAY_CONFIG, "gateway configuration is invalid"
            ) from None
        if not math.isfinite(timeout_s) or timeout_s <= 0:
            raise ToolError(GATEWAY_CONFIG, "gateway configuration is invalid")
        if parsed.scheme == "http" and not self.allow_insecure_http:
            raise ToolError(GATEWAY_CONFIG, "gateway configuration requires HTTPS")
        object.__setattr__(self, "base_url", base_url)
        object.__setattr__(self, "service_token", service_token)
        object.__setattr__(self, "timeout_s", timeout_s)

    def __repr__(self) -> str:
        return "GatewayConfig(redacted=True)"

    @classmethod
    def from_env(cls, env: Optional[Mapping[str, str]] = None) -> "GatewayConfig":
        values = os.environ if env is None else env
        base_url = values.get("AGENT_TOOL_GATEWAY_URL", "").strip()
        service_token = values.get("AGENT_TOOL_GATEWAY_SERVICE_TOKEN", "").strip()
        timeout_raw = values.get("AGENT_TOOL_GATEWAY_TIMEOUT_S", "").strip()
        allow_insecure_raw = values.get(_ALLOW_INSECURE_HTTP_ENV, "").strip()
        if not base_url or not service_token or not timeout_raw:
            raise ToolError(GATEWAY_DISABLED, "gateway is not configured")
        if allow_insecure_raw not in {"", "false", "true"}:
            raise ToolError(GATEWAY_CONFIG, "gateway configuration is invalid")
        try:
            timeout_s = float(timeout_raw)
        except ValueError:
            raise ToolError(
                GATEWAY_CONFIG, "gateway configuration is invalid"
            ) from None
        return cls(
            base_url=base_url,
            service_token=service_token,
            timeout_s=timeout_s,
            allow_insecure_http=allow_insecure_raw == "true",
        )


@dataclass(frozen=True, repr=False)
class HttpRequest:
    url: str = field(repr=False)
    headers: Mapping[str, str] = field(repr=False)
    body: bytes = field(repr=False)
    timeout_s: float = field(repr=False)

    def __repr__(self) -> str:
        return "HttpRequest(redacted=True)"


@dataclass(frozen=True, repr=False)
class HttpResponse:
    status: int
    body: bytes = field(repr=False)


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HttpTransport(Protocol):
    def post(self, request: HttpRequest, response_limit: int) -> HttpResponse: ...


class UrllibHttpTransport:
    """Tiny stdlib transport so the default package remains dependency-light."""

    def __init__(self) -> None:
        self._opener = build_opener(_NoRedirectHandler())

    def post(self, request: HttpRequest, response_limit: int) -> HttpResponse:
        native = Request(
            request.url, data=request.body, headers=dict(request.headers), method="POST"
        )
        try:
            with self._opener.open(native, timeout=request.timeout_s) as response:  # nosec B310
                return HttpResponse(
                    status=response.status, body=response.read(response_limit + 1)
                )
        except HTTPError as exc:
            try:
                return HttpResponse(status=exc.code, body=exc.read(response_limit + 1))
            finally:
                exc.close()
        except URLError as exc:
            if isinstance(exc.reason, TimeoutError):
                raise TimeoutError from None
            raise OSError from None


def build_gateway_toolbox_from_env(
    budget: Budget,
    *,
    env: Optional[Mapping[str, str]] = None,
    transport: Optional[HttpTransport] = None,
) -> "GatewayToolBox":
    """Explicit opt-in seam for a future async worker or diagnostic command."""

    return GatewayToolBox(GatewayConfig.from_env(env), budget, transport=transport)


class GatewayToolBox:
    """Bounded Go gateway client with opaque-id grounding and safe tracing."""

    def __init__(
        self,
        config: GatewayConfig,
        budget: Budget,
        *,
        transport: Optional[HttpTransport] = None,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._config = config
        self.budget = budget
        self._transport = transport or UrllibHttpTransport()
        self._now = now
        self._monotonic = monotonic
        self._started = monotonic()
        self.tool_calls = 0
        self.trace: list[TraceStep] = []
        self.allowlist: set[str] = set()
        self.evidence_allowlist: set[str] = set()
        self._capability: Optional[str] = None
        self._capability_expires_at: Optional[datetime] = None

    def __repr__(self) -> str:
        return "GatewayToolBox(redacted=True)"

    def _clamp_limit(self, limit: int) -> int:
        try:
            value = int(limit)
        except (TypeError, ValueError):
            value = MAX_LIMIT_PER_CALL
        return max(1, min(value, MAX_LIMIT_PER_CALL, self.budget.max_candidates_in))

    def _encode(self, args: dict) -> bytes:
        return json.dumps(args, sort_keys=True, separators=(",", ":")).encode("utf-8")

    def _guard(self, args: dict, *, count_call: bool) -> bytes:
        if count_call and self.tool_calls >= self.budget.max_tool_calls:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "exceeded max tool calls")
        if self._monotonic() - self._started > self.budget.wall_clock_s:
            raise BudgetExceeded(BUDGET_EXCEEDED_CODE, "exceeded wall clock budget")
        body = self._encode(args)
        if len(body) > self.budget.max_request_bytes:
            raise BudgetExceeded(
                BUDGET_EXCEEDED_CODE, "tool request exceeded byte budget"
            )
        if count_call:
            self.tool_calls += 1
        return body

    def _record(self, tool: str, args: dict, result_count: int) -> None:
        digest = hashlib.sha256(self._encode(args)).hexdigest()[:12]
        self.trace.append(
            TraceStep(
                step=len(self.trace) + 1,
                tool=tool,
                argsDigest=digest,
                resultCount=result_count,
                elapsedMs=max(
                    0, int(round((self._monotonic() - self._started) * 1000))
                ),
            )
        )

    @staticmethod
    def _safe_argument_text(value: object) -> str:
        if not isinstance(value, str) or not is_safe_gateway_text(value):
            raise ToolError(INVALID_ARGUMENT, "tool argument is invalid")
        return value

    @staticmethod
    def _safe_opaque_id(value: object) -> str:
        if not isinstance(value, str) or not is_safe_progress_reference(value):
            raise ToolError(INVALID_ARGUMENT, "tool argument is invalid")
        return value

    def _post(
        self, path: str, body: bytes, headers: Mapping[str, str], model: type[BaseModel]
    ) -> BaseModel:
        try:
            response = self._transport.post(
                HttpRequest(
                    url=f"{self._config.base_url}{GATEWAY_PREFIX}{path}",
                    headers=headers,
                    body=body,
                    timeout_s=self._config.timeout_s,
                ),
                self.budget.max_response_bytes,
            )
        except TimeoutError:
            raise ToolError(GATEWAY_TIMEOUT, "gateway request timed out") from None
        except Exception:
            raise ToolError(GATEWAY_HTTP, "gateway request failed") from None
        if len(response.body) > self.budget.max_response_bytes:
            raise ToolError(GATEWAY_OVERSIZE, "gateway response exceeded byte budget")
        if response.status < 200 or response.status >= 300:
            if 400 <= response.status <= 599:
                backend_error = self._parse_backend_error(response.body)
                if backend_error is not None:
                    message = _SAFE_BACKEND_ERROR_MESSAGES.get(
                        backend_error.error.code, "gateway request was rejected"
                    )
                    raise ToolError(backend_error.error.code, message)
            if response.status == 429:
                raise ToolError(GATEWAY_QUOTA, "gateway quota is unavailable")
            raise ToolError(GATEWAY_HTTP, "gateway request failed")
        try:
            payload = json.loads(response.body.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("response must be an object")
            if model is GatewayEvidenceWireResponse:
                evidence = payload.get("markdown")
                if (
                    isinstance(evidence, str)
                    and len(evidence.encode("utf-8")) > GATEWAY_EVIDENCE_MAX_BYTES
                ):
                    raise ToolError(
                        GATEWAY_OVERSIZE, "gateway evidence exceeded byte limit"
                    )
            return model.model_validate(payload)
        except (UnicodeDecodeError, ValueError, ValidationError):
            raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid") from None

    @staticmethod
    def _parse_backend_error(body: bytes) -> Optional[GatewayErrorEnvelope]:
        try:
            return GatewayErrorEnvelope.model_validate_json(body)
        except (ValueError, ValidationError):
            return None

    @staticmethod
    def _project(model: type[BaseModel], payload: object) -> BaseModel:
        try:
            return model.model_validate(payload)
        except ValidationError:
            raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid") from None

    def _ensure_capability(self) -> str:
        if self._capability is not None:
            if (
                self._capability_expires_at is None
                or self._now() >= self._capability_expires_at
            ):
                raise ToolError(CAPABILITY_EXPIRED, "gateway capability has expired")
            return self._capability
        body = self._guard({}, count_call=False)
        response = self._post(
            "/capabilities",
            body,
            {
                "Content-Type": "application/json",
                "X-OMP-Agent-Service-Token": self._config.service_token,
            },
            GatewayCapabilityResponse,
        )
        assert isinstance(response, GatewayCapabilityResponse)
        try:
            expires = datetime.fromisoformat(response.expiresAt.replace("Z", "+00:00"))
            if expires.tzinfo is None:
                raise ValueError("timezone required")
            expires = expires.astimezone(timezone.utc)
        except ValueError:
            raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid") from None
        if self._now() >= expires:
            raise ToolError(CAPABILITY_EXPIRED, "gateway capability has expired")
        self._capability = response.capability
        self._capability_expires_at = expires
        return response.capability

    def _tool_headers(self) -> dict[str, str]:
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self._ensure_capability()}",
        }

    def search_sources(
        self, query: str, providers: Optional[list[str]] = None, limit: int = 10
    ) -> list[GatewayCandidate]:
        query = self._safe_argument_text(query)
        safe_providers = [
            self._safe_argument_text(provider) for provider in (providers or [])
        ]
        args = {
            "query": query,
            "providers": safe_providers,
            "limit": self._clamp_limit(limit),
        }
        body = self._guard(args, count_call=True)
        try:
            response = self._post(
                "/search-sources",
                body,
                self._tool_headers(),
                GatewaySearchSourcesWireResponse,
            )
            assert isinstance(response, GatewaySearchSourcesWireResponse)
            candidates = []
            for candidate in response.candidates:
                projected = self._project(
                    GatewayCandidate, candidate.model_dump(exclude={"metadata"})
                )
                assert isinstance(projected, GatewayCandidate)
                candidates.append(projected)
        except ToolError:
            self._record("search_sources", args, 0)
            raise
        self._record("search_sources", args, len(candidates))
        for candidate in candidates:
            self.allowlist.add(candidate.candidateId)
            self.evidence_allowlist.update(candidate.evidenceRefs)
        return candidates

    def search_catalog(
        self, query: str, kind: str = "track", limit: int = 8
    ) -> list[GatewayCatalogEntry]:
        query = self._safe_argument_text(query)
        kind = self._safe_argument_text(kind)
        args = {"query": query, "kind": kind, "limit": self._clamp_limit(limit)}
        body = self._guard(args, count_call=True)
        try:
            response = self._post(
                "/search-catalog",
                body,
                self._tool_headers(),
                GatewaySearchCatalogWireResponse,
            )
            assert isinstance(response, GatewaySearchCatalogWireResponse)
            catalog = []
            for item in response.items:
                if item.id is None:
                    raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid")
                projected = self._project(
                    GatewayCatalogEntry,
                    {
                        "kind": item.kind,
                        "id": item.id,
                        "title": item.title,
                        "artist": item.artist,
                        "durationMs": item.durationMs,
                        "score": item.score,
                    },
                )
                assert isinstance(projected, GatewayCatalogEntry)
                catalog.append(projected)
        except ToolError:
            self._record("search_catalog", args, 0)
            raise
        self._record("search_catalog", args, len(catalog))
        return catalog

    def inspect_source_metadata(self, candidate_id: str) -> GatewayMetadata:
        candidate_id = self._safe_opaque_id(candidate_id)
        args = {"candidateId": candidate_id}
        body = self._guard(args, count_call=True)
        if candidate_id not in self.allowlist:
            self._record("inspect_source_metadata", args, 0)
            raise ToolError(
                UNKNOWN_CANDIDATE, "candidate id was not returned by search"
            )
        try:
            response = self._post(
                "/inspect-source-metadata",
                body,
                self._tool_headers(),
                GatewayWireCandidate,
            )
            assert isinstance(response, GatewayWireCandidate)
            if response.candidateId != candidate_id:
                raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid")
            projected = self._project(
                GatewayMetadata,
                {
                    "candidateId": response.candidateId,
                    "evidenceRefs": response.evidenceRefs,
                    "attributes": [
                        {"key": key, "value": value}
                        for key, value in sorted(response.metadata.items())
                    ],
                },
            )
            assert isinstance(projected, GatewayMetadata)
            metadata = projected
        except ToolError:
            self._record("inspect_source_metadata", args, 0)
            raise
        self._record("inspect_source_metadata", args, 1)
        self.evidence_allowlist.update(metadata.evidenceRefs)
        return metadata

    def extract_web(self, evidence_ref: str) -> GatewayEvidence:
        evidence_ref = self._safe_opaque_id(evidence_ref)
        args = {"evidenceRef": evidence_ref}
        body = self._guard(args, count_call=True)
        if evidence_ref not in self.evidence_allowlist:
            self._record("extract_web", args, 0)
            raise ToolError(UNKNOWN_EVIDENCE, "evidence ref was not returned by a tool")
        try:
            response = self._post(
                "/extract-web", body, self._tool_headers(), GatewayEvidenceWireResponse
            )
            assert isinstance(response, GatewayEvidenceWireResponse)
            if response.evidenceRef != evidence_ref:
                raise ToolError(GATEWAY_MALFORMED, "gateway response is invalid")
            projected = self._project(
                GatewayEvidence,
                {"evidenceRef": response.evidenceRef, "text": response.markdown},
            )
            assert isinstance(projected, GatewayEvidence)
            evidence = projected
        except ToolError:
            self._record("extract_web", args, 0)
            raise
        self._record("extract_web", args, 1)
        return evidence
