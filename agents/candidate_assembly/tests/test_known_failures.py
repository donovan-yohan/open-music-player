from __future__ import annotations

import json
import shutil

import pytest

from candidate_assembly.evalrunner import corpus as corpus_mod
from candidate_assembly.evalrunner import graders as g
from candidate_assembly.evalrunner import known_failures as kf
from candidate_assembly.evalrunner import runner as runner_mod
from candidate_assembly.evalrunner.cli import main as cli_main
from candidate_assembly.schemas import (
    KNOWN_FAILURES_SCHEMA_VERSION,
    KnownFailure,
    KnownFailuresManifest,
)

_ALL_GRADER_NAMES = (g.SCHEMA, g.GROUNDING, g.SAFETY, g.EXPECTED, g.CLAIMS, g.BUDGET)


def _outcome(case_id, arm, failing=(), *, status=runner_mod.STATUS_GRADED):
    failing = set(failing)
    grades = [g.GradeResult(name, name not in failing) for name in _ALL_GRADER_NAMES]
    return runner_mod.CaseArmOutcome(
        case_id=case_id,
        arm=arm,
        status=status,
        passed=not failing,
        latency_ms=0,
        grades=grades,
    )


def _manifest(*entries: KnownFailure) -> KnownFailuresManifest:
    return KnownFailuresManifest(entries=list(entries))


# ---------------------------------------------------------------------------
# Manifest loading + validation.
# ---------------------------------------------------------------------------


def test_real_manifest_loads_and_validates_against_corpus():
    corpus = corpus_mod.load_corpus()
    manifest = kf.load_manifest()
    kf.validate_manifest(manifest, corpus)  # must not raise
    assert manifest.schemaVersion == KNOWN_FAILURES_SCHEMA_VERSION
    # The agent-search-system-prompt-v2 rewrite closed every deep_agent gap, so the
    # manifest now pins zero intended failures and all three arms pass replay. The
    # exact-match gate machinery stays exercised below; any future pinned entry must
    # still carry a non-empty reason and at least one grader.
    assert manifest.entries == []
    for entry in manifest.entries:
        assert entry.reason.strip()
        assert entry.graders


def test_validate_rejects_wrong_schema_version():
    corpus = corpus_mod.load_corpus()
    manifest = kf.load_manifest()
    manifest.schemaVersion = "omp.agent-search.eval.known-failures.v2"
    with pytest.raises(kf.KnownFailuresError):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_unknown_case_id():
    corpus = corpus_mod.load_corpus()
    manifest = _manifest(
        KnownFailure(caseId="not-a-case", arm="deep_agent", graders=["grounding"], reason="x")
    )
    with pytest.raises(kf.KnownFailuresError, match="unknown case id"):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_unknown_arm():
    corpus = corpus_mod.load_corpus()
    case_id = corpus.cases[0].id
    manifest = _manifest(
        KnownFailure(caseId=case_id, arm="ghost_arm", graders=["grounding"], reason="x")
    )
    with pytest.raises(kf.KnownFailuresError, match="unknown arm"):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_duplicate_entries():
    corpus = corpus_mod.load_corpus()
    case_id = corpus.cases[0].id
    entry = KnownFailure(caseId=case_id, arm="deep_agent", graders=["grounding"], reason="x")
    manifest = _manifest(entry, entry)
    with pytest.raises(kf.KnownFailuresError, match="duplicate"):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_empty_reason():
    corpus = corpus_mod.load_corpus()
    case_id = corpus.cases[0].id
    manifest = _manifest(
        KnownFailure(caseId=case_id, arm="deep_agent", graders=["grounding"], reason="   ")
    )
    with pytest.raises(kf.KnownFailuresError, match="empty reason"):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_empty_graders():
    corpus = corpus_mod.load_corpus()
    case_id = corpus.cases[0].id
    manifest = _manifest(
        KnownFailure(caseId=case_id, arm="deep_agent", graders=[], reason="x")
    )
    with pytest.raises(kf.KnownFailuresError, match="no graders"):
        kf.validate_manifest(manifest, corpus)


