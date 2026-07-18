"""Deterministic, artifact-only redaction for evaluator output.

The evaluator never needs raw provider URLs, model text, or credentials.  This
module is deliberately applied immediately before every JSONL write as a final
backstop for future fields and typed failure details.
"""

from __future__ import annotations

import re
from typing import Any

REDACTED = "[REDACTED]"

_URL = re.compile(r"(?i)\b(?:https?|ftp)://[^\s\"'<>\\]+")
_BEARER = re.compile(r"(?i)\bbearer\s+[^\s\"'\\]+")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b")
_API_KEY = re.compile(
    r"(?i)\b(?:sk|fc)-[A-Za-z0-9_-]{8,}|\b(?:api[_-]?key|firecrawl[_-]?key)\s*[:=]\s*[^\s\"'\\]+"
)
_NAMED_TOKEN = re.compile(
    r"(?i)\b(?:capability|service[_-]?token|access[_-]?token|refresh[_-]?token|token|secret|password)\s*[:=]\s*[^\s\"'\\]+"
)
_SENSITIVE_KEY = re.compile(
    r"(?i)(?:authorization|bearer|jwt|token|secret|password|api[_-]?key|firecrawl|capability|service)"
)


def redact_text(value: str, literals: tuple[str, ...] = ()) -> str:
    """Replace known sensitive forms without attempting to parse their value."""

    for literal in literals:
        if len(literal) >= 8:
            value = value.replace(literal, REDACTED)
    for pattern in (_URL, _BEARER, _JWT, _API_KEY, _NAMED_TOKEN):
        value = pattern.sub(REDACTED, value)
    return value


def redact_value(value: Any, literals: tuple[str, ...] = ()) -> Any:
    """Return an artifact-safe copy, preserving only non-sensitive structure."""

    if isinstance(value, str):
        return redact_text(value, literals)
    if isinstance(value, list):
        return [redact_value(item, literals) for item in value]
    if isinstance(value, tuple):
        return [redact_value(item, literals) for item in value]
    if isinstance(value, dict):
        return {
            key: REDACTED if _SENSITIVE_KEY.search(str(key)) else redact_value(item, literals)
            for key, item in value.items()
        }
    return value
