from __future__ import annotations

import pytest
from pydantic import ValidationError

from candidate_assembly.schemas import (
    ASSEMBLY_SCHEMA_VERSION,
    AssemblyResult,
    DeterministicBaseline,
    ProgressEvent,
    RawCandidate,
    Recommendation,
    SafeEvidenceRef,
)
from conftest import make_result


def test_assembly_result_round_trips():
    result = make_result()
    dumped = result.model_dump(exclude_none=True)
    restored = AssemblyResult.model_validate(dumped)
    assert restored == result
    assert restored.schemaVersion == ASSEMBLY_SCHEMA_VERSION


def test_raw_candidate_mirrors_go_shape():
    candidate = RawCandidate.model_validate(
        {
            "candidateId": "youtube:x",
            "provider": "youtube",
            "sourceUrl": "https://youtu.be/x",
            "title": "Artist - Song",
            "downloadable": True,
            "playable": False,
            "explicit": None,
            "durationMs": 210000,
            "metadata": {"discoverySurface": "youtube_search"},
        }
    )
    assert candidate.explicit is None
    assert candidate.metadata["discoverySurface"] == "youtube_search"


def test_unknown_field_is_rejected():
    with pytest.raises(ValidationError):
        RawCandidate.model_validate(
            {
                "candidateId": "youtube:x",
                "provider": "youtube",
                "sourceUrl": "https://youtu.be/x",
                "title": "Artist - Song",
                "downloadable": True,
                "surpriseField": "nope",
            }
        )


def test_recommendation_confidence_bounds():
    with pytest.raises(ValidationError):
        Recommendation.model_validate(
            {"candidateId": "youtube:a", "rank": 1, "confidence": 1.5, "rationale": "x"}
        )
    with pytest.raises(ValidationError):
        Recommendation.model_validate(
            {"candidateId": "youtube:a", "rank": 0, "confidence": 0.5, "rationale": "x"}
        )


def test_warning_enum_is_constrained():
    with pytest.raises(ValidationError):
        Recommendation.model_validate(
            {
                "candidateId": "youtube:a",
                "rank": 1,
                "confidence": 0.5,
                "rationale": "x",
                "warnings": ["not_a_real_warning"],
            }
        )


def test_schema_version_is_pinned():
    with pytest.raises(ValidationError):
        AssemblyResult.model_validate(
            {
                **make_result().model_dump(exclude_none=True),
                "schemaVersion": "omp.agent-search.assembly.v2",
            }
        )


@pytest.mark.parametrize(
    "unsafe",
    [
        "https://example.test/candidate",
        "sk-abcdef123456",
        "Bearer-secret",
        "candidate id with spaces",
        "x" * 129,
    ],
)
def test_progress_candidate_and_evidence_refs_reject_unsafe_values(unsafe):
    with pytest.raises(ValidationError):
        DeterministicBaseline(elapsedMs=1, validationMs=1, candidateIds=[unsafe])
    with pytest.raises(ValidationError):
        ProgressEvent(
            sequence=1, kind="baseline", phase="baseline_validated", elapsedMs=1,
            status="passed", resultCount=1,
            candidateIds=[unsafe],
        )
    with pytest.raises(ValidationError):
        SafeEvidenceRef(tool="search_sources", ref=unsafe)


def test_progress_candidate_and_evidence_refs_accept_fixture_identifiers():
    baseline = DeterministicBaseline(
        elapsedMs=1,
        validationMs=1,
        candidateIds=["youtube:abc_123"],
        evidenceRefs=[SafeEvidenceRef(tool="search_sources", ref="youtube:abc_123")],
    )
    assert baseline.candidateIds == ["youtube:abc_123"]


@pytest.mark.parametrize(
    "payload",
    [
        {"kind": "lifecycle", "phase": "started"},
        {
            "kind": "lifecycle", "phase": "model_call", "attempt": 1,
            "repair": False, "status": "parse_error",
        },
        {"kind": "lifecycle", "phase": "finalizing", "status": "success"},
        {"kind": "lifecycle", "phase": "failed", "status": "failed"},
        {
            "kind": "tool", "phase": "tool_completed", "tool": "search_sources",
            "resultCount": 2,
        },
        {
            "kind": "baseline", "phase": "baseline_validated", "status": "passed",
            "resultCount": 1, "candidateIds": ["youtube:abc_123"],
        },
        {"kind": "baseline", "phase": "failed", "status": "failed", "resultCount": 0},
        {
            "kind": "validated_result", "phase": "validated", "status": "passed",
            "resultCount": 1, "candidateIds": ["youtube:abc_123"],
        },
        {
            "kind": "validated_result", "phase": "validated", "status": "failed",
            "resultCount": 0,
        },
    ],
)
def test_progress_event_accepts_valid_kind_phase_metadata_matrix(payload):
    event = ProgressEvent(sequence=1, elapsedMs=0, **payload)
    assert event.kind == payload["kind"]


@pytest.mark.parametrize(
    "payload",
    [
        {"kind": "lifecycle", "phase": "tool_completed", "tool": "search_sources", "resultCount": 1},
        {"kind": "lifecycle", "phase": "model_call", "status": "success"},
        {"kind": "lifecycle", "phase": "model_call", "attempt": 1},
        {"kind": "lifecycle", "phase": "started", "status": "success"},
        {"kind": "lifecycle", "phase": "failed", "status": "failed", "resultCount": 0},
        {"kind": "tool", "phase": "tool_completed", "resultCount": 1},
        {"kind": "tool", "phase": "tool_completed", "tool": "search_sources"},
        {
            "kind": "tool", "phase": "tool_completed", "tool": "search_sources",
            "resultCount": 1, "status": "success",
        },
        {"kind": "baseline", "phase": "validated", "status": "passed", "resultCount": 1},
        {"kind": "baseline", "phase": "baseline_validated", "resultCount": 1},
        {"kind": "baseline", "phase": "baseline_validated", "status": "passed"},
        {
            "kind": "baseline", "phase": "failed", "status": "failed", "resultCount": 1,
            "candidateIds": ["youtube:abc_123"],
        },
        {"kind": "validated_result", "phase": "validated", "resultCount": 1},
        {"kind": "validated_result", "phase": "validated", "status": "passed"},
        {
            "kind": "validated_result", "phase": "validated", "status": "passed",
            "resultCount": 1, "attempt": 1,
        },
    ],
)
def test_progress_event_rejects_invalid_kind_phase_metadata_matrix(payload):
    with pytest.raises(ValidationError):
        ProgressEvent(sequence=1, elapsedMs=0, **payload)
