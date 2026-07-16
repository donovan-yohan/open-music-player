"""Deterministic baseline arm — the honest floor.

It retrieves the case pool through the read-only fixture tools, pipes the
candidates through the REAL Go ``sourcequality-rank`` scorer, and shapes the
top-N into an ``AssemblyResult``. Zero model calls. This is the production
scorer, not a Python re-implementation, so the A/B comparison answers "what does
multi-step agenting buy over the shipped deterministic ranking?" honestly.
"""

from __future__ import annotations

from .. import go_ranker
from ..budgets import Budget
from ..fixture_tools import ToolBox, normalize_tokens
from ..schemas import (
    AssemblyResult,
    BudgetSpent,
    CaseInput,
    Evidence,
    FixtureWorld,
    InterpretedIntent,
    Provenance,
    Recommendation,
)
from ..validate import canonical_track_duration, is_duration_mismatch

ORCHESTRATOR_ID = "deterministic-go-sourcequality-v1"

# Map production source-quality warning strings onto the assembly warning enum.
_GO_WARNING_MAP: tuple[tuple[str, str], ...] = (
    ("music video", "music_video"),
    ("live version", "live"),
    ("lyric video", "lyric_video"),
    ("remix or edit", "remix"),
    ("speed/pitch altered", "altered_audio"),
    ("short-form video", "short_version"),
    ("duration is very short", "short_version"),
    ("interview or documentary", "interview"),
    ("visualizer", "visualizer"),
    ("not downloadable", "not_downloadable"),
    # "cover" is matched last and loosely; keep it after the specific phrases.
    ("cover", "cover"),
)


def _zero_clock() -> float:
    """A frozen clock so trace/budget elapsedMs are deterministic (0). The arm is
    bounded by the tool-call counter, not wall time, so this is safe."""

    return 0.0


def _platform_preference(prompt: str) -> list[str]:
    tokens = set(normalize_tokens(prompt))
    preference: list[str] = []
    if "youtube" in tokens:
        preference.append("youtube")
    if "soundcloud" in tokens:
        preference.append("soundcloud")
    return preference


def _desired_kinds(prompt: str) -> list[str]:
    lowered = prompt.lower()
    # Single-word signals match on normalized tokens (word boundaries), not raw
    # substrings, so 'Oliver' does not read as 'live' nor 'discover' as 'cover'.
    tokens = set(normalize_tokens(prompt))
    if "official audio" in lowered or "audio only" in lowered:
        return ["official_audio", "topic_audio"]
    if "music video" in lowered or "official video" in lowered:
        return ["music_video"]
    if "live" in tokens:
        return ["live"]
    if "remix" in tokens:
        return ["remix"]
    if "cover" in tokens:
        return ["cover"]
    return ["official_audio", "topic_audio"]


def _map_warnings(go_warnings: list[str], duration_mismatch: bool) -> list[str]:
    out: list[str] = []
    for warning in go_warnings:
        lowered = warning.lower()
        for needle, enum_value in _GO_WARNING_MAP:
            if needle in lowered:
                out.append(enum_value)
                break
    if duration_mismatch:
        out.append("duration_mismatch")
    # De-dupe while preserving order.
    seen: set[str] = set()
    deduped: list[str] = []
    for value in out:
        if value not in seen:
            seen.add(value)
            deduped.append(value)
    return deduped


def _rationale(classification: str, reasons: list[str]) -> str:
    base = classification.replace("_", " ")
    for reason in reasons:
        cleaned = reason.strip()
        if cleaned and cleaned != "deterministic fallback ranking":
            text = f"{base}: {cleaned}."
            return text[:240]
    return f"{base} candidate ranked by the deterministic source-quality scorer."[:240]


class DeterministicArm:
    name = "deterministic"

    def assemble(
        self, case_input: CaseInput, world: FixtureWorld, budget: Budget
    ) -> AssemblyResult:
        toolbox = ToolBox(world, budget, now=_zero_clock)
        # Expose the tool-returned id allowlist so the runner can thread it into the
        # grounding validator (grounding checks real tool output, not pool membership).
        self.allowlist = toolbox.allowlist
        preference = _platform_preference(case_input.prompt)

        # Retrieve the pool (optionally provider-filtered) through the tool layer
        # so the grounding allowlist reflects real tool calls.
        retrieved = toolbox.search_sources(
            case_input.prompt,
            providers=preference or None,
            limit=budget.max_candidates_in,
        )
        catalog_tracks = toolbox.search_catalog(case_input.prompt, kind="track", limit=8)

        canonical = canonical_track_duration(world)
        catalog_ref = catalog_tracks[0].id if catalog_tracks else None

        candidate_dicts = [c.model_dump(exclude_none=True) for c in retrieved]
        ranked = go_ranker.rank(case_input.prompt, candidate_dicts)

        top_n = min(case_input.limit, budget.max_recommendations, len(ranked))
        recommendations: list[Recommendation] = []
        for position, candidate in enumerate(ranked[:top_n], start=1):
            metadata = candidate.get("metadata") or {}
            quality = metadata.get("sourceQuality") or {}
            classification = quality.get("classification", "unknown")
            confidence = float(quality.get("confidence", 0.5))
            reasons = list(quality.get("reasons") or [])
            go_warnings = list(quality.get("warnings") or [])
            candidate_id = candidate["candidateId"]
            duration_ms = candidate.get("durationMs")
            mismatch = bool(canonical) and is_duration_mismatch(duration_ms, canonical)
            evidence = [Evidence(tool="search_sources", ref=candidate_id)]
            if canonical and catalog_ref:
                evidence.append(Evidence(tool="search_catalog", ref=catalog_ref))
            recommendations.append(
                Recommendation(
                    candidateId=candidate_id,
                    rank=position,
                    confidence=max(0.0, min(1.0, confidence)),
                    rationale=_rationale(classification, reasons),
                    classification=classification,
                    evidence=evidence,
                    warnings=_map_warnings(go_warnings, mismatch),
                )
            )

        unresolved: list[str] = []
        if canonical is None and any(entry.kind == "track" for entry in world.catalog):
            unresolved.append(
                "Catalog has no canonical duration for the interpreted track; duration cross-check skipped."
            )

        intent = InterpretedIntent(
            searchQueries=[case_input.prompt],
            platformPreference=preference,
            desiredKinds=_desired_kinds(case_input.prompt),
            durationTargetMs=canonical,
            notes="Deterministic source-quality ranking of the retrieved pool.",
        )

        return AssemblyResult(
            arm=self.name,
            interpretedIntent=intent,
            recommendations=recommendations,
            unresolved=unresolved,
            trace=list(toolbox.trace),
            budgetSpent=BudgetSpent(
                toolCalls=toolbox.tool_calls, modelCalls=0, elapsedMs=0
            ),
            provenance=Provenance(
                orchestrator=ORCHESTRATOR_ID, model="", toolTransport="none"
            ),
        )
