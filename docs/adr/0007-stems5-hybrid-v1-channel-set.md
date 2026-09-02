# ADR 0007: stems5-hybrid-v1 Channel Set (ADR 0006 Addendum)

Date: 2026-08-03

## Status

Proposed (exploration branch `codex/stems-exploration`, not merged).

Amends ADR 0006 *Stem Edit Events And Playback Ladder*. ADR 0006 remains the
contract authority; this addendum only adds the channel set, the three seams
ADR 0006 left open, and one correction to overstated language in
`docs/stems5-spec.md`.

## Context

ADR 0006 rejected kick and hi-hat as audio-addressable edit stems "pending
specific quality and license validation", and permitted kick/hi-hat only as
*visualization* channels. That verdict was aimed at **learned** hi-hat models,
which top out around 3.4-5.1 dB SDR and whose checkpoints carry absent or
non-commercial terms (LarsNet CC BY-NC with no code license; jarredou MDX23C
CC-BY-NC-SA with a dead source repo; MVSep/RoFormer community mirrors).

`docs/stems5-spec.md` proposes a different construction: derive the pair from
the demucs `drums` stem with deterministic DSP instead of a second model. The
bench on this host (2026-08-03, demucs 4.1.0 + torch-cpu 2.8.0, 8 vCPU)
measured the derivation as numerically exact, and the base separation as viable
on CPU:

| Gate | Result |
| --- | --- |
| Wall time, 3 real library tracks | 0.65-0.94x realtime |
| Max RSS | 1.7-2.3 GB |
| kick+perc null-sum vs drums | **-120 dB** (threshold -80 dB) |
| Opus 128k/48k, 6 stems | ~19 MB/track |

The spec also arrived with five open corrections. Three of them are contract
decisions that had to be made before the pipeline could be implemented, and
they are recorded here rather than left in code.

## Decision

### 1. `stems5-hybrid-v1` is an audio-addressable channel set

`stems5-hybrid-v1` = `{vocals, melody, bass, kick, perc}`.

- `vocals`, `bass`, `melody` reference the base `htdemucs-4s-v1` objects
  (`melody` is the alias of demucs `other`). They are **not** duplicated on
  disk.
- `kick` = zero-phase LR4 low-pass of the `drums` stem at 180 Hz (2nd-order
  Butterworth applied via `filtfilt`, giving 4th-order magnitude and no phase
  shift).
- `perc` = `drums - kick`, computed by subtraction, so `kick + perc == drums`
  to float precision rather than approximately.
- Both derived channels carry the provenance tag `dsp-crossover-lr4-180`.
- `drums.opus` is always retained, so the pair can be null-verified or
  re-derived without another demucs run.

This does not reopen ADR 0006's verdict: **learned hi-hat stems remain
banned.** The pair is admitted because it is deterministic DSP with no
checkpoint, no license surface, and a by-construction reconstruction identity —
i.e. it is a real audio artifact of the already-accepted `drums` stem, not a
new model output.

Honesty copy is part of the decision, not decoration. The UI labels are
**"Kick (low drums)"** and **"Hats & Percussion"**, and cut copy says
**"mostly removed"**, never "isolated". Known bounded failures: kick beater
click (2-4 kHz) stays in `perc`; 808 and low-tom bodies leak into `kick`.

### 2. Canonical wire names (one place, no aliases in flight)

| Channel set | Channels | Stem model version |
| --- | --- | --- |
| `stems4-demucs-v1` | `vocals, drums, bass, other` | `htdemucs-4s-v1` |
| `stems5-hybrid-v1` | `vocals, melody, bass, kick, perc` | `htdemucs-4s-v1+lr4-180` |

`hihat` is **retired**; `perc` is the only name for the non-kick percussion
channel. `melody` is the only alias of demucs `other`, and the alias map is
declared exactly once (`backend/cmd/stems-worker/stems_dsp.py`,
`CHANNEL_ALIASES`). Edit events, energy channels, and the client colour
registry all read that vocabulary, so they cannot drift apart. ADR 0006's
example event (`channel: vocals`) stays valid unchanged.

Storage layout:

```text
stems/{track_id}/htdemucs-4s-v1/{vocals,drums,bass,other}.opus
stems/{track_id}/stems5-hybrid-v1/{kick,perc}.opus
```

All six files are encoded by one libopus configuration in one worker run
(128 kbps VBR, 48 kHz, stereo, `application=audio`, 20 ms frames). Codec
uniformity is a correctness requirement, not a preference: mixed encoders have
different priming delays, which appear as a fixed inter-stem offset under any
mixer. `opus_encode_argv` is the single definition, and the build-time smoke
asserts the encoder-flag slice is identical across every emitted file.

