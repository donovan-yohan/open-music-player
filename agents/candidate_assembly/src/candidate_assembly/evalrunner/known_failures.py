"""Pinned known-failures manifest — the replay-only exact-match gate.

The ``deep_agent`` prototype has intended, visible grader failures (issue #265
findings). The replay CI gate must stay green AND stay meaningful: rather than
hiding those failures or loosening the pass-rate bar, we pin the exact set of
``(caseId, arm)`` outcomes and their failing-grader sets in a versioned
manifest. Replay exits 0 iff the actual failing set matches the manifest
exactly. Any unexpected failure, any expected-but-now-passing entry (a stale
manifest), or any failing-grader-set mismatch fails the gate and lists the
deltas.

Safety-grader failures may NEVER be excused by the manifest: a safety failure
always fails the run, even if some entry's grader set would otherwise match.
Live mode ignores the manifest entirely (its min-pass-rate stays advisory).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Iterable, Optional

from pydantic import ValidationError

from ..orchestrator import ALL_ARMS
from ..schemas import (
    KNOWN_FAILURES_SCHEMA_VERSION,
    Corpus,
    KnownFailuresManifest,
)
from . import graders as graders_mod

if TYPE_CHECKING:  # pragma: no cover - typing only, avoids an import cycle
    from .runner import CaseArmOutcome

_FIXTURES_DIR = Path(__file__).resolve().parents[1] / "fixtures"
_MANIFEST_PATH = _FIXTURES_DIR / "known_failures.v1.json"


class KnownFailuresError(RuntimeError):
    """Raised on a malformed or internally inconsistent manifest — a
    corpus-load-style hard error that aborts the run before any gate verdict."""


def manifest_path() -> Path:
    return _MANIFEST_PATH


def load_manifest(path: Optional[Path] = None) -> KnownFailuresManifest:
    manifest_file = path or _MANIFEST_PATH
    try:
        raw = json.loads(manifest_file.read_text())
    except FileNotFoundError as exc:
        raise KnownFailuresError(f"known-failures manifest not found at {manifest_file}") from exc
    except json.JSONDecodeError as exc:
        raise KnownFailuresError(f"known-failures manifest is not valid JSON: {exc}") from exc
    try:
        return KnownFailuresManifest.model_validate(raw)
    except ValidationError as exc:
        raise KnownFailuresError(f"known-failures manifest is malformed: {exc}") from exc


def validate_manifest(
    manifest: KnownFailuresManifest,
    corpus: Corpus,
    arms: Optional[Iterable[str]] = None,
) -> None:
    """Structural validation: correct schema version, every entry references a
    real corpus case id + real arm, no duplicate ``(caseId, arm)`` entries,
    non-empty grader lists that reference real graders (never ``safety``), and a
    non-empty reason. Fails loudly like corpus loading."""

    if manifest.schemaVersion != KNOWN_FAILURES_SCHEMA_VERSION:
        raise KnownFailuresError(
            f"unsupported known-failures schema version {manifest.schemaVersion!r}"
        )
    known_case_ids = {case.id for case in corpus.cases}
    known_arms = set(arms) if arms is not None else set(ALL_ARMS)
    seen: set[tuple[str, str]] = set()
    for entry in manifest.entries:
        label = f"{entry.caseId!r}/{entry.arm!r}"
        if entry.caseId not in known_case_ids:
            raise KnownFailuresError(
                f"known-failures entry {label} references unknown case id {entry.caseId!r}"
            )
        if entry.arm not in known_arms:
            raise KnownFailuresError(
                f"known-failures entry {label} references unknown arm {entry.arm!r}"
            )
        key = (entry.caseId, entry.arm)
        if key in seen:
            raise KnownFailuresError(f"duplicate known-failures entry for {label}")
        seen.add(key)
        if not entry.graders:
            raise KnownFailuresError(f"known-failures entry {label} lists no graders")
        if len(set(entry.graders)) != len(entry.graders):
            raise KnownFailuresError(f"known-failures entry {label} has duplicate graders")
        for grader in entry.graders:
            if grader == graders_mod.SAFETY:
                raise KnownFailuresError(
                    f"known-failures entry {label} pins the safety grader; "
                    "safety failures may never be excused"
                )
            if grader not in graders_mod.ALL_GRADER_NAMES:
                raise KnownFailuresError(
                    f"known-failures entry {label} references unknown grader {grader!r}"
                )
        if not entry.reason.strip():
            raise KnownFailuresError(f"known-failures entry {label} has an empty reason")


@dataclass(frozen=True)
class Delta:
    """One discrepancy between the actual replay failures and the manifest."""

    kind: str  # unexpected | stale | grader_mismatch | safety
    case_id: str
    arm: str
    expected: frozenset[str] = frozenset()
    actual: frozenset[str] = frozenset()

    def render(self) -> str:
        exp = "{" + ",".join(sorted(self.expected)) + "}"
        act = "{" + ",".join(sorted(self.actual)) + "}"
        if self.kind == "unexpected":
            return f"  UNEXPECTED case={self.case_id} arm={self.arm} failing={act} (not in manifest)"
        if self.kind == "stale":
            return (
                f"  STALE      case={self.case_id} arm={self.arm} expected={exp} "
                "now passing (remove from manifest)"
            )
        if self.kind == "grader_mismatch":
            return (
                f"  MISMATCH   case={self.case_id} arm={self.arm} "
                f"expected={exp} actual={act}"
            )
        return (
            f"  SAFETY     case={self.case_id} arm={self.arm} failing={act} "
            "(safety failures may never be pinned)"
        )


@dataclass
class KnownFailuresComparison:
    matched: bool
    matched_count: int
    deltas: list[Delta] = field(default_factory=list)

    def delta_lines(self) -> list[str]:
        return ["known-failures gate deltas:"] + [d.render() for d in self.deltas]


def compare(
    outcomes: list["CaseArmOutcome"],
    manifest: KnownFailuresManifest,
) -> KnownFailuresComparison:
    """Compare the actual failing outcomes against the manifest.

    Only *graded* outcomes are considered, and manifest entries are scoped to the
    ``(caseId, arm)`` pairs that were actually graded in this run — so a subset
    run (e.g. ``--arm deterministic``) neither trips over nor is excused by an
    entry it never exercised. Within that scope the match must be exact.
    """

    graded_keys: set[tuple[str, str]] = set()
    actual: dict[tuple[str, str], frozenset[str]] = {}
    safety_keys: set[tuple[str, str]] = set()
    for outcome in outcomes:
        if not outcome.graded:
            continue
        key = (outcome.case_id, outcome.arm)
        graded_keys.add(key)
        if outcome.passed:
            continue
        failing = frozenset(g.name for g in outcome.grades if not g.passed)
        actual[key] = failing
        if graders_mod.SAFETY in failing:
            safety_keys.add(key)

    expected = {(e.caseId, e.arm): frozenset(e.graders) for e in manifest.entries}
    applicable = {key: graders for key, graders in expected.items() if key in graded_keys}

    deltas: list[Delta] = []
    for key in sorted(actual):
        case_id, arm = key
        if key in safety_keys:
            # A safety failure is never excusable, even by an exact-set match.
            deltas.append(Delta("safety", case_id, arm, applicable.get(key, frozenset()), actual[key]))
            continue
        if key not in applicable:
            deltas.append(Delta("unexpected", case_id, arm, frozenset(), actual[key]))
        elif applicable[key] != actual[key]:
            deltas.append(Delta("grader_mismatch", case_id, arm, applicable[key], actual[key]))
    for key in sorted(applicable):
        if key not in actual:
            case_id, arm = key
            deltas.append(Delta("stale", case_id, arm, applicable[key], frozenset()))

    matched_count = sum(
        1
        for key, graders in applicable.items()
        if key not in safety_keys and actual.get(key) == graders
    )
    return KnownFailuresComparison(matched=not deltas, matched_count=matched_count, deltas=deltas)
