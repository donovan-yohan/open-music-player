# ADR 0006: Stem Edit Events And Playback Ladder

Date: 2026-07-25

## Status

Accepted.

## Context

Open Music Player needs durable stem cuts that can play on today's mobile
engine and later become live native-mixer automation. The current repository
still has a lossy bridge between saved queue timing and playback, so a
stem-specific store would create another authority and repeat that failure.

Independent `just_audio` voices also cannot represent sibling stems. One voice
per stem would spend the locked four-deck budget on one clip and put
sample-coherence work on a drift corrector designed for independent tracks.

Separation is imperfect. Kick extraction is promising, but hi-hat/cymbal
separation remains bleed-heavy and model/checkpoint licenses are mixed.

## Decision

Stem edit events extend the canonical versioned clip contract shared by
`MixSessionClip` and `MixPlanClip`; they never form a parallel editor,
persistence, or playback authority. This decision is gated on #196/#290
single-clip-authority work.

Version 1 is source-time-anchored, duration-preserving gain automation.
Milliseconds are authoritative; beat indices are advisory provenance. A cut is
a click-safe gain ramp to zero. Events identify the versioned channel set,
stem-model output, source-file hash, and beat-grid reference.

Phase 1 resolves edited clips through a content-addressed, server-rendered
subtractive mixdown: start with the original and subtract the envelope-scaled
parts of edited stems. The derived artifact uses the existing signed-URL
playback path, so current mobile clients still play one ordinary audio file.
When that artifact is unavailable, clients play the unmodified original and
show **edits not applied**.

Future live playback uses `StemGroupVoice implements Voice`. One clip's stems
are decoded and advanced in one native mixer callback, so the group consumes
one deck slot and has zero-sample intra-stem offset by construction. Deck-level
sync remains under the existing timeline/voice drift model. The native-mixer
MVP is rate 1.0; pitch-preserving tempo automation is a separate integration.

Kick and hi-hat audio-addressable edit stems are rejected pending specific
quality and license validation. Kick/hi-hat energy channels may drive
visualization; hi-hat must not be presented as clean playable audio.

## Consequences

- The canonical clip-unification work is a hard prerequisite. Implementing
  `stemEdits` on both sides of today's split is not an acceptable shortcut.
- One event document supports pre-rendered playback, future live playback, and
  deterministic honest fallback without translation into competing schemas.
- Mobile modified-stem playback can ship before live native mixing, but edits
  have render latency and need pending/failed status.
- Desktop-first authoring is rollout sequencing, not a claim that native live
  mixing is desktop-only.
- Separator bleed means "cut" is "mostly removed"; product copy and acceptance
  tests must preserve that limitation.
- Community model checkpoints with absent, non-commercial, or unclear terms
  remain personal self-hosted experiments and are not redistributed.
- The detailed design, evidence, and deferred risks live in
  `docs/stem-architecture.md`.

## Enforcement

Issue #305 is docs-only, so this ADR does not claim that prose already enforces
runtime behavior. The implementation slices must add executable backpressure:

- Do not accept `stemEdits` until #196/#290 has established one canonical clip
  save/playback path.
- Validate schema/channel/model/source hashes and reject edits for
  non-audio-addressable channel sets.
- Golden-test the subtractive null-edit render, deterministic artifact key, and
  original-audio fallback.
- Require exact-head checks plus physical-device evidence for native
  mixer/audio-focus claims that unit tests cannot prove.
