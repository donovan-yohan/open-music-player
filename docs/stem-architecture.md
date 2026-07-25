# Stem Separation, Edit Events, And Playback Architecture

Issue: #305

Epic: #302

Status: Phase C design; no implementation is implied by this document.

## Intent

This design answers three maintainer questions:

1. Which separation models are credible for a self-hosted Open Music Player
   deployment, and which quality or license claims are too weak to ship?
2. Does live stem manipulation have to be desktop-only?
3. Can stem cuts be stored as metadata while today's mobile engine still plays
   the modified result?

The short answers are: use an offline Apple Silicon worker with a license-clean
Demucs model first; live stem mixing is native-engine-dependent rather than
desktop-only; and versioned, source-anchored edit events can resolve to a
server-rendered mixdown that today's clients play as an ordinary audio file.

This is a design for later implementation. Runtime, quality, device, and
storage figures below are research inputs to validate during delivery, not
measurements from OMP.

## Separation Pipeline

### Model matrix

SDR values below come from different test sets and sometimes measure different
targets. They are useful for tiering models, not for pretending every row is a
controlled head-to-head benchmark.

| Model | Reported quality | Runtime / deployment evidence | License reality | OMP verdict |
| --- | --- | --- | --- | --- |
| `htdemucs` | HTDemucs4 is reported at about 9.16 dB average SDR on a community multisong comparison ([comparison](https://stemsplitter.github.io/research/model-comparison/)) | The community `demucs-mlx` port reports a seven-minute song in 12 seconds, about 73x realtime on Apple Silicon ([port](https://github.com/ssmall256/demucs-mlx/), [benchmark account](https://medium.com/@andradeolivier/i-ported-demucs-to-apple-silicon-it-separates-a-7-minute-song-in-12-seconds-6c4e5cffb5c3)) | Demucs code and pretrained weights are MIT; upstream is archived and the maintained fork accepts limited fixes ([fork](https://github.com/adefossez/demucs), [weights discussion](https://github.com/facebookresearch/demucs/issues/327)) | Fast, license-clean four-stem baseline and the first model to validate on `server-mac` |
| `htdemucs_ft` | About 9.19 dB vocal SDR median in the cited community comparison; exact deltas are approximate ([comparison](https://stemsplitter.github.io/research/model-comparison/)) | A bag of four models, inferred at roughly 18x realtime if it is four times the published `htdemucs` cost; the 73x headline must not be attributed to this variant without an OMP benchmark | MIT code and weights | Preferred quality default if parity and the estimated approximately 6.5-hour full-library run are verified; otherwise start with `htdemucs` |
| BS-RoFormer / Mel-Band RoFormer family | Roughly 10.87-10.98 dB vocal SDR for named community checkpoints; the BS-RoFormer paper reports 9.80 dB average without extra data ([paper](https://arxiv.org/abs/2309.02612), [community list](https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/docs/pretrained_models.md)) | CUDA-friendly, but community reports and ports do not yet establish an acceptable OMP Apple Silicon or CPU budget | Architecture/training code may be MIT, but usable community checkpoint licenses and training provenance are absent or mixed; the KimberleyJensen repository has no license ([checkpoint repository](https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model)) | Optional experimental vocal pass only; not a default and never redistribute unlicensed weights |
| SCNet XL | Reported at 10.08 dB average SDR on MUSDB test material ([community list](https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/docs/pretrained_models.md)) | No dependable OMP self-hosted runtime path was established; leading artifacts are MVSEP-tied | Availability and redistribution terms are not clean enough for the default | Track as a quality reference, not a Phase C dependency |
| DrumSep family | On the drum-only MVSEP benchmark, a Mel-Band v2 model reports kick 18.7 dB, snare/toms 13.6 dB, but hi-hat only 3.4-5.1 dB ([leaderboard](https://mvsep.com/quality_checker/leaderboard/drumsep5/?sort=kick)) | A second-stage pass over the Demucs drums stem, not a replacement four-stem pipeline | Model-specific terms are mixed; LarsNet checkpoints are CC BY-NC 4.0 ([LarsNet](https://github.com/polimi-ispl/larsnet)) | Kick is promising, but neither kick nor hi-hat becomes an audio-addressable edit stem in this decision. Kick may graduate after quality/license validation; hi-hat is an energy/color channel only |

The Phase C recommendation is an offline batch worker on the existing Apple
Silicon `server-mac`, reached over the tailnet. Validate the published
`demucs-mlx` `htdemucs` result (about 73x realtime) and output parity against
reference PyTorch on a representative track set before selecting
`htdemucs_ft`. If the fine-tuned bag remains about four times as expensive, the
2,000-track / 7,000-track-minute estimate is about 6.5 hours rather than the
1.6-hour baseline estimate. These are capacity estimates, not an SLA.

The low-memory x86 host is a degraded fallback. `demucs.cpp` reports 4m09s for
a four-minute track with four threads on a Ryzen 5950X, approximately realtime
([benchmark](https://github.com/sevagh/demucs.cpp/blob/main/.github/PERFORMANCE.md)).
At the assumed library size that is about 117 hours, so it can drain a trickle
queue while `server-mac` is unavailable but must not be the primary batch path.

Store four identically encoded `vocals`, `drums`, `bass`, and `other` artifacts
plus their energy summaries. At 128 kbps Opus per stem, four stems consume
about 3.8 MB per track-minute, 13.5 MB for the assumed 3.5-minute track, or
27 GB for 2,000 tracks. This estimate excludes derived mixdowns and object
metadata. FLAC would move the library into a materially larger, 200+ GB tier,
so lossless storage is not the default.

The drum split must be presented honestly. Kick extraction is good enough to
evaluate as an energy channel and potentially later as audio. Hi-hat and cymbal
results are bleed-heavy research outputs, so Phase C uses them only to color or
energize a lane. The drum-only SDR figures are not comparable to the four-stem
MUSDB figures.

## Live-Mix Engine

### Decision shape

Live stem manipulation does not have to be desktop-only. The requirement is
that all stems for one clip advance under one sample clock and are summed in
one native render callback. Algoriddim ships a substantially heavier workload
(realtime separation plus mixing) on A12-class iOS devices and 64-bit Android
devices ([compatibility](https://help.algoriddim.com/topic/using-djay/neuralmix-compatibility),
[product architecture](https://www.audioshake.ai/case-studies/algoriddim)).
That is feasibility evidence, not OMP device proof.

The proposed adapter is:

```text
PlaybackEngine / VoicePool
          |
          +-- JustAudioVoice       (ordinary one-file deck)
          |
          `-- StemGroupVoice       (one clip, N stems, one native voice group)
                    |
                    `-- flutter_soloud / SoLoud / miniaudio mixer callback
```

`StemGroupVoice implements Voice`. The current `Voice` contract is already an
injection seam with load, seek, gain, speed, transport, and drift methods
(`client/lib/core/engine/voice.dart:6-51`). A stem group presents one clip as
one deck to `VoicePool`; internally, all stem decoders are started together and
advanced by the same SoLoud/miniaudio callback. Inter-stem offset is therefore
zero samples by construction. Deck-to-deck synchronization remains on the
existing drift model, whose current intervals and thresholds are explicit in
`client/lib/core/engine/voice_pool.dart:29-59`.

One stem group consumes **one** slot of the locked four-deck cap
(`client/lib/core/engine/timeline_model.dart:269-285`). It can therefore
crossfade with other ordinary or stem-group clips without redefining overlap
depth. `flutter_soloud` is the recommended first vehicle because it exposes an
MIT-licensed Flutter plugin over SoLoud/miniaudio, supports disk-streamed
software decoding, voice groups, and native mobile/desktop targets
([plugin](https://pub.dev/packages/flutter_soloud),
[SoLoud](https://github.com/jarikomppa/soloud),
[miniaudio](https://miniaud.io/)).

One `Voice` per stem is explicitly rejected. It would consume the entire
four-voice deck budget for one track, require eight streams for a two-clip
transition, and delegate phase coherence to a corrector built for independent
tracks. Today's implementation uses one `just_audio` player per voice
(`client/lib/core/engine/voice.dart:27-98`) and checks drift on a two-second
cadence. It tolerates 150 ms before speed-nudging and hard-seeks only beyond
500 ms (`client/lib/core/engine/voice_pool.dart:39-46`,
`client/lib/core/engine/voice_pool.dart:690-723`). That is appropriate for
cross-deck drift, not for keeping sibling stems within a few milliseconds.

### Platform verdict

| Platform | Verdict | Qualification |
| --- | --- | --- |
| Android | Feasible | `flutter_soloud` supports Android 21+ and software decoding avoids treating each stem as a MediaCodec session. OMP still needs low- and mid-tier device profiling. |
| iOS | Feasible | `flutter_soloud` supports iOS 13+; AVAudioEngine is an alternative native path. Algoriddim's A12 floor is evidence for the heavier realtime-separation tier, not an OMP minimum. |
| macOS | Feasible | SoLoud/miniaudio can use the native CoreAudio path. |
| Windows | Feasible | SoLoud/miniaudio can use WASAPI. |
| Web | Excluded for now | Web Audio can express a sample-locked graph, but `flutter_soloud` labels web support under testing and eager float PCM decode is memory-hostile. Pre-rendered playback remains available on web. |

Desktop-FIRST describes rollout sequencing and authoring ergonomics. It is not
a platform verdict. Android, iOS, macOS, and Windows are feasible native
targets; only web live mixing is excluded from the initial native-mixer scope.

The native-mixer MVP is fixed at playback rate 1.0. The existing engine has a
pitch-preserving speed/pitch path (`client/lib/core/engine/voice.dart:149-160`)
and tempo automation
(`client/lib/core/engine/tempo_automation.dart:372-651`) built over source
tempo metadata (`client/lib/core/engine/tempo_automation.dart:19-57`). SoLoud
exposes varispeed rather than equivalent pitch-preserving time stretch. When
tempo-automated stem clips are scoped, integrate an MIT option such as
[signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)
inside the native pipeline. That work is not smuggled into the stem MVP.

## Edit-Event Model

### Canonical clip extension

Stem edits extend the canonical per-clip contract. They do not create an
editor-local store, a stem-specific plan, or a third playback authority.
Today, `MixSessionClip` already snapshots placement, rate, tempo, and analysis
identity (`client/lib/core/audio/playback_session.dart:696-711`,
`client/lib/core/audio/playback_session.dart:734-791`,
`client/lib/core/audio/playback_session.dart:872-886`), while the server
`MixPlanClip` carries the durable timing and stored gain/fade/pitch hooks
(`backend/internal/api/mix_plan_handlers.go:49-66`) in `mix_plans.payload`
JSONB with optimistic versioning (`backend/internal/db/db.go:433-447`).

The future unified `MixSessionClip` / `MixPlanClip` shape gains one optional
field:

```json
{
  "stemEdits": {
    "schemaVersion": 1,
    "channelSet": "stems4-demucs-v1",
    "stemModelVersion": "htdemucs-4s-v1",
    "sourceFileHash": "sha256:...",
    "beatGridRef": {
      "analysisRef": "track:42",
      "analysisVersion": "2026-07-25T00:00:00Z"
    },
    "events": [
      {
        "eventId": "stem-edit-1",
        "channel": "vocals",
        "type": "gain",
        "sourceStartMs": 42000,
        "sourceEndMs": 58000,
        "gainDb": -96,
        "rampInMs": 40,
        "rampOutMs": 40,
        "snap": {
          "mode": "beat4",
          "beatIndices": [64, 80]
        }
      }
    ]
  }
}
```

The rules are:

- `schemaVersion`, `channelSet`, `stemModelVersion`, and `sourceFileHash`
  prevent an edit from silently applying to the wrong channel registry,
  separator output, or source revision.
- Version 1 has one event type: `gain`. A cut is a ramp to linear gain 0,
  represented at the serialization boundary by approximately `-96 dB`.
  Duration-changing edits are out of scope.
- Event ranges are half-open and anchored to source milliseconds before clip
  trim, placement, or rate. Moving a clip does not move an edit within its
  source.
- Milliseconds are authoritative. Beat indices and snap mode are advisory
  provenance against `beatGridRef`; a changed analysis version offers re-snap
  rather than silently moving an event. The existing beat-grid vocabulary and
  source-timed metadata live in
  `client/lib/core/engine/tempo_automation.dart:19-57`.
- Only audio-addressable channel sets accept edits. Visual sets such as a
  future kick/hi-hat energy overlay cannot be mistaken for playable stems.
- Old clips without `stemEdits` continue to parse as before. A later
  implementation must also prevent old clients from erasing unknown
  `stemEdits` during a read-modify-write cycle, either through server-side
  merge preservation or a minimum-client gate.

The server representation stays nested inside the existing clip objects in
`mix_plans.payload`; no normalized table is required for v1. This follows the
existing timing contract's explicit JSONB-first migration path
(`docs/MIX_PLAN_TIMING_CONTRACT.md:6-12`, `docs/MIX_PLAN_TIMING_CONTRACT.md:63-65`).
The client snapshot carries the same field through `MixSessionClip.toJson`, so
resume and queue persistence do not create a second schema.

### Three-rung playback resolution ladder

#### A. Server-side subtractive pre-render (Phase 1)

This is the first playback implementation. A render worker uses the original
mixdown and selected stems:

```text
output(t) = original(t) - sum((1 - requested_gain_c(t)) * stem_c(t))
```

Equivalently, it mixes the original with polarity-inverted stem deltas
`(gain_c(t) - 1) * stem_c(t)`. Unlike reconstructing the whole song by summing
all separator outputs, this preserves the original file outside edited ranges
and confines separation/reconstruction artifacts to the edited material.

The worker follows the existing bounded Redis queue and worker-pool shape
(`backend/internal/download/queue.go:14-33`,
`backend/internal/download/worker.go:41-67`). The analyzer image installs
`ffmpeg` (`backend/Dockerfile:25-38`), and the Go analyzer invokes it
(`backend/cmd/audio-analyzer/main.go:355-375`). Implementation must still pin
and test the required filter behavior rather than assuming the current image
is a render contract.

The derived full-length mixdown is content-addressed by a canonical hash of:

```text
sorted edit events
+ channelSet
+ stemModelVersion
+ sourceFileHash
+ renderPipelineVersion
```

Store it under a derived-artifact prefix, deduplicate identical edit states,
and garbage-collect unreferenced artifacts with a bounded sweep. Extend the
existing signed playback descriptor path, documented at
`docs/SIGNED_AUDIO_URLS.md:1-7`, so a rendered clip resolves to the derived
object. To today's mobile engine it is still one signed audio file and one
ordinary voice; no live-stem client support is required.

Required implementation backpressure includes a null-edit render that is
sample-close to the original, deterministic key tests, event validation,
render failure/retry coverage, and proof that the signed descriptor resolves
the derived object only when its source/model hashes still match.

#### B. Native-mixer live interpretation (future)

`StemGroupVoice` interprets the same `(channel, source range, gain envelope)`
events as audio-rate per-stem faders. Persistence and authoring do not fork;
only the playback interpreter changes. The pre-render remains useful for
offline playback, battery-constrained devices, old clients, and web.

#### C. Honest fallback

If separation or rendering is pending, failed, absent from the offline cache,
or unsupported by the client, play the unmodified original and show an
**edits not applied** badge based on the artifact actually resolved. Never
approximate a vocal or drum cut with broad EQ or a whole-track volume dip.

## Sequencing And Prerequisites

1. **#196 / #290 single-clip authority first — hard gate.** Queue playback
   currently rebuilds tracks through `toPlaybackJson`
   (`client/lib/screens/queue_screen.dart:1369-1390`), whose payload omits trim,
   placement, rate, and stem metadata
   (`client/lib/models/track.dart:195-203`). Meanwhile queue edits are held and
   saved separately (`client/lib/providers/queue_provider.dart:42-44`,
   `client/lib/providers/queue_provider.dart:646-714`). Adding stem events
   before that bridge is unified would recreate the confirmed lossy-bridge P0
   in a third store.
2. **#304 stem artifacts second.** Separation is opt-in and on-demand. Trigger
   it when a user first attempts a stem edit; separating an entire library
   before demonstrated demand is the most expensive default.
3. **Phase 1 mobile playback.** Add the versioned gain events, render worker,
   content-addressed artifact, signed-URL resolution, pending/failed status,
   and honest fallback. Today's mobile engine plays the resulting single file.
4. **Desktop-first authoring.** Build the detailed editor on stem-colored
   lanes, where pointer precision, beat zoom, and vertical space can support
   four channels. Mobile may display the merged colored waveform and status
   before it supports detailed event authoring.
5. **Future native interpretation.** Add `StemGroupVoice` at rate 1.0, prove
   device budgets and audio focus, and only then scope tempo automation.

Realtime on-device separation is out of scope. Algoriddim proves it is
possible, but it requires a custom native audio and ML stack and introduces a
real device floor. OMP is designing playback of pre-separated artifacts first.

## Risks And Honesty Constraints

### License boundary

| Artifact | Terms / uncertainty | Allowed Phase C posture |
| --- | --- | --- |
| Demucs code and pretrained `htdemucs` / `htdemucs_ft` weights | MIT; upstream archived, maintained fork limited | Safe default after pinning and parity checks |
| RoFormer architecture/training repositories | Often MIT code | Code license does not grant rights to every checkpoint or its training data |
| Community RoFormer checkpoints | Absent, unclear, mixed, or site-specific terms | Personal self-hosted experiment only; do not redistribute or make a product default |
| LarsNet pretrained checkpoints | CC BY-NC 4.0 | Non-commercial research/energy evaluation only; do not make an audio-addressable product dependency |
| DrumSep / MVSEP-tied artifacts | Research/hobby availability and unclear redistribution posture | Quality reference and local evaluation only until a specific artifact passes license review |

Personal self-hosting can tolerate experiments that a redistributed or
commercial product cannot. The repository must not bundle, mirror, or
automatically fetch a checkpoint whose redistribution and training provenance
have not been cleared.

### Product and engineering risks

- **Separation bleed:** a gain-zero vocal event means "mostly removed," not
  studio-clean removal. Residual vocals can remain in other stems. UX copy must
  say reduce/remove-mostly and must not promise isolation.
- **SoLoud maturity:** `flutter_soloud` has game-audio lineage, no built-in
  pitch-preserving time stretch, a game-grade resampler, web support marked
  under testing, and a maintenance cadence to evaluate before adoption. A
  custom miniaudio/FFI mixer is the hedge if measured limits appear, not Phase
  1 scope.
- **Dual-pipeline migration:** ordinary ExoPlayer voices and one miniaudio
  output may coexist. Intra-stem coherence remains sample-locked, while
  cross-deck timing remains on the existing coarse drift model. Audio focus and
  media-session behavior require physical-device proof.
- **Codec priming:** every stem in a set must use the same codec, encoder, and
  settings. Prefer Opus or FLAC; avoid mixing MP3 and other encoders whose
  different priming delays can create a fixed offset even under a perfect
  mixer.
- **Capacity and availability:** `server-mac` is the fast path and a single
  point of failure; the x86 fallback is approximately 70x slower. Separation
  needs its own queue class and bounded backpressure so it cannot starve
  analysis or downloads.
- **Unmeasured OMP budgets:** third-party runtime and device claims are not OMP
  acceptance evidence. Before native playback ships, profile CPU, memory,
  battery, seek behavior, focus handling, and artifact alignment on the actual
  target matrix.
