from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import pytest

from candidate_assembly.budgets import Budget, BudgetExceeded
from candidate_assembly.fixture_tools import ToolBox, ToolError
from candidate_assembly.gateway_tools import (
    CAPABILITY_EXPIRED,
    GATEWAY_CONFIG,
    GATEWAY_DISABLED,
    GATEWAY_HTTP,
    GATEWAY_MALFORMED,
    GATEWAY_OVERSIZE,
    GATEWAY_QUOTA,
    GATEWAY_TIMEOUT,
    UNKNOWN_CANDIDATE,
    UNKNOWN_EVIDENCE,
    GatewayConfig,
    GatewayToolBox,
    HttpRequest,
    HttpResponse,
    UrllibHttpTransport,
    build_gateway_toolbox_from_env,
)
from candidate_assembly.tool_transport import (
    ReadOnlyToolTransport,
    model_safe_observation,
)
from conftest import make_candidate, make_world


def _config() -> GatewayConfig:
    return GatewayConfig(
        base_url="https://gateway.test",
        service_token="service-token-never-recorded",
        timeout_s=1.0,
    )


def _payload(value: object, status: int = 200) -> HttpResponse:
    return HttpResponse(status=status, body=json.dumps(value).encode())


def _error_payload(
    code: str, status: int, message: str = "request failed"
) -> HttpResponse:
    return _payload({"error": {"code": code, "message": message}}, status=status)


class FakeTransport:
    def __init__(self, responses: dict[str, HttpResponse | Exception]) -> None:
        self.responses = responses
        self.requests: list[HttpRequest] = []

    def post(self, request: HttpRequest, response_limit: int) -> HttpResponse:
        self.requests.append(request)
        response = self.responses[urlsplit(request.url).path.rsplit("/", 1)[-1]]
        if isinstance(response, Exception):
            raise response
        return response


def _gateway_responses(
    *, expires_at: str = "2099-01-01T00:00:00Z"
) -> dict[str, HttpResponse]:
    return {
        "capabilities": _payload(
            {"capability": "capability-opaque", "expiresAt": expires_at, "maxCalls": 24}
        ),
        "search-sources": _payload(
            {
                "query": "artist song",
                "candidates": [
                    {
                        "candidateId": "youtube:source-1",
                        "provider": "youtube",
                        "title": "Artist - Song",
                        "downloadable": True,
                        "evidenceRefs": ["evidence:source-1"],
                    }
                ],
                "providers": [],
            }
        ),
        "search-catalog": _payload(
            {
                "query": "artist song",
                "kind": "track",
                "items": [
                    {"kind": "track", "id": "catalog:track-1", "title": "Artist - Song"}
                ],
            }
        ),
        "inspect-source-metadata": _payload(
            {
                "candidateId": "youtube:source-1",
                "provider": "youtube",
                "title": "Artist - Song",
                "downloadable": True,
                "metadata": {"album": "Album"},
                "evidenceRefs": ["evidence:metadata-1"],
            }
        ),
        "extract-web": _payload(
            {
                "evidenceRef": "evidence:source-1",
                "markdown": "Artist and track title match.",
            }
        ),
    }


def test_gateway_all_tools_reuse_capability_and_keep_credentials_out_of_trace():
    transport = FakeTransport(_gateway_responses())
    box = GatewayToolBox(_config(), Budget.default(), transport=transport)

    candidates = box.search_sources("artist song", ["youtube"], 99)
    catalog = box.search_catalog("artist song")
    metadata = box.inspect_source_metadata(candidates[0].candidateId)
    evidence = box.extract_web("evidence:source-1")

    assert candidates[0].candidateId == "youtube:source-1"
    assert catalog[0].id == "catalog:track-1"
    assert metadata.candidateId == candidates[0].candidateId
    assert evidence.evidenceRef == "evidence:source-1"
    assert box.tool_calls == 4
    assert [step.tool for step in box.trace] == [
        "search_sources",
        "search_catalog",
        "inspect_source_metadata",
        "extract_web",
    ]
    assert [
        urlsplit(request.url).path.rsplit("/", 1)[-1] for request in transport.requests
    ] == [
        "capabilities",
        "search-sources",
        "search-catalog",
        "inspect-source-metadata",
        "extract-web",
    ]
    rendered = repr(box) + repr(box._config) + repr(box.trace)
    assert "service-token-never-recorded" not in rendered
    assert "capability-opaque" not in rendered
    assert "https://gateway.test" not in rendered