def test_validate_rejects_safety_grader_pinned():
    corpus = corpus_mod.load_corpus()
    case_id = corpus.cases[0].id
    manifest = _manifest(
        KnownFailure(caseId=case_id, arm="deep_agent", graders=["safety"], reason="x")
    )
    with pytest.raises(kf.KnownFailuresError, match="safety"):
        kf.validate_manifest(manifest, corpus)


def test_load_manifest_rejects_malformed_json(tmp_path):
    bad = tmp_path / "kf.json"
    bad.write_text("{ not json")
    with pytest.raises(kf.KnownFailuresError):
        kf.load_manifest(bad)


def test_load_manifest_rejects_unknown_field(tmp_path):
    bad = tmp_path / "kf.json"
    bad.write_text(
        json.dumps(
            {
                "schemaVersion": KNOWN_FAILURES_SCHEMA_VERSION,
                "entries": [],
                "surprise": True,
            }
        )
    )
    with pytest.raises(kf.KnownFailuresError):
        kf.load_manifest(bad)


# ---------------------------------------------------------------------------
# Comparison semantics.
# ---------------------------------------------------------------------------


def test_compare_exact_match_passes():
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["grounding"], reason="x"),
        KnownFailure(caseId="c2", arm="deep_agent", graders=["expected"], reason="y"),
    )
    outcomes = [
        _outcome("c1", "deep_agent", failing=["grounding"]),
        _outcome("c2", "deep_agent", failing=["expected"]),
        _outcome("c1", "deterministic"),  # passes cleanly
    ]
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is True
    assert comparison.matched_count == 2
    assert comparison.deltas == []


def test_compare_unexpected_failure_fails():
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["grounding"], reason="x")
    )
    outcomes = [
        _outcome("c1", "deep_agent", failing=["grounding"]),
        _outcome("c3", "deep_agent", failing=["expected"]),  # not pinned
    ]
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is False
    kinds = {(d.kind, d.case_id) for d in comparison.deltas}
    assert ("unexpected", "c3") in kinds


def test_compare_stale_entry_fails():
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["grounding"], reason="x"),
        KnownFailure(caseId="c2", arm="deep_agent", graders=["expected"], reason="y"),
    )
    outcomes = [
        _outcome("c1", "deep_agent", failing=["grounding"]),
        _outcome("c2", "deep_agent"),  # now passes -> stale entry
    ]
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is False
    assert any(d.kind == "stale" and d.case_id == "c2" for d in comparison.deltas)


def test_compare_grader_set_mismatch_fails():
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["grounding"], reason="x")
    )
    outcomes = [_outcome("c1", "deep_agent", failing=["grounding", "budget"])]
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is False
    assert any(d.kind == "grader_mismatch" for d in comparison.deltas)


def test_compare_safety_never_excused():
    # A manifest entry that (illegally) tries to excuse a safety failure with an
    # exact grader-set match must still fail: safety is never pinnable.
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["safety"], reason="sneaky")
    )
    outcomes = [_outcome("c1", "deep_agent", failing=["safety"])]
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is False
    assert comparison.matched_count == 0
    assert any(d.kind == "safety" and d.case_id == "c1" for d in comparison.deltas)


def test_compare_scopes_entries_to_graded_outcomes():
    # An entry whose (caseId, arm) was never graded in this run is neither a
    # stale delta nor a match — it is simply out of scope.
    manifest = _manifest(
        KnownFailure(caseId="c1", arm="deep_agent", graders=["grounding"], reason="x")
    )
    outcomes = [_outcome("c9", "deterministic")]  # unrelated, passes
    comparison = kf.compare(outcomes, manifest)
    assert comparison.matched is True
    assert comparison.matched_count == 0


# ---------------------------------------------------------------------------
# CLI integration (the real replay gate).
# ---------------------------------------------------------------------------


@pytest.mark.skipif(
    shutil.which("go") is None, reason="Go toolchain required for the deterministic arm"
)
def test_cli_replay_matches_manifest_and_exits_zero(tmp_path):
    out = tmp_path / "run.jsonl"
    assert cli_main(["--mode", "replay", "--output", str(out)]) == 0
