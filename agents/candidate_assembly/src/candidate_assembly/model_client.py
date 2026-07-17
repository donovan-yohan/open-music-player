"""Model endpoint configuration and the structured-output transport.

The endpoint is an OpenAI-compatible llama-swap proxy. Nothing here is ever
hardcoded — every value comes from the environment — and none of it is imported
or exercised on the network-free replay path. The model arms read
``ModelConfig.from_env()`` only when they actually run live.

Verified endpoint behavior (probed live): ``response_format={"type":
"json_object"}`` is honored — grammar-enforced pure JSON arrives in
``message.content`` while the model's chain-of-thought is returned separately in
``message.reasoning_content`` (which we never read). ``response_format`` of type
``json_schema`` is silently ignored (prose comes back). Native tool support is
endpoint- and model-dependent, so the startup probe records it but does not
change transport selection. The transport here remains: json_object enforcement
with defensive content parsing + one bounded repair retry, never
``with_structured_output`` / ``json_schema``.
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from pydantic import BaseModel, ValidationError

# Environment variables (see docs/AI_EVALS.md). Keep endpoints/keys in the shell
# or a secret store — never in fixtures, docs, or artifacts.
ENV_BASE_URL = "AGENT_SEARCH_BASE_URL"
ENV_API_KEY = "AGENT_SEARCH_API_KEY"
ENV_MODEL = "AGENT_SEARCH_MODEL"
ENV_TIMEOUT = "AGENT_SEARCH_TIMEOUT_S"
ENV_RUN_TIMEOUT = "AGENT_SEARCH_RUN_TIMEOUT_S"

# The endpoint spends reasoning tokens before the answer, so completions always
# request at least this many tokens regardless of a smaller budget override.
MIN_COMPLETION_TOKENS = 4096

Message = dict[str, Any]
ChatFn = Callable[[list[Message]], str]


class ModelConfigError(RuntimeError):
    pass


class StructuredParseError(RuntimeError):
    """A single completion could not be turned into the expected schema."""


class StructuredOutputError(RuntimeError):
    """Structured output could not be produced within the bounded repair budget.

    Carries how many model calls were spent so an arm can charge them against the
    model-call budget before it converts this into a typed failure result.
    """

    def __init__(
        self, message: str, *, calls_used: int, attempts: list["ModelAttempt"]
    ) -> None:
        self.calls_used = calls_used
        self.attempts = attempts
        super().__init__(message)


@dataclass(frozen=True)
class ModelConfig:
    base_url: str
    api_key: str
    model: str
    timeout_s: float = 90.0
    run_timeout_s: float = 3600.0

    @classmethod
    def from_env(cls) -> "ModelConfig":
        base_url = os.environ.get(ENV_BASE_URL, "").strip()
        api_key = os.environ.get(ENV_API_KEY, "").strip()
        model = os.environ.get(ENV_MODEL, "").strip()
        missing = [
            name
            for name, value in (
                (ENV_BASE_URL, base_url),
                (ENV_API_KEY, api_key),
                (ENV_MODEL, model),
            )
            if not value
        ]
        if missing:
            raise ModelConfigError(
                "live mode requires " + ", ".join(missing)
            )
        return cls(
            base_url=base_url,
            api_key=api_key,
            model=model,
            timeout_s=_env_float(ENV_TIMEOUT, 90.0),
            run_timeout_s=_env_float(ENV_RUN_TIMEOUT, 3600.0),
        )


def _env_float(name: str, fallback: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return fallback
    try:
        return float(raw)
    except ValueError:
        return fallback


# ---------------------------------------------------------------------------
# Clients.
# ---------------------------------------------------------------------------


def build_openai_client(config: ModelConfig) -> Any:
    """Construct a raw OpenAI-compatible client. Imported lazily so the optional
    ``live`` dependency stack is only required when a model arm actually runs."""

    from openai import OpenAI  # type: ignore

    return OpenAI(
        base_url=config.base_url,
        api_key=config.api_key,
        timeout=config.timeout_s,
        max_retries=0,
    )


# ---------------------------------------------------------------------------
# Content extraction + structured parsing (pure, unit-tested without a network).
# ---------------------------------------------------------------------------

# A fenced JSON block, if the model wrapped the object in markdown despite the
# instruction not to. json_object enforcement makes this rare, but stripping it
# saves a repair round-trip when it happens.
_FENCE_RE = re.compile(r"^```(?:json)?\s*(?P<body>.*?)\s*```$", re.DOTALL)


def extract_message_content(message: Any) -> str:
    """Return ``message.content`` as text, ignoring ``reasoning_content`` entirely.

    The endpoint returns grammar-enforced JSON in ``content`` and the model's
    chain-of-thought in a separate ``reasoning_content`` field; CoT must never
    reach results, recordings, or artifacts, so this reads ``content`` only.
    """

    if message is None:
        return ""
    content = getattr(message, "content", None)
    if content is None and isinstance(message, dict):
        content = message.get("content")
    if content is None:
        return ""
    return str(content)


def _strip_fence(text: str) -> str:
    stripped = text.strip()
    match = _FENCE_RE.match(stripped)
    return match.group("body").strip() if match else stripped


def _format_validation_error(exc: ValidationError) -> str:
    parts: list[str] = []
    for err in exc.errors()[:5]:
        loc = ".".join(str(part) for part in err.get("loc", ())) or "<root>"
        parts.append(f"{loc}: {err.get('msg', 'invalid')}")
    return "schema validation failed: " + "; ".join(parts)


def parse_structured_content(
    content: str,
    schema: type[BaseModel],
    coerce: Optional[Callable[[Any], tuple[Any, bool]]] = None,
) -> tuple[BaseModel, list[str]]:
    """Parse one completion's ``content`` into ``schema``.

    Returns ``(model, provenance_notes)``. ``coerce`` may reshape the decoded JSON
    before strict validation (e.g. wrap a bare array in its envelope); when it
    reports a change, a ``"coerced_envelope"`` provenance note is added. Raises
    ``StructuredParseError`` on empty content, invalid JSON, or a schema
    violation so the caller can drive a bounded repair retry.
    """

    text = _strip_fence(content or "")
    if not text:
        raise StructuredParseError("model returned empty content")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise StructuredParseError(f"content is not valid JSON ({exc})") from exc
    notes: list[str] = []
    if coerce is not None:
        data, coerced = coerce(data)
        if coerced:
            notes.append("coerced_envelope")
    try:
        value = schema.model_validate(data)
    except ValidationError as exc:
        raise StructuredParseError(_format_validation_error(exc)) from exc
    return value, notes


def coerce_judgments_envelope(data: Any) -> tuple[Any, bool]:
    """Wrap a bare judgments array in its ``{"judgments": [...]}`` envelope.

    A json_object completion sometimes returns the array directly. Wrapping it
    before strict validation keeps the model's substance while enforcing the
    contract; the ``(data, True)`` signal records provenance of the coercion.
    """

    if isinstance(data, list):
        return {"judgments": data}, True
    return data, False


@dataclass
class StructuredResult:
    value: BaseModel
    calls_used: int
    provenance_notes: list[str] = field(default_factory=list)
    attempts: list["ModelAttempt"] = field(default_factory=list)


@dataclass(frozen=True)
class ModelAttempt:
    """Safe per-attempt transport accounting; never includes completion text."""

    attempt: int
    duration_ms: int
    repair: bool
    status: str


def complete_structured(
    chat: ChatFn,
    messages: list[Message],
    schema: type[BaseModel],
    coerce: Optional[Callable[[Any], tuple[Any, bool]]] = None,
    max_repair: int = 1,
    now: Callable[[], float] = time.monotonic,
) -> StructuredResult:
    """Drive one primary completion plus up to ``max_repair`` bounded repairs.

    ``chat`` maps a message list to the completion's ``content`` string (json_object
    enforced upstream). On a parse/validation failure the conversation is extended
    with the invalid response and the validation error, then re-asked to "Return
    ONLY the corrected JSON object." Every attempt (primary + repairs) counts one
    model call. After the repair budget is exhausted, raises ``StructuredOutputError``
    carrying the total calls spent so the arm can charge them and fail typed.
    """

    convo = list(messages)
    calls_used = 0
    attempt_records: list[ModelAttempt] = []
    last_error = "no completion attempted"
    attempts = max_repair + 1
    for attempt in range(attempts):
        started = now()
        try:
            content = chat(convo)
        except Exception as exc:
            calls_used += 1
            attempt_records.append(
                ModelAttempt(
                    attempt=attempt + 1,
                    duration_ms=int(round((now() - started) * 1000)),
                    repair=attempt > 0,
                    status="transport_error",
                )
            )
            raise StructuredOutputError(
                "model completion transport failed",
                calls_used=calls_used,
                attempts=attempt_records,
            ) from exc
        calls_used += 1
        try:
            value, notes = parse_structured_content(content, schema, coerce)
        except StructuredParseError as exc:
            attempt_records.append(
                ModelAttempt(
                    attempt=attempt + 1,
                    duration_ms=int(round((now() - started) * 1000)),
                    repair=attempt > 0,
                    status="parse_error",
                )
            )
            last_error = str(exc)
            if attempt >= attempts - 1:
                break
            convo = convo + [
                {"role": "assistant", "content": content or ""},
                {
                    "role": "user",
                    "content": (
                        f"Your previous response was invalid: {last_error}. "
                        "Return ONLY the corrected JSON object."
                    ),
                },
            ]
            continue
        attempt_records.append(
            ModelAttempt(
                attempt=attempt + 1,
                duration_ms=int(round((now() - started) * 1000)),
                repair=attempt > 0,
                status="success",
            )
        )
        return StructuredResult(
            value=value,
            calls_used=calls_used,
            provenance_notes=notes,
            attempts=attempt_records,
        )
    raise StructuredOutputError(
        last_error, calls_used=calls_used, attempts=attempt_records
    )


def schema_prompt(schema: type[BaseModel]) -> str:
    """A system-prompt fragment embedding the exact expected JSON Schema (field
    names, types, enums) with an instruction to return ONLY that JSON object."""

    return (
        "Return ONLY a single minified JSON object that validates against the JSON "
        "Schema below. Do not include markdown, code fences, comments, prose, or any "
        "chain-of-thought outside the JSON object.\nJSON Schema:\n"
        + json.dumps(schema.model_json_schema(), sort_keys=True)
    )


def make_json_object_chat(client: Any, config: ModelConfig, max_tokens: int) -> ChatFn:
    """Return a ``ChatFn`` that sends one json_object completion (temperature 0,
    max_tokens >= 4096) and returns ``message.content`` (never reasoning_content)."""

    tokens = max(max_tokens, MIN_COMPLETION_TOKENS)

    def chat(messages: list[Message]) -> str:  # pragma: no cover - live only
        response = client.chat.completions.create(
            model=config.model,
            messages=list(messages),
            temperature=0,
            max_tokens=tokens,
            response_format={"type": "json_object"},
        )
        return extract_message_content(response.choices[0].message)

    return chat


# ---------------------------------------------------------------------------
# Startup probe.
# ---------------------------------------------------------------------------


def probe_structured_output(config: ModelConfig) -> dict[str, Any]:
    """Probe once, at live-run start, that json_object enforcement returns a
    parseable JSON object, and separately record whether native tool-calling is
    supported. Returns redacted evidence for the run artifact header. Never raises
    on a transport failure — the transport is always the json_object
    structured-action loop; native support is recorded as evidence only."""

    started = time.monotonic()
    evidence: dict[str, Any] = {
        "transport": "structured_action",
        "jsonMode": False,
        "jsonModeDetail": "",
        "nativeTools": False,
        "nativeToolsDetail": "",
    }
    try:  # pragma: no cover - live only
        client = build_openai_client(config)
    except Exception as exc:  # pragma: no cover - live only
        evidence["jsonModeDetail"] = f"client init failed: {type(exc).__name__}"
        evidence["probeDurationMs"] = int(round((time.monotonic() - started) * 1000))
        return evidence

    try:  # pragma: no cover - live only
        response = client.chat.completions.create(
            model=config.model,
            messages=[
                {
                    "role": "system",
                    "content": 'Return ONLY a JSON object of the form {"ok": true}.',
                },
                {"role": "user", "content": "probe"},
            ],
            temperature=0,
            max_tokens=64,
            response_format={"type": "json_object"},
        )
        content = extract_message_content(response.choices[0].message)
        parsed = json.loads(content)
        ok = isinstance(parsed, dict)
        evidence["jsonMode"] = ok
        evidence["jsonModeDetail"] = (
            "json_object returned a parseable JSON object"
            if ok
            else "json_object content was not a JSON object"
        )
    except Exception as exc:  # pragma: no cover - live only
        evidence["jsonModeDetail"] = f"json_object probe failed: {type(exc).__name__}"

    try:  # pragma: no cover - live only
        response = client.chat.completions.create(
            model=config.model,
            messages=[{"role": "user", "content": "probe: reply with the word ok"}],
            tools=[
                {
                    "type": "function",
                    "function": {
                        "name": "noop",
                        "description": "probe only",
                        "parameters": {"type": "object", "properties": {}},
                    },
                }
            ],
            temperature=0,
            max_tokens=16,
        )
        tool_calls = getattr(response.choices[0].message, "tool_calls", None)
        evidence["nativeTools"] = bool(tool_calls)
        evidence["nativeToolsDetail"] = (
            "native tool_calls returned" if tool_calls else "no tool_calls in response"
        )
    except Exception as exc:  # pragma: no cover - live only
        evidence["nativeToolsDetail"] = f"native tool probe failed: {type(exc).__name__}"

    evidence["probeDurationMs"] = int(round((time.monotonic() - started) * 1000))
    return evidence


def redact(text: Optional[str], api_key: Optional[str]) -> str:
    if not text:
        return ""
    if api_key:
        text = text.replace(api_key, "[REDACTED]")
    return text