def test_gateway_server_receives_only_expected_auth_headers():
    captured: list[tuple[str, dict[str, str], dict]] = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 - stdlib callback name
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            captured.append((self.path, dict(self.headers), body))
            payload = (
                {
                    "capability": "capability-opaque",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "maxCalls": 24,
                }
                if self.path.endswith("/capabilities")
                else {"query": "artist song", "candidates": [], "providers": []}
            )
            encoded = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        config = GatewayConfig(
            base_url=f"http://127.0.0.1:{server.server_port}",
            service_token="service-token-never-recorded",
            timeout_s=1.0,
            allow_insecure_http=True,
        )
        GatewayToolBox(config, Budget.default()).search_sources("artist song")
    finally:
        server.shutdown()
        thread.join()
        server.server_close()

    capability_headers = captured[0][1]
    tool_headers = captured[1][1]
    assert (
        capability_headers["X-Omp-Agent-Service-Token"]
        == "service-token-never-recorded"
    )
    assert "Authorization" not in capability_headers
    assert tool_headers["Authorization"] == "Bearer capability-opaque"
    assert "X-Omp-Agent-Service-Token" not in tool_headers
    assert captured[1][2] == {"limit": 10, "providers": [], "query": "artist song"}


def test_gateway_rejects_unknown_ids_without_network_calls():
    transport = FakeTransport(_gateway_responses())
    box = GatewayToolBox(_config(), Budget.default(), transport=transport)
    with pytest.raises(ToolError) as candidate_error:
        box.inspect_source_metadata("youtube:not-returned")
    with pytest.raises(ToolError) as evidence_error:
        box.extract_web("evidence:not-returned")
    assert candidate_error.value.code == UNKNOWN_CANDIDATE
    assert evidence_error.value.code == UNKNOWN_EVIDENCE
    assert transport.requests == []
    assert [step.resultCount for step in box.trace] == [0, 0]


@pytest.mark.parametrize(
    ("response", "expected"),
    [
        (TimeoutError(), GATEWAY_TIMEOUT),
        (_payload({}, status=429), GATEWAY_QUOTA),
        (
            _payload({"candidates": [{"sourceUrl": "https://forbidden.test"}]}),
            GATEWAY_MALFORMED,
        ),
        (
            _payload(
                {
                    "candidates": [
                        {
                            "candidateId": "youtube:a",
                            "provider": "youtube",
                            "title": "https://forbidden.test",
                            "downloadable": True,
                        }
                    ]
                }
            ),
            GATEWAY_MALFORMED,
        ),
    ],
)
def test_gateway_converts_timeout_http_and_unsafe_or_malformed_responses(
    response, expected
):
    responses = _gateway_responses()
    responses["search-sources"] = response
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(responses)
    )
    with pytest.raises(ToolError) as error:
        box.search_sources("artist song")
    assert error.value.code == expected
    assert "forbidden.test" not in str(error.value)


