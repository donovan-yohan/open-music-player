from __future__ import annotations

import pytest

from candidate_assembly.evalrunner import corpus as corpus_mod
from candidate_assembly.schemas import Corpus


def test_real_corpus_loads_and_is_bounded():
    corpus = corpus_mod.load_corpus()
    assert 10 <= len(corpus.cases) <= 15
    ids = [c.id for c in corpus.cases]
    assert len(ids) == len(set(ids)), "case ids must be unique"


def test_every_case_pool_resolves_and_expectations_valid():
    corpus = corpus_mod.load_corpus()
    for case in corpus.cases:
        world = corpus_mod.load_world(case)
        assert world.candidates, f"{case.id} has an empty pool"
        # expectation candidate references must exist in the pool.
        pool_ids = world.candidate_ids()
        if case.expected.topCandidateId:
            assert case.expected.topCandidateId in pool_ids
        for candidate_id in case.expected.requiredWarnings:
            assert candidate_id in pool_ids


def test_bounds_rejected():
    corpus = corpus_mod.load_corpus()
    corpus.cases = corpus.cases[:9]
    with pytest.raises(corpus_mod.CorpusError):
        corpus_mod.validate_corpus(corpus)


def test_duplicate_ids_rejected():
    corpus = corpus_mod.load_corpus()
    corpus.cases = corpus.cases + [corpus.cases[0]]
    with pytest.raises(corpus_mod.CorpusError):
        corpus_mod.validate_corpus(corpus)


def test_prompt_revision_mismatch_rejected():
    corpus = corpus_mod.load_corpus()
    corpus.promptRevision = "some-other-revision"
    with pytest.raises(corpus_mod.CorpusError):
        corpus_mod.validate_corpus(corpus)


def test_select_cases_unknown_id_rejected():
    corpus = corpus_mod.load_corpus()
    with pytest.raises(corpus_mod.CorpusError):
        corpus_mod.select_cases(corpus, ["not-a-real-case"])


def test_select_cases_subset():
    corpus = corpus_mod.load_corpus()
    first = corpus.cases[0].id
    selected = corpus_mod.select_cases(corpus, [first])
    assert [c.id for c in selected] == [first]
