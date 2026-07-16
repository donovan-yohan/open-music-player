from __future__ import annotations

from candidate_assembly.budgets import Budget
from candidate_assembly.fixture_tools import (
    ToolBox,
    normalize_tokens,
    rank_candidates,
)
from conftest import make_candidate, make_world


def test_normalize_strips_punctuation_and_diacritics():
    assert normalize_tokens("Björk — Jóga (Official Audio)!") == [
        "bjork",
        "joga",
        "official",
        "audio",
    ]
    assert normalize_tokens("") == []


def test_retrieval_is_deterministic():
    candidates = [
        make_candidate("youtube:a", title="Ninajirachi - iPod Touch"),
        make_candidate("youtube:b", title="Ninajirachi - Rukus"),
        make_candidate("youtube:c", title="Unrelated Artist - Other Song"),
    ]
    first = rank_candidates("ninajirachi ipod touch", candidates, 10)
    second = rank_candidates("ninajirachi ipod touch", candidates, 10)
    assert [c.candidateId for c in first] == [c.candidateId for c in second]


def test_title_match_outranks_metadata_only_match():
    on_title = make_candidate("youtube:title", title="Charli xcx - Von dutch")
    metadata_only = make_candidate(
        "youtube:meta",
        title="Some Playlist Mix",
        metadata={"description": "includes charli xcx von dutch and more"},
    )
    ranked = rank_candidates("charli xcx von dutch", [metadata_only, on_title], 10)
    assert ranked[0].candidateId == "youtube:title"


def test_unrelated_candidate_is_filtered_out():
    candidates = [
        make_candidate("youtube:hit", title="Radiohead - Creep"),
        make_candidate("youtube:noise", title="Cooking Pasta Tutorial"),
    ]
    ranked = rank_candidates("radiohead creep", candidates, 10)
    assert [c.candidateId for c in ranked] == ["youtube:hit"]


def test_toolbox_filters_by_provider_and_records_allowlist():
    world = make_world(
        candidates=[
            make_candidate("youtube:a", title="Artist - Song"),
            make_candidate("soundcloud:b", title="Artist - Song"),
        ]
    )
    box = ToolBox(world, Budget.default(), now=lambda: 0.0)
    results = box.search_sources("artist song", providers=["soundcloud"], limit=10)
    assert [c.candidateId for c in results] == ["soundcloud:b"]
    assert box.allowlist == {"soundcloud:b"}
    assert box.tool_calls == 1
    assert len(box.trace) == 1


def test_toolbox_clamps_limit_to_ceiling():
    world = make_world(
        candidates=[make_candidate(f"youtube:{i}", title="Artist - Song") for i in range(40)]
    )
    box = ToolBox(world, Budget.default(), now=lambda: 0.0)
    results = box.search_sources("artist song", limit=999)
    assert len(results) <= 25