def test_gateway_rejects_oversize_and_expired_capability():
    oversized = _gateway_responses()
    oversized["search-sources"] = _payload({"candidates": [], "padding": "x" * 500})
    box = GatewayToolBox(
        _config(),
        Budget.default().with_overrides(max_response_bytes=150),
        transport=FakeTransport(oversized),
    )
    with pytest.raises(ToolError) as oversized_error:
        box.search_sources("artist song")
    assert oversized_error.value.code == GATEWAY_OVERSIZE

    expired = GatewayToolBox(
        _config(),
        Budget.default(),
        transport=FakeTransport(_gateway_responses(expires_at="2020-01-01T00:00:00Z")),
        now=lambda: datetime(2025, 1, 1, tzinfo=timezone.utc),
    )
    with pytest.raises(ToolError) as expired_error:
        expired.search_sources("artist song")
    assert expired_error.value.code == CAPABILITY_EXPIRED


def test_gateway_preserves_gateway_unknown_and_disabled_error_codes():
    unknown = _gateway_responses()
    unknown["inspect-source-metadata"] = _error_payload("CANDIDATE_UNKNOWN", status=404)
    box = GatewayToolBox(_config(), Budget.default(), transport=FakeTransport(unknown))
    candidate = box.search_sources("artist song")[0]
    with pytest.raises(ToolError) as unknown_error:
        box.inspect_source_metadata(candidate.candidateId)
    assert unknown_error.value.code == "CANDIDATE_UNKNOWN"

    disabled = _gateway_responses()
    disabled["extract-web"] = _error_payload("FIRECRAWL_DISABLED", status=503)
    box = GatewayToolBox(_config(), Budget.default(), transport=FakeTransport(disabled))
    box.search_sources("artist song")
    with pytest.raises(ToolError) as disabled_error:
        box.extract_web("evidence:source-1")
    assert disabled_error.value.code == "FIRECRAWL_DISABLED"


@pytest.mark.parametrize(
    ("code", "status"),
    [
        ("CAPABILITY_EXPIRED", 401),
        ("CAPABILITY_UNKNOWN", 401),
        ("CAPABILITY_RATE_LIMIT", 429),
        ("CAPABILITY_BUSY", 503),
        ("CAPABILITY_RESOURCE_LIMIT", 429),
        ("PROVIDER_BUSY", 503),
        ("FIRECRAWL_DISABLED", 503),
        ("FIRECRAWL_BUSY", 503),
        ("FIRECRAWL_RATE_LIMIT", 429),
        ("FIRECRAWL_TIMEOUT", 502),
        ("FIRECRAWL_RESPONSE_TOO_LARGE", 502),
        ("FIRECRAWL_BAD_RESPONSE", 502),
    ],
)
def test_gateway_preserves_only_allowlisted_backend_codes_without_message_leak(
    code, status
):
    responses = _gateway_responses()
    responses["search-sources"] = _error_payload(
        code,
        status,
        message=(
            "https://private-gateway.test Authorization: Bearer "
            "capability-opaque service-token-never-recorded"
        ),
    )
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(responses)
    )

    with pytest.raises(ToolError) as error:
        box.search_sources("artist song")

    assert error.value.code == code
    rendered = str(error.value) + repr(error.value) + repr(box.trace)
    assert "private-gateway" not in rendered
    assert "capability-opaque" not in rendered
    assert "service-token-never-recorded" not in rendered


@pytest.mark.parametrize(
    "body",
    [
        {"error": {"code": "UNTRUSTED_SERVER_CODE", "message": "secret body"}},
        {
            "error": {
                "code": "CAPABILITY_EXPIRED",
                "message": "expired",
                "extra": "not allowed",
            }
        },
    ],
)
def test_gateway_rejects_unallowlisted_or_non_strict_error_envelopes(body):
    responses = _gateway_responses()
    responses["search-sources"] = _payload(body, status=401)
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(responses)
    )

    with pytest.raises(ToolError) as error:
        box.search_sources("artist song")

    assert error.value.code == GATEWAY_HTTP
    assert "secret body" not in str(error.value)


def test_search_sources_wire_envelope_rejects_uncoordinated_truncated_field():
    responses = _gateway_responses()
    payload = json.loads(responses["search-sources"].body)
    payload["truncated"] = True
    responses["search-sources"] = _payload(payload)
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(responses)
    )

    with pytest.raises(ToolError) as error:
        box.search_sources("artist song")

    assert error.value.code == GATEWAY_MALFORMED