### 3. Derived-render URL resolution — explicit content-hash selector

*(Resolves the spec's "derived-render resolution contract is undefined"
correction.)*

`POST /api/v1/playback/urls` is track-scoped (`{trackIds, ttlSeconds}`), but a
track can carry different `stemEdits` in different mix plans, or none. Rather
than making the descriptor mix-plan-aware — which would give playback a second
authority over which edit state is "current", contradicting ADR 0001 — the
**client names the artifact it wants by content hash**:

```jsonc
POST /api/v1/playback/urls
{
  "trackIds": [42],
  "ttlSeconds": 600,
  "renders": [                          // optional; omit for plain playback
    {
      "trackId": 42,
      "contentHash": "sha256:...",      // computed client-side, see below
      "channelSet": "stems5-hybrid-v1",
      "stemModelVersion": "htdemucs-4s-v1+lr4-180",
      "sourceFileHash": "sha256:..."
    }
  ]
}
```

`contentHash` is the deterministic key already specified by
`docs/stem-architecture.md`: `sha256(sorted events + channelSet +
stemModelVersion + sourceFileHash + renderPipelineVersion)`. The client can
compute it without a round trip, so the request is self-identifying.

Server resolution, per requested render:

1. The `track_stems` row for `(trackId, channelSet, stemModelVersion)` must be
   `ready` **and** its `source_file_hash` must equal the requested one.
2. `derived/{contentHash}.opus` must exist.
3. If both hold, presign the derived object and return
   `editsApplied: true` with `renderContentHash`.
4. Otherwise presign the **original** and return `editsApplied: false` plus a
   machine-readable `renderFallbackReason`
   (`stems_not_ready` / `source_changed` / `render_missing` / `model_changed`).

Consequences that follow from this shape:

- Plain library playback omits `renders` entirely and always resolves the
  original. Existing behaviour is untouched.
- ADR 0006's honest-fallback badge is driven by the server's `editsApplied`
  flag, never inferred client-side.
- The handler uses `DisallowUnknownFields`, so a new client against an old
  server gets a clean 400 rather than silently losing its edits. That is the
  intended failure mode.

**Not implemented on this branch.** The Rung A render worker does not exist
yet, so shipping half of this contract would create a descriptor that promises
artifacts nothing produces. The decision is recorded so the Rung A ticket is
implementable; the endpoint is unchanged today.

### 4. Energy-curve delivery — `track_stems` owns them, the analyzer does not

*(Resolves the spec's "stems energy-curve delivery path is unspecified"
correction.)*

`channels.audio_ref` is null-reserved in the analyzer-written `track_analysis`
payload, but the stems worker is a separate service. Making it write
`track_analysis` would give that table two writers and let a stems run
invalidate or race a beat-grid analysis.

Decision: **per-stem energy curves are stored in
`track_stems.artifacts_json.energy` and delivered by
`GET /api/v1/tracks/{track_id}/stems`.** The stems service never writes
`track_analysis`; `track_analysis` stays single-writer.

Payload shape, on the analyzer's shared 80 Hz frame grid:

```jsonc
"energy": {
  "frame_hz": 80,
  "frame_count": 16800,
  "encoding": "uint8-linear",
  "reference_rms": 0.41,            // ONE reference shared by all channels
  "channels": { "vocals": "<base64 uint8>", "melody": "...", "bass": "...",
                "kick": "...", "perc": "...", "drums": "..." }
}
```

All channels share one normalization reference so lanes are comparable against
each other; per-channel autoscaling would make a silent stem look as busy as a
loud one. `channels.audio_ref` in `track_analysis` stays null and is defined as
an opaque pointer whose stems-set value means "resolve from the stems
endpoint" — no analyzer re-run is required, and no cross-service write exists.

### 5. Timeline stem automation is authored as change points

ADR 0006 v1 is "source-time-anchored, duration-preserving gain automation" with
half-open source-ms ranges authoritative. The product requirement is stated as
change points — "vocals off at X ms, back on at Y ms", beat-quantizable. These
are the same contract, and this addendum fixes the mapping:

```jsonc
"stemEdits": {
  "schemaVersion": 1,
  "channelSet": "stems5-hybrid-v1",
  "stemModelVersion": "htdemucs-4s-v1+lr4-180",
  "sourceFileHash": "sha256:...",
  "beatGridRef": { "analysisRef": "...", "analysisVersion": "..." },
  "events": [ { "channel": "vocals", "atMs": 12000, "gain": 0.0,
                "rampMs": 8, "beatIndex": 32 } ]
}
```

