# Mix-plan timing contract

Issue: #57
Schema version: 1

## Decision

MVP timing persistence lives in the lightweight saved mix-plan store (`mix_plans.payload` JSONB, exposed by `/api/v1/mix-plans`). Do not put trim or placement on Redis queue items.

Why, because Redis queue state is operational download/playback state: it can be reordered, retried, dropped, or rebuilt. Trim/placement is user-authored arrangement state and must survive queue churn, reloads, and future editor sessions. The SQL-backed mix-plan row gives us ownership scoping, optimistic versioning, timestamps, and a future migration path without turning the queue into a cursed document database.

Future normalized SQL tables can split clips out of `mix_plans.payload` when we need cross-plan search, collaborative editing, or partial clip updates. That is not required for v1.

## Clip timing model

Request clip shape for `POST /api/v1/mix-plans` and `PUT /api/v1/mix-plans/{mixPlanId}`:

```json
{
  "clipId": "clip-a",
  "queueItemId": "queue-a",
  "trackId": 42,
  "sourceStartMs": 1000,
  "sourceEndMs": 5000,
  "timelineStartMs": 12000,
  "gainDb": -1.5,
  "fadeInMs": 250,
  "fadeOutMs": 500
}
```

Fields:

- `clipId`: stable client-owned clip identity inside a plan.
- `queueItemId`: durable queue item identity the clip was planned from. This is an identity/link, not where timing is persisted.
- `trackId`: authenticated user's library track id. Multiple clips may point at the same track.
- `sourceStartMs`: start of the selected source range, inclusive.
- `sourceEndMs`: end of the selected source range, exclusive. Must be greater than `sourceStartMs`.
- `timelineStartMs`: where the clip starts on the mix timeline.
- `timelineEndMs`: response-only derived value: `timelineStartMs + (sourceEndMs - sourceStartMs)`. Clients must not persist or send it as independent state.
- `gainDb`: static future gain hook. Stored only; no backend audio engine behavior.
- `fadeInMs`, `fadeOutMs`: optional future fade hooks. Stored only; no backend fade rendering.

Invariant: source trim and timeline placement are independent. Moving a clip changes `timelineStartMs` and derived `timelineEndMs`; it does not mutate `sourceStartMs` or `sourceEndMs`. Trimming a clip changes `sourceStartMs`/`sourceEndMs` and derived `timelineEndMs`; it does not move `timelineStartMs`.

## Plan metadata

Saved plan responses include:

- `version`: optimistic concurrency token. `PUT` must send the latest version.
- `createdAt`, `updatedAt`: durable timestamps from the store.
- `summary.durationMs`: max derived `timelineEndMs` across clips, not a server playhead.
- `summary.trackIds`: unique referenced track ids, sorted ascending.

## Non-goals for v1

- No audio rendering/mixing engine.
- No BPM/key analysis.
- No beat-grid, cue points, stems, or time-stretch.
- No Redis queue item timing mutation.
- No normalized clip SQL table until query/collab requirements justify it.

## Migration notes

Current v1 payloads are JSONB documents under `mix_plans`. A future normalized model can migrate each payload clip into a `mix_plan_clips` table keyed by `(mix_plan_id, clip_id)` while preserving the same API fields. If queue item ids become unavailable after queue GC, the saved plan still has `clipId`, `trackId`, and timing, so playback/editor recovery can degrade without losing arrangement timing.