def test_gateway_evidence_accepts_exact_4k_and_rejects_over_bound_as_typed():
    exact = _gateway_responses()
    exact["extract-web"] = _payload(
        {"evidenceRef": "evidence:source-1", "markdown": "x" * 4096}
    )
    box = GatewayToolBox(_config(), Budget.default(), transport=FakeTransport(exact))
    box.search_sources("artist song")
    assert len(box.extract_web("evidence:source-1").text.encode("utf-8")) == 4096

    oversized = _gateway_responses()
    oversized["extract-web"] = _payload(
        {"evidenceRef": "evidence:source-1", "markdown": "x" * 4097}
    )
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(oversized)
    )
    box.search_sources("artist song")
    with pytest.raises(ToolError) as error:
        box.extract_web("evidence:source-1")
    assert error.value.code == GATEWAY_OVERSIZE


def test_gateway_projection_validation_is_typed_and_safe():
    responses = _gateway_responses()
    responses["inspect-source-metadata"] = _payload(
        {
            "candidateId": "youtube:source-1",
            "provider": "youtube",
            "title": "Artist - Song",
            "downloadable": True,
            "metadata": {"album": "x" * 513},
        }
    )
    box = GatewayToolBox(
        _config(), Budget.default(), transport=FakeTransport(responses)
    )
    candidate = box.search_sources("artist song")[0]

    with pytest.raises(ToolError) as error:
        box.inspect_source_metadata(candidate.candidateId)

    assert error.value.code == GATEWAY_MALFORMED
    assert "ValidationError" not in str(error.value)


def test_gateway_budget_and_disabled_factory_are_typed_and_safe():
    with pytest.raises(ToolError) as disabled:
        build_gateway_toolbox_from_env(Budget.default(), env={})
    assert disabled.value.code == GATEWAY_DISABLED

    with pytest.raises(ToolError) as invalid_timeout:
        build_gateway_toolbox_from_env(
            Budget.default(),
            env={
                "AGENT_TOOL_GATEWAY_URL": "https://gateway-host.example",
                "AGENT_TOOL_GATEWAY_SERVICE_TOKEN": "service-token-never-recorded",
                "AGENT_TOOL_GATEWAY_TIMEOUT_S": "0",
            },
        )
    assert invalid_timeout.value.code == "GATEWAY_CONFIG"

    box = GatewayToolBox(
        _config(),
        Budget.default().with_overrides(max_request_bytes=24),
        transport=FakeTransport(_gateway_responses()),
    )
    with pytest.raises(BudgetExceeded):
        box.search_sources("artist song")
    assert box.tool_calls == 0


def test_gateway_requires_https_unless_strict_insecure_opt_in_is_enabled():
    with pytest.raises(ToolError) as direct_http:
        GatewayConfig(
            base_url="http://127.0.0.1:8080",
            service_token="service-token-never-recorded",
            timeout_s=1.0,
        )
    assert direct_http.value.code == GATEWAY_CONFIG

    local = GatewayConfig(
        base_url="http://127.0.0.1:8080",
        service_token="service-token-never-recorded",
        timeout_s=1.0,
        allow_insecure_http=True,
    )
    assert local.base_url == "http://127.0.0.1:8080"

    base_env = {
        "AGENT_TOOL_GATEWAY_URL": "http://127.0.0.1:8080",
        "AGENT_TOOL_GATEWAY_SERVICE_TOKEN": "service-token-never-recorded",
        "AGENT_TOOL_GATEWAY_TIMEOUT_S": "1",
    }
    with pytest.raises(ToolError) as env_http:
        GatewayConfig.from_env(base_env)
    assert env_http.value.code == GATEWAY_CONFIG

    enabled = GatewayConfig.from_env(
        {**base_env, "AGENT_TOOL_GATEWAY_ALLOW_INSECURE_HTTP": "true"}
    )
    assert enabled.allow_insecure_http is True

    for invalid in ("1", "TRUE", "yes"):
        with pytest.raises(ToolError) as invalid_opt_in:
            GatewayConfig.from_env(
                {**base_env, "AGENT_TOOL_GATEWAY_ALLOW_INSECURE_HTTP": invalid}
            )
        assert invalid_opt_in.value.code == GATEWAY_CONFIG