- `atMs` is source time and is authoritative. `beatIndex` is advisory
  provenance, exactly as ADR 0006 requires. Beat snapping rewrites `atMs`; it
  never makes the beat index load-bearing.
- Gain is linear `0.0..1.0`, held from `atMs` until the next change point on
  the same channel. The implicit gain before a channel's first change point is
  `1.0`.
- A cut is gain `0.0` reached over a click-safe `rampMs` ramp (default 8 ms).
- Events canonicalize by `(atMs, channel)`; a duplicate `(channel, atMs)`
  collapses to the later write.
- Consecutive change points compile deterministically to ADR 0006's half-open
  ranges `[atMs_i, atMs_{i+1})`, with the last running to clip end. The
  equivalence is unit-tested, so the authoring form provably does not fork the
  contract.
- Solo/isolate remains gain events on the other channels. No new event type.

`stemEdits` stays gated: the server must reject it until #196/#290
single-clip authority lands. This branch ships the client authoring model and
UI only; playback is stubbed behind the `StemChannelSource` seam.

### 6. Correction: "sample-close", not bit-identical

`docs/stems5-spec.md` §5 claims Rung A "preserves the original bit-identically
outside edited ranges". That is not achievable: the derived artifact is a
48 kHz Opus re-encode of a typically 44.1 kHz lossy original. **ADR 0006's
"sample-close" is the binding language**, and the spec is overstated where it
conflicts.

Two consequences the Rung A ticket must carry:

- The resample/priming alignment policy for subtracting 48 kHz Opus stems
  (312-sample pre-skip) from a 44.1 kHz decoded original is where cancellation
  quality is actually decided, and must be specified before implementation.
- A null-edit golden test is alignment-blind (it degenerates to passthrough).
  Acceptance needs an alignment-sensitive gate instead: an all-stems-full-cut
  render residual bound, or a decoded-stem-sum vs original alignment check.

## Consequences

- The client colour registry gains five lanes named by the canonical wire
  names above.
- `track_stems` is keyed `(track_id, channel_set, stem_model_version)`. A
  source re-download changes `source_file_hash` and marks existing rows stale;
  a stem-model bump marks rows stale by identity. Both go through the guarded
  upsert, so a late worker response can never overwrite a newer request.
- A Tier 1 upgrade (`stems5-hybrid-v2`, e.g. a learned kick model) is a new
  `stem_model_version`, which stale-marks the v1 rows rather than mutating
  them. Any such upgrade requires **primary verification of that checkpoint's
  own terms** — a permissive code license does not license weights.
- `flutter_soloud`/miniaudio has no built-in Opus decoder. A Rung B live mixer
  therefore needs an FFI libopus decode stage or an on-device transcode. This
  does not change storage today, but it is recorded because codec uniformity is
  partly Rung-B-motivated.
- `just_audio` on iOS (AVPlayer) does not play Ogg/Opus natively. Derived
  pre-renders are Android/web-scoped unless an AAC/m4a container is chosen for
  them.
- The htdemucs weight licence remains formally unresolved upstream. The
  mitigation stands: build-time download, pinned repo + file + sha256, never
  mirrored in-repo. Verified value:
  `d9fa14133cfcc034a6758923bb3a8ca9f8dfd0b582134643bbf83f72c17576dd`
  (`adefossez/HTDemucs`, `955717e8.safetensors`). Note that `955717e8` is the
  demucs model **signature**, not a hash; the spec's original assertion against
  it would have failed the build.

## Operational configuration

Separation is **default-off** and opt-in per track. It is never a library-wide
sweep.

| Variable | Default | Purpose |
| --- | --- | --- |
| `STEMS_ENABLED` | `true` when `STEMS_BASE_URL` is set, else `false` | Force-disable a configured worker. |
| `STEMS_BASE_URL` | empty | Worker root. The backend posts to `/separate` below it. |
| `STEMS_AUTH_TOKEN` | empty | Bearer token; empty disables worker-side auth. |
| `STEMS_CONCURRENCY` | `1` (max 2) | demucs peaks near 2.3 GB RSS on the bench host; a third slot trades analysis and download liveness for separation throughput. |
| `STEMS_TIMEOUT_MS` | `1800000` | 30-minute separation budget. |
| `STEMS_QUEUE_MAX_DEPTH` | `32` | Reject-when-full threshold; `POST /api/v1/tracks/{id}/stems` returns `429 QUEUE_FULL` above it. |

