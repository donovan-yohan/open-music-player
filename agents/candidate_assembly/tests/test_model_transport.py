"""Unit tests for the json_object transport core: content extraction (ignoring
reasoning_content), defensive parsing, envelope coercion, and the bounded
repair-retry driver. All network-free — ``complete_structured`` takes a fake
``chat`` callable, and the parse/coerce/extract helpers are pure.
"""

from __future__ import annotations

import pytest
from pydantic import BaseModel, ConfigDict, Field

from candidate_assembly.model_client import (
    StructuredOutputError,
    StructuredParseError,
    coerce_judgments_envelope,
    complete_structured,
    extract_message_content,
    parse_structured_content,
    schema_prompt,
)


class _Item(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    value: int


class _Envelope(BaseModel):
    model_config = ConfigDict(extra="forbid")
    items: list[_Item] = Field(default_factory=list)


def _coerce_items(data):
    if isinstance(data, list):
        return {"items": data}, True
    return data, False


class _Msg:
    def __init__(self, content, reasoning_content=None):
        self.content = content
        self.reasoning_content = reasoning_content


class FakeChat:
    """Returns canned completion strings and records the messages of each call."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls: list[list[dict]] = []

    def __call__(self, messages):
        self.calls.append([dict(m) for m in messages])
        return self._responses.pop(0)


# -- content extraction (reasoning_content must never be read) ---------------


def test_extract_ignores_reasoning_content():
    msg = _Msg(content='{"ok": true}', reasoning_content="a long chain of thought")
    assert extract_message_content(msg) == '{"ok": true}'


def test_extract_none_content_returns_empty():
    msg = _Msg(content=None, reasoning_content="thinking but no answer")
    assert extract_message_content(msg) == ""


def test_extract_from_dict_message():
    assert extract_message_content({"content": "x"}) == "x"


def test_extract_none_message_returns_empty():
    assert extract_message_content(None) == ""


# -- defensive parsing -------------------------------------------------------


def test_parse_valid_content():
    value, notes = parse_structured_content('{"name": "a", "value": 1}', _Item)
    assert notes == []
    assert value.name == "a" and value.value == 1


def test_parse_empty_content_raises():
    with pytest.raises(StructuredParseError):
        parse_structured_content("   ", _Item)


def test_parse_invalid_json_raises():
    with pytest.raises(StructuredParseError):
        parse_structured_content("not json at all", _Item)


def test_parse_schema_violation_raises():
    with pytest.raises(StructuredParseError):
        parse_structured_content('{"name": "a"}', _Item)  # missing required value


def test_parse_rejects_unknown_field():
    with pytest.raises(StructuredParseError):
        parse_structured_content('{"name": "a", "value": 1, "extra": true}', _Item)


def test_parse_strips_code_fence():
    value, _ = parse_structured_content('```json\n{"name": "a", "value": 2}\n```', _Item)
    assert value.value == 2


# -- envelope coercion -------------------------------------------------------


def test_coerce_judgments_envelope_wraps_bare_array():
    wrapped, coerced = coerce_judgments_envelope([{"candidateId": "x"}])
    assert coerced is True
    assert wrapped == {"judgments": [{"candidateId": "x"}]}


def test_coerce_judgments_envelope_passthrough_dict():
    data = {"judgments": []}
    out, coerced = coerce_judgments_envelope(data)
    assert coerced is False
    assert out is data


def test_parse_coerces_bare_array_and_records_note():
    value, notes = parse_structured_content(
        '[{"name": "a", "value": 1}]', _Envelope, _coerce_items
    )
    assert notes == ["coerced_envelope"]
    assert value.items[0].name == "a"


def test_parse_no_note_when_coerce_makes_no_change():
    value, notes = parse_structured_content(
        '{"items": [{"name": "a", "value": 1}]}', _Envelope, _coerce_items
    )
    assert notes == []
    assert value.items[0].value == 1


# -- bounded repair-retry driver ---------------------------------------------


def test_complete_structured_succeeds_first_try():
    chat = FakeChat(['{"name": "a", "value": 1}'])
    result = complete_structured(chat, [{"role": "user", "content": "go"}], _Item)
    assert result.calls_used == 1
    assert result.value.name == "a"
    assert result.provenance_notes == []
    assert len(chat.calls) == 1


def test_complete_structured_repairs_once_then_succeeds():
    chat = FakeChat(["not json", '{"name": "a", "value": 1}'])
    result = complete_structured(chat, [{"role": "user", "content": "go"}], _Item)
    assert result.calls_used == 2
    assert len(chat.calls) == 2
    # The repair turn echoes the invalid response and re-asks for corrected JSON.
    repair_turn = chat.calls[1]
    assert any(m.get("content") == "not json" for m in repair_turn)
    last = repair_turn[-1]
    assert last["role"] == "user"
    assert "Return ONLY the corrected JSON object." in last["content"]
    assert "invalid" in last["content"]


def test_complete_structured_raises_after_repair_exhausted():
    chat = FakeChat(["garbage", "still garbage"])
    with pytest.raises(StructuredOutputError) as excinfo:
        complete_structured(chat, [{"role": "user", "content": "go"}], _Item)
    assert excinfo.value.calls_used == 2
    assert len(chat.calls) == 2


def test_complete_structured_carries_coercion_note():
    chat = FakeChat(['[{"name": "a", "value": 1}]'])
    result = complete_structured(
        chat, [{"role": "user", "content": "go"}], _Envelope, coerce=_coerce_items
    )
    assert result.calls_used == 1
    assert result.provenance_notes == ["coerced_envelope"]


def test_complete_structured_records_attempt_durations_and_repair_status():
    chat = FakeChat(["bad", '{"name": "a", "value": 1}'])
    ticks = iter([10.0, 10.125, 11.0, 11.25])
    result = complete_structured(
        chat, [{"role": "user", "content": "go"}], _Item, now=lambda: next(ticks)
    )
    assert [(a.duration_ms, a.repair, a.status) for a in result.attempts] == [
        (125, False, "parse_error"),
        (250, True, "success"),
    ]


def test_complete_structured_reports_primary_attempt_before_slow_repair():
    clock = [0.0]
    delivered = []

    def now():
        return clock[0]

    def on_attempt(attempt):
        delivered.append((attempt.status, attempt.repair, clock[0]))

    class SlowRepairChat:
        calls = 0

        def __call__(self, _messages):
            self.calls += 1
            if self.calls == 1:
                clock[0] = 0.125
                return "invalid primary completion"
            assert delivered == [("parse_error", False, 0.125)]
            clock[0] = 5.125
            return '{"name": "a", "value": 1}'

    result = complete_structured(
        SlowRepairChat(),
        [{"role": "user", "content": "go"}],
        _Item,
        now=now,
        attempt_callback=on_attempt,
    )

    assert delivered == [
        ("parse_error", False, 0.125),
        ("success", True, 5.125),
    ]
    assert [attempt.status for attempt in result.attempts] == ["parse_error", "success"]


def test_complete_structured_records_safe_transport_error():
    def fail(_messages):
        raise RuntimeError("Bearer secret-do-not-serialize")

    ticks = iter([1.0, 1.5])
    with pytest.raises(StructuredOutputError) as excinfo:
        complete_structured(fail, [{"role": "user", "content": "go"}], _Item, now=lambda: next(ticks))
    assert str(excinfo.value) == "model completion transport failed"
    assert [(a.duration_ms, a.repair, a.status) for a in excinfo.value.attempts] == [
        (500, False, "transport_error")
    ]


def test_complete_structured_does_not_mutate_input_messages():
    messages = [{"role": "user", "content": "go"}]
    chat = FakeChat(["bad", '{"name": "a", "value": 1}'])
    complete_structured(chat, messages, _Item)
    assert messages == [{"role": "user", "content": "go"}]


# -- schema prompt -----------------------------------------------------------


def test_schema_prompt_embeds_fields_and_instruction():
    prompt = schema_prompt(_Item)
    assert "Return ONLY" in prompt
    assert "name" in prompt and "value" in prompt