def test_stdlib_transport_does_not_follow_cross_origin_redirects_or_leak_credentials():
    target_requests: list[dict[str, str]] = []

    class TargetHandler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - stdlib callback name
            target_requests.append(dict(self.headers))
            self.send_response(204)
            self.end_headers()

        def do_POST(self):  # noqa: N802 - stdlib callback name
            target_requests.append(dict(self.headers))
            self.send_response(204)
            self.end_headers()

        def log_message(self, format, *args):
            return

    target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
    target_thread = threading.Thread(target=target.serve_forever, daemon=True)
    target_thread.start()
    redirect_capability = {"enabled": True}

    class OriginHandler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 - stdlib callback name
            if (
                self.path.endswith("/capabilities")
                and not redirect_capability["enabled"]
            ):
                encoded = json.dumps(
                    {
                        "capability": "capability-opaque",
                        "expiresAt": "2099-01-01T00:00:00Z",
                        "maxCalls": 24,
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
                return
            self.send_response(302)
            self.send_header(
                "Location", f"http://127.0.0.1:{target.server_port}/credential-sink"
            )
            self.end_headers()

        def log_message(self, format, *args):
            return

    origin = ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
    origin_thread = threading.Thread(target=origin.serve_forever, daemon=True)
    origin_thread.start()
    config = GatewayConfig(
        base_url=f"http://127.0.0.1:{origin.server_port}",
        service_token="service-token-never-recorded",
        timeout_s=1.0,
        allow_insecure_http=True,
    )

    try:
        errors = []
        with pytest.raises(ToolError) as capability_redirect:
            GatewayToolBox(config, Budget.default()).search_sources("artist song")
        errors.append(capability_redirect.value)

        redirect_capability["enabled"] = False
        with pytest.raises(ToolError) as tool_redirect:
            GatewayToolBox(config, Budget.default()).search_sources("artist song")
        errors.append(tool_redirect.value)
    finally:
        origin.shutdown()
        origin_thread.join()
        origin.server_close()
        target.shutdown()
        target_thread.join()
        target.server_close()

    assert target_requests == []
    assert [error.code for error in errors] == [GATEWAY_HTTP, GATEWAY_HTTP]
    rendered = " ".join(str(error) + repr(error) for error in errors)
    assert "service-token-never-recorded" not in rendered
    assert "capability-opaque" not in rendered


def test_stdlib_transport_preserves_only_a_bounded_error_body():
    class ErrorHandler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 - stdlib callback name
            encoded = b"x" * 128
            self.send_response(400)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), ErrorHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        response = UrllibHttpTransport().post(
            HttpRequest(
                url=f"http://127.0.0.1:{server.server_port}/error",
                headers={"Content-Type": "application/json"},
                body=b"{}",
                timeout_s=1.0,
            ),
            response_limit=32,
        )
    finally:
        server.shutdown()
        thread.join()
        server.server_close()

    assert response.status == 400
    assert len(response.body) == 33


def test_fixture_transport_remains_default_and_model_observations_drop_urls():
    fixture = ToolBox(
        make_world(candidates=[make_candidate("youtube:a")]),
        Budget.default(),
        now=lambda: 0.0,
    )
    assert isinstance(fixture, ReadOnlyToolTransport)
    raw = fixture.search_sources("artist song")[0]
    observation = model_safe_observation(raw)
    assert "sourceUrl" not in observation
    assert "thumbnailUrl" not in observation
    assert "https://" not in json.dumps(observation)