A 30-minute synchronous POST is fragile (resets, future tailnet proxies). It is
tolerable only because the Postgres row is the durable authority: a retried
delivery reproduces the same content-addressed objects, and the guarded upsert
turns a duplicate into a no-op rather than a double-write. Before pointing
`STEMS_BASE_URL` at server-mac, switch to submit/poll.

## Enforcement

Prose does not enforce; these do, and each can fail:

- `backend/Dockerfile` stage `stems-runtime` asserts the checkpoint sha256 at
  build time and pins `HF_HUB_OFFLINE=1` at runtime, so a container cannot
  drift off the pinned weights.
- `backend/Dockerfile` stage `stems-test` fails the build if the worker sources
  name a checkpoint host outside `{huggingface.co, dl.fbaipublicfiles.com}` or
  mention a known NC-licensed checkpoint family. This moves the spec's
  "CI should grep for non-allowlisted checkpoint URLs" out of risk prose and
  into a gate.
- The build-time separation smoke asserts four demucs sources, six distinct
  objects, `kick+perc` null-sum ≤ -80 dB, one uniform libopus configuration,
  and the 80 Hz energy grid.
- `backend/cmd/stems-worker/stems_dsp_test.py` proves the crossover null-sum,
  the LR4 corner response, encoder uniformity, the retirement of `hihat`, and
  the manifest shape — with the separator dependency-injected, so it runs
  without torch.
- `backend/cmd/stems-worker/main_test.go` proves the versioned identity
  handshake (409 on mismatch), bearer auth, the six-object upload, source-hash
  computation, and that local scratch paths never reach the database.
- The stems Redis queue is its own key namespace with reject-when-full
  backpressure, so separation provably cannot starve Beat This analysis or
  downloads.
- Client unit tests prove change-point/range equivalence, unknown-key
  preservation, unknown-`schemaVersion` rejection, and the honesty copy.

## 2026-08-30 implementation addendum — audio-separator runtime

This addendum supersedes only the prior runtime provider/model, artifact-key,
and current performance assertions. The preceding derived-render selector,
energy ownership, automation/change-point, sample-close, configuration,
enforcement, and historical research decisions remain intact.

`stems-runtime` uses `audio-separator==0.47.0` as the inference provider with
the SHA-verified `htdemucs_ft` bag. This is a Demucs-family four-stem model,
not a different channel-set vocabulary: its exact outputs are `vocals`,
`drums`, `bass`, and `other`, with `other` exposed as `melody` in the v5 UI.
The provider wheel, mutable UVR registry, model config, and four weights are
baked only at image build behind SHA-256 assertions. The adapter revalidates
the local bundle at readiness and before inference, rejects provider
model/registry downloads, and reports provider/version, exact
wheel/registry/config/weight hashes, output mapping, CPU device, and worker
version. The API compares that complete identity before it starts handlers or
queue consumers.

The stable channel-set IDs now resolve to immutable model versions
`audio-separator-htdemucs-ft-4s-v1` (`stems4-demucs-v1`) and
`audio-separator-htdemucs-ft-4s-v1+lr4-180` (`stems5-hybrid-v1`). All new
objects carry the complete identity, including the v5 base channels:

```text
stems/{track_id}/audio-separator-htdemucs-ft-4s-v1/
  {vocals,drums,bass,other}.opus
stems/{track_id}/audio-separator-htdemucs-ft-4s-v1+lr4-180/
  {vocals,other,bass,drums,kick,perc}.opus
```

This makes every new six-object set disjoint from the legacy
`htdemucs-4s-v1` and `stems5-hybrid-v1` layouts. Existing ready rows retain
their old stored model version and are model-changed/stale, never rewritten.
The LR4 split, -80 dB null-sum guard, uniform Opus encode, and energy/manifest
contracts remain unchanged. audio-separator emits WAV files, so the adapter
uses its least-mutating normalization/amplification settings before OMP-owned
DSP and encoding.

The 2026-08-03 Demucs benchmark remains historical evidence only; it does not
characterize this current provider/model bag. Concurrency is fixed at `1`
until a representative three-track CPU RSS/realtime-factor benchmark exists.
Offline readiness was manually verified with `docker run --rm --network none
--entrypoint python omp-stems-runtime-audio-separator:verify /app/stems_dsp.py
--check`; that evidence is not currently CI backpressure.

Modern specialist vocal, instrumental, and drum-component routes are future
evaluation work only: no such checkpoint is bundled or fetched here, and any
later route requires separate license, quality, identity, and stale-model
review.
