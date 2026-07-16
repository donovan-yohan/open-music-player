"""Corpus + fixture-world loading and validation.

Mirrors the Go eval conventions: a versioned JSON envelope, a 10..15 case bound,
unique ids, and resolvable pools. Loading a corpus fails loudly before any arm
runs so a malformed fixture never masquerades as a passing case.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from ..schemas import (
    CORPUS_SCHEMA_VERSION,
    PROMPT_REVISION,
    Case,
    Corpus,
    FixtureWorld,
)

_FIXTURES_DIR = Path(__file__).resolve().parents[1] / "fixtures"
_CORPUS_PATH = _FIXTURES_DIR / "corpus.v1.json"
_POOLS_DIR = _FIXTURES_DIR / "pools"
_RECORDINGS_DIR = _FIXTURES_DIR / "recorded"

_MIN_CASES = 10
_MAX_CASES = 15


class CorpusError(RuntimeError):
    pass


def fixtures_dir() -> Path:
    return _FIXTURES_DIR


def recordings_dir() -> Path:
    return _RECORDINGS_DIR


def load_corpus(path: Optional[Path] = None) -> Corpus:
    corpus_path = path or _CORPUS_PATH
    try:
        raw = json.loads(corpus_path.read_text())
    except FileNotFoundError as exc:
        raise CorpusError(f"corpus not found at {corpus_path}") from exc
    except json.JSONDecodeError as exc:
        raise CorpusError(f"corpus is not valid JSON: {exc}") from exc
    corpus = Corpus.model_validate(raw)
    validate_corpus(corpus)
    return corpus


def validate_corpus(corpus: Corpus) -> None:
    if corpus.schemaVersion != CORPUS_SCHEMA_VERSION:
        raise CorpusError(f"unsupported corpus schema version {corpus.schemaVersion!r}")
    if not corpus.promptRevision.strip():
        raise CorpusError("corpus promptRevision is required")
    if corpus.promptRevision != PROMPT_REVISION:
        raise CorpusError(
            f"corpus promptRevision {corpus.promptRevision!r} != expected {PROMPT_REVISION!r}"
        )
    if not (_MIN_CASES <= len(corpus.cases) <= _MAX_CASES):
        raise CorpusError(
            f"corpus has {len(corpus.cases)} cases, want {_MIN_CASES} through {_MAX_CASES}"
        )
    seen: set[str] = set()
    for case in corpus.cases:
        if not case.id.strip() or not case.prompt.strip():
            raise CorpusError("case id and prompt are required")
        if case.id in seen:
            raise CorpusError(f"duplicate case id {case.id!r}")
        seen.add(case.id)
        pool_path = _POOLS_DIR / case.poolRef
        if not pool_path.exists():
            raise CorpusError(f"case {case.id!r} references missing pool {case.poolRef!r}")
        # Eagerly validate the pool so a broken world is caught at corpus load.
        load_world(case)
        _validate_expectations(case)


def _validate_expectations(case: Case) -> None:
    expected = case.expected
    if expected.forbiddenInTopK and expected.forbiddenInTopK.k < 1:
        raise CorpusError(f"case {case.id!r} forbiddenInTopK.k must be >= 1")
    if (
        expected.minRecommendations is not None
        and expected.maxRecommendations is not None
        and expected.minRecommendations > expected.maxRecommendations
    ):
        raise CorpusError(f"case {case.id!r} minRecommendations exceeds maxRecommendations")


def load_world(case: Case) -> FixtureWorld:
    pool_path = _POOLS_DIR / case.poolRef
    try:
        raw = json.loads(pool_path.read_text())
    except FileNotFoundError as exc:
        raise CorpusError(f"pool not found at {pool_path}") from exc
    except json.JSONDecodeError as exc:
        raise CorpusError(f"pool {case.poolRef!r} is not valid JSON: {exc}") from exc
    return FixtureWorld.model_validate(raw)


def select_cases(corpus: Corpus, ids: Optional[list[str]]) -> list[Case]:
    if not ids:
        return list(corpus.cases)
    wanted = {i.strip() for i in ids if i.strip()}
    known = {case.id for case in corpus.cases}
    unknown = wanted - known
    if unknown:
        raise CorpusError(f"unknown case id(s): {', '.join(sorted(unknown))}")
    return [case for case in corpus.cases if case.id in wanted]
