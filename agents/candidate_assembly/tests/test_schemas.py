from __future__ import annotations

import pytest
from pydantic import ValidationError

from candidate_assembly.schemas import (
    ASSEMBLY_SCHEMA_VERSION,
    AssemblyResult,
    RawCandidate,
    Recommendation,
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
