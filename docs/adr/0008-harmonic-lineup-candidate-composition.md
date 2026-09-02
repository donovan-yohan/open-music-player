# ADR 0008: Harmonic Lineup Candidate Composition

Date: 2026-08-26

Status: Accepted

## Context

Slices 1-3 of the mix work shipped a harmonic candidate primitive:
`LibraryRepository.NearbyTracks` returns the analyzed tracks in a user's library
that are camelot-compatible with, and tempo-near, a given BPM/key, optionally
re-ranked by play-history affinity (issues #393, #391). Nothing consumed it from
the DJ session surface.

Issue #401 asks for a lineup block that continues the set the listener has
already built: "what mixes cleanly out of what I just queued". Two structural
facts constrain how that can be built.

First, **there is no server-side playback queue**. The DJ session screen fetches
`GET /api/v1/dj/lineup` with query parameters only, and every queue mutation
stays in the client's `QueueProvider`, which ADR 0001 keeps as the single
playback authority. The backend therefore cannot read a "queue tail" — it can
only be told one.

Second, the themed lineup's three blocks (`on-repeat`, `flashback`,
`fresh-finds`) are a frozen design contract. Their count bounds the `blocks`
query parameter, their ids spell the `block` enum error, and a test asserts the
exact copy of all three. Growing that list would change flag-off behavior in
three places at once.

## Decision

**One new block consumes harmonic candidates.** A single additive block, id
`harmonic`, title "In key", reason "Mixes cleanly from what you just queued.",
leads the response. The three themed blocks, their count, their ordering rules
and their copy are untouched; `blocks` continues to bound only the themed
blocks. The harmonic block's tracks are marked used before the themed blocks are
built, so the existing "no track twice in one response" invariant holds.

**The anchor is a client-supplied queue-tail track id.** A new `anchorTrackId`
query parameter carries the last enqueued track. It is resolved against the
caller's own library projection — the `db.DJLineupTrack` rows the lineup already
loaded, whose BPM/camelot come from `projectCompactAnalysis`, the same semantics
as the `track_analysis.effective_bpm` / `effective_camelot` generated columns
that the candidate query filters on. **No new SQL, no new repository method, no
schema change.** Resolution happens before the vibe-pin filter, so an active pin
cannot hide the track the listener just queued; the pin still governs which
candidates may appear. Candidates come from `NearbyTracks` with a ±6 BPM
tolerance and `AffinityRankHistory`, are re-checked per candidate against the
canonical camelot distance rule and the BPM window, and are joined back onto the
lineup projection so the response payload keeps its duration/energy/album fields.

**The fallback is silent and exact.** The block is omitted entirely — with no
new response field, no new block, and no changed copy — when any of the
following holds: the flag is off or no candidate reader is wired; no
`anchorTrackId` was supplied; the anchor is not in the user's library, has no
positive BPM, or has an unparseable camelot; the candidate read errors (logged,
never a 500); or fewer than three candidates survive the compatibility, filter
and pin join. There are **no new fields** on the lineup response types, so a
fallback response is structurally identical to a lineup that never had a
harmonic block.

**Determinism.** The API layer adds no clock and no map iteration order. The
block's rule is: seeded selection from the affinity-ranked head, then restored
to rank order — variety comes from the seed, ordering comes from affinity. The
seed offset is disjoint from the themed blocks' offsets, ranks are captured
after skip sequencing so a demoted track stays demoted, and every map in the
path is read by key only. The one wall-clock dependency is the `NOW()` in the
shipped affinity SQL from #391; it lives in the repository, not in this code,
and is out of scope here.

**The flag is `ENABLE_HARMONIC_LINEUP`, default false everywhere**, including
tailnet staging, where the operator opts in for QA. With the flag off, the
lineup is byte-identical to the themed lineup: `anchorTrackId` is never
inspected and `block=harmonic` is rejected with the pre-existing enum error.
A golden corpus captured before the feature landed enforces that.

**The DJ session surface remains a discovery surface.** The client reads the
queue snapshot its provider already holds; it never triggers a queue fetch from
the lineup path and never becomes a second playback controller. Epic #380's
"one playback truth, no second controller" constraint holds unchanged. Because
`QueueProvider` is hydrated lazily by whichever surface loads it first, a cold
start straight into the DJ session would otherwise read an empty queue and
omit the anchor forever; the screen therefore observes the provider and
re-issues its own lineup load once, the first time a non-empty snapshot
appears. That is an observation, not a fetch: the DJ surface still never asks
for the queue.

## Consequences

- Harmonic suggestions arrive on an existing surface with no new endpoint, no
  new table and no new client screen.
- The block is only as good as the analyzer's coverage: an unanalyzed queue tail
  silently yields no block, which is the intended honest failure.
- Turning the flag on changes one piece of error copy: an invalid `block` value
  is reported against a four-value enum instead of three. That is the only
  observable flag-on difference for a request without an anchor.
- The anchor is client-asserted. It is validated against the caller's own
  library, so it can only ever surface tracks the caller already owns; it is not
  a trust boundary beyond that.
- If a server-side queue is ever introduced, the anchor becomes derivable
  server-side and `anchorTrackId` can be deprecated without changing the block.
- **The harmonic block is exempt from fast-exit pruning.** Skip sequencing
  applies to it like any other block — a heavily skipped track is demoted and
  stays demoted in the emitted order — but the fast-exit rule that empties
  `fresh-finds` does not extend to it. Fast exit means the listener is
  rejecting unfamiliar material; the harmonic block is scoped to what mixes out
  of the track they just queued, which is a different claim, so it stays.
  `TestDJHarmonicLineupSurvivesFastExitPruning` pins that decision.
- **The harmonic block is deliberately unpinnable.** The vibe pin stores an
  energy/genre envelope derived from a themed block's candidate set, and there
  is no meaningful envelope for "in key with the queue tail" — the pin's
  candidate lookup has no harmonic case and would fall through to the whole
  library. `POST /api/v1/dj/pin` therefore keeps its frozen three-theme enum
  (`TestDJPinRejectsHarmonicBlockID`) and the client hides the pin affordance
  on the harmonic block rather than offering a control the server rejects. Swap
  is unaffected: `block=harmonic` is a valid lineup selector while the flag is
  on.
