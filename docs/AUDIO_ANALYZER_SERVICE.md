# Optional Audio Analyzer Service

The backend can call an out-of-process analyzer after downloaded audio has been stored in object storage. This keeps DSP off Flutter/mobile clients and preserves the existing `track_analysis` contract for queue/library UI.

## Disabled default

The analyzer is disabled unless `ANALYZER_BASE_URL` is set or `ANALYZER_ENABLED=true` is provided. When disabled, the processor does not create `pending` `track_analysis` rows, so imported tracks do not get stuck behind an unavailable analyzer.

## Backend configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `ANALYZER_ENABLED` | `true` when `ANALYZER_BASE_URL` is set, otherwise `false` | Set `false` to force-disable a configured analyzer. |
| `ANALYZER_BASE_URL` | empty | Service root URL. The backend posts to `/analyze` below this root. Example: `http://localhost:18190`. |
| `ANALYZER_AUTH_TOKEN` | empty | Optional bearer token sent in the `Authorization` header. |
| `ANALYZER_TIMEOUT_MS` | `90000` | Per-request timeout. The processor also caps the analysis goroutine at two minutes. |

The analyzer container also accepts:

| Variable | Default | Notes |
| --- | --- | --- |
| `ANALYZER_MIR_HELPER` | `/app/audio_mir.py` | Python MIR bridge invoked for each stored audio file. |
| `ANALYZER_BEAT_MODEL` | `/app/models/beat_this-final0.ckpt` | Pinned Beat This model used for beat and downbeat inference. |
| `ANALYZER_CONCURRENCY` | `1` | Backend dispatch and service MIR concurrency, clamped to 1-4. Keep at 1 on low-memory hosts. |
| `ANALYZER_SAMPLE_RATE` | `22050` | PCM sample rate used by the waveform pipeline. |
| `ANALYZER_WAVEFORM_HZ` | `80` | Maximum detail waveform frames per second, bounded by the service cap. |
| `ANALYZER_SPECTRAL_LOW_HZ` | `200` | Tunable low/mid crossover in Hz. |
| `ANALYZER_SPECTRAL_HIGH_HZ` | `2000` | Tunable mid/high crossover in Hz. |
| `ANALYZER_SPECTRAL_LOW_WEIGHT` | `1.0` | Perceptual low-channel weight applied before shared normalization. |
| `ANALYZER_SPECTRAL_MID_WEIGHT` | `1.6` | Perceptual mid-channel weight applied before shared normalization. |
| `ANALYZER_SPECTRAL_HIGH_WEIGHT` | `2.8` | Perceptual high-channel weight applied before shared normalization. |

Crossovers and weights are explicit tuning knobs. The shipped
`200 Hz / 2 kHz` and `1.0 / 1.6 / 2.8` defaults favor bass, body, and presence;
`600 Hz / 4 kHz` is the documented Mixxx-style crossover alternative. Change
these only as one analyzer deployment and bump the analyzer provenance when
the defaults change so stored artifacts are rolled forward.

## Service contract

Request:

```json
{
  "schema_version": 1,
  "track_id": 42,
  "storage_key": "tracks/user/song.wav",
  "source_url": "https://youtu.be/example",
  "source_type": "youtube",
  "duration_ms": 197500,
  "title": "Fixture Song",
  "artist": "Fixture Artist"
}
```

Response (`200`):

```json
{
  "schema_version": 1,
  "summary": {
    "bpm": { "value": 124.0, "confidence": 0.94, "provenance": "beat-this-final0-v1.1.0" },
    "beat_grid": {
      "bpm": 124.0,
      "offset_ms": 320,
      "beats_ms": [320, 804, 1288, 1772],
      "confidence": 0.91,
      "provenance": "beat-this-final0-v1.1.0"
    },
    "downbeats": {
      "positions_ms": [320],
      "confidence": 0.86,
      "provenance": "beat-this-final0-v1.1.0"
    },
    "key": { "value": "A minor", "confidence": 0.82, "provenance": "librosa-cqt-krumhansl-v1" },
    "camelot": { "value": "8A", "confidence": 0.82, "provenance": "librosa-cqt-krumhansl-v1" },
    "energy": { "value": 0.73, "confidence": 0.88, "provenance": "rms_spectral_flux" },
    "loudness": {
      "integrated_lufs": -11.8,
      "short_term_lufs": -9.5,
      "loudness_range_lu": 5.2,
      "confidence": 0.93,
      "provenance": "ebu_r128"
    },
    "true_peak": { "dbtp": -1.2, "confidence": 0.92, "provenance": "true_peak" },
    "waveform": {
      "sample_count": 6,
      "resolutions": [
        { "name": "overview", "samples_per_pixel": 1024, "sample_count": 6, "artifact_ref": "waveforms.overview" },
        { "name": "detail", "samples_per_pixel": 256, "sample_count": 12, "artifact_ref": "waveforms.detail" }
      ],
      "spectral_bands": {
        "low": { "sample_count": 12, "artifact_ref": "spectral_bands.detail.low" },
        "mid": { "sample_count": 12, "artifact_ref": "spectral_bands.detail.mid" },
        "high": { "sample_count": 12, "artifact_ref": "spectral_bands.detail.high" }
      },
      "channels": {
        "channel_set": "bands3-v1",
        "audio_ref": null,
        "sample_count": 12,
        "normalization": { "kind": "shared_peak", "scalar": 2.8 },
        "weights": { "low": 1.0, "mid": 1.6, "high": 2.8 },
        "crossovers_hz": { "low_mid": 200, "mid_high": 2000 },
        "provenance": "librosa-mel-bands-v2",
        "values": {
          "low": {
            "sample_count": 12,
            "artifact_ref": "channels.detail.low",
            "normalization": { "kind": "shared_peak", "scalar": 2.8 },
            "weight": 1.0,
            "provenance": "librosa-mel-bands-v2"
          },
          "mid": {
            "sample_count": 12,
            "artifact_ref": "channels.detail.mid",
            "normalization": { "kind": "shared_peak", "scalar": 2.8 },
            "weight": 1.6,
            "provenance": "librosa-mel-bands-v2"
          },
          "high": {
            "sample_count": 12,
            "artifact_ref": "channels.detail.high",
            "normalization": { "kind": "shared_peak", "scalar": 2.8 },
            "weight": 2.8,
            "provenance": "librosa-mel-bands-v2"
          }
        }
      },
      "confidence": 0.99,
      "provenance": "waveform"
    },
    "transients": { "count": 48, "density_per_second": 1.6, "strongest_ms": [10120, 20180, 30240], "confidence": 0.9 },
    "silence": { "leading_ms": 320, "trailing_ms": 610, "ranges": [{ "start_ms": 0, "end_ms": 320 }], "confidence": 0.97 },
    "intro": { "start_ms": 320, "end_ms": 16000, "confidence": 0.74, "provenance": "sections" },
    "outro": { "start_ms": 180000, "end_ms": 197500, "confidence": 0.69, "provenance": "sections" },
    "sections": [],
    "cue_candidates": [],
    "duration_sanity": { "declared_ms": 197500, "decoded_ms": 197480, "delta_ms": -20, "confidence": 0.99 }
  },
  "artifacts": {
    "source": {
      "storage_key": "tracks/user/song.wav",
      "duration_ms": 197500,
      "fingerprint": "sha256-or-decoder-fingerprint"
    },
    "waveforms": {
      "overview": { "sample_rate_hz": 2, "peaks": [0.0, 0.21, 0.65], "minima": [0.0, -0.18, -0.58], "maxima": [0.0, 0.21, 0.65], "rms": [0.0, 0.14, 0.41] },
      "detail": { "sample_rate_hz": 4, "peaks": [0.0, 0.12, 0.21], "minima": [0.0, -0.10, -0.18], "maxima": [0.0, 0.12, 0.21], "rms": [0.0, 0.08, 0.14] }
    },
    "channels": {
      "channel_set": "bands3-v1",
      "audio_ref": null,
      "normalization": { "kind": "shared_peak", "scalar": 2.8 },
      "provenance": "librosa-mel-bands-v2",
      "overview": {
        "low": [0.0, 0.17, 0.55],
        "mid": [0.0, 0.20, 0.61],
        "high": [0.0, 0.09, 0.23]
      },
      "detail": {
        "low": [0.0, 0.08, 0.17],
        "mid": [0.0, 0.11, 0.20],
        "high": [0.0, 0.04, 0.09]
      }
    },
    "spectral_bands": {
      "overview": {
        "low": [0.0, 0.17, 0.55],
        "mid": [0.0, 0.20, 0.61],
        "high": [0.0, 0.09, 0.23]
      }
    },
    "beat_grid": {
      "beats_ms": [320, 804, 1288, 1772],
      "downbeats_ms": [320]
    },
    "markers": {
      "silence_ranges": [{ "start_ms": 0, "end_ms": 320 }],
      "transients_ms": [10120, 20180, 30240]
    },
    "waveform_resolution": "multi_resolution"
  },
  "provenance": {
    "analyzer": "omp-mir-analyzer",
    "analyzer_version": "2026-07-24-1",
    "model_versions": {
      "tempo": "beat-this-final0-v1.1.0",
      "downbeat": "beat-this-final0-v1.1.0",
      "key": "librosa-cqt-krumhansl-v1",
      "loudness": "loudness-v1",
      "waveform": "spectral-v2",
      "spectral": "librosa-mel-bands-v2"
    }
  }
}
```

The client also accepts `summary_json`, `artifacts_json`, and `provenance_json` field names to match the persistence schema directly.

Analysis rows use these lifecycle states:

- `pending`: queued but not started.
- `analyzing`: the analyzer worker has started.
- `analyzed`: ready for playback, queue, and timeline UI. Mobile clients also accept the public alias `ready`.
- `failed`: analyzer work failed and can be retried by maintenance repair.
- `stale`: stored artifacts were invalidated by a newer analyzer/model/source identity and should be repaired asynchronously.
- `unsupported`: the source could not be analyzed.

When an analyzer version or model version changes, backend maintenance marks
older `analyzed` rows as `stale`; playback remains usable because stale
analysis is metadata only, and the repair path re-queues those rows as
`pending` without blocking import/share completion.

### Rolling re-analysis

Deploy the analyzer and backend with the same new analyzer identity. The
backend reads `/health`, marks older rows stale, and drains them in stable
batches of 50. Claim work is bounded to four workers, while actual MIR work
continues to honor `ANALYZER_CONCURRENCY` (keep it at `1` on the low-memory
host). Each row's persisted lifecycle state is the resume checkpoint: a server
restart selects remaining `stale` rows plus abandoned `pending`/`analyzing`
rows, and the idempotent claim prevents duplicate live work.

Each re-analysis reruns the full pipeline, including Beat This inference; the
stateless analyzer does not reuse prior beat results.

Watch the structured `Analyzer version reconciliation completed` log fields
(`marked_stale`, `batches`, `queued`, `skipped`, `failures`). If the analyzer is
temporarily unavailable, reconciliation retries every 30 seconds without
mutating analysis rows. To resume failed/stale rows later in a smaller operator
batch, use the authenticated maintenance endpoint:

```bash
curl -fsS -X POST "$OMP_API_BASE_URL/maintenance/repair" \
  -H "Authorization: Bearer $OMP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"metadata":false,"analysis":true,"staleAfterMinutes":30,"limit":25}'
```

## Manual correction overrides

Manual DJ corrections are stored in `track_analysis.overrides_json` separately
from analyzer output. Queue/library compact summaries overlay
`overrides_json` on top of `summary_json`, so playback, beat snapping, and BPM
automation consume corrected BPM/downbeats immediately while future analyzer
runs can still refresh waveform/loudness/artifacts.

Update corrections with:

```http
PATCH /api/v1/tracks/{track_id}/analysis/overrides
Content-Type: application/json

{
  "expected_revision": 0,
  "overrides": {
    "bpm": { "value": 124.0, "confidence": 1.0 },
    "beat_grid": { "bpm": 124.0, "beats_ms": [120, 604, 1088] },
    "downbeats": { "positions_ms": [120, 2056] },
    "key": { "value": "A minor" },
    "camelot": { "value": "8A" }
  }
}
```

New timing corrections use the additive canonical object below. It keeps tempo,
beat-grid anchor, meter, downbeat phase, and phrase length as independent
facts. Analyzer and retained legacy beat arrays remain stored unchanged as the
fallback span for effective timing projection.

```json
{
  "expected_revision": 3,
  "overrides": {
    "manual_timing_override": {
      "bpm": 124.0,
      "beat_anchor_ms": 120,
      "beats_per_bar": 4,
      "downbeat_phase_index": 0,
      "phrase_length_bars": 8
    }
  }
}
```

The server stamps `confidence: 1.0`, `provenance: "manual_override"`, a
monotonic `revision`, and `updated_at`. Clients should send `expected_revision`
for normal edits; omitting it is treated as `0` to migrate legacy rows. A stale
revision receives `409 ANALYSIS_OVERRIDE_CONFLICT` rather than silently
overwriting another editor. Sending an empty `overrides` object clears manual
facts while advancing the revision, so current generated analysis is visible
again. Legacy `bpm`, `beat_grid`, and `downbeats` override payloads remain
readable. Canonical writes preserve them as fallback data but take precedence;
reset is the operation that clears all manual facts. Analyzer reruns replace
generated summaries/artifacts without changing the manual document or revision.
An override write preserves an existing `pending` or `analyzing` lifecycle
state; the analyzer's normal `StoreResult` path can then transition the row to
`analyzed` while retaining that manual state.

For compact queue/list payloads, a manual BPM or anchor deterministically
regenerates effective beat markers over the existing stored beat span. The
stored analyzer/legacy timestamps are not mutated. A phase-only edit keeps the
effective beat timestamps unchanged; when both meter and phase are known,
downbeats are selected from that effective list modulo the meter. No downbeats
are manufactured when meter is unknown, and phrase length is metadata rather
than a downbeat interval.

The response is the normal analysis envelope plus `overrides`. The queue list
and selected timeline clip expose the current editor sheet. It lets users edit
BPM, grid anchor, meter, phase, phrase length, key, and Camelot as facts. After
a successful CAS update, the client refreshes queue/timeline analysis caches so
markers and labels consume the corrected effective summary immediately.

## Tempo automation and pitch mode

The timeline model uses reliable BPM metadata to automate playback speed during
overlaps. The outgoing clip ramps from its native BPM toward the incoming BPM,
while the incoming clip starts at the outgoing BPM and ramps back to its native
BPM across the crossfade. Both rates are projections of one shared target-BPM
curve, so their effective BPM must be equal at every point in the overlap, not
only at the start or midpoint. If either clip already has a non-1.0 base rate,
the curve runs from the outgoing clip's effective BPM to the incoming clip's
effective BPM; it does not multiply the shared target independently per deck.
The client solves the transition end against the outgoing clip's
rate-adjusted source duration. Auto-managed gain fades use that same solved
window, so the outgoing deck reaches zero gain exactly when both tempo ramps
reach the incoming target BPM instead of ending early or leaving a silent tail.

Playback voices apply speed and pitch together:

- `pitchMode: preserve` is the default key-lock mode. It keeps the just_audio
  pitch factor at `1.0` while speed changes for BPM matching. On Android,
  just_audio/ExoPlayer treats speed and pitch as independent playback
  parameters, so `1.0` is the compensating key-lock value rather than an
  uncorrected resample.
- `pitchMode: followTempo` is available for vinyl/resample-style behavior. It
  sets the pitch factor to the effective playback rate.

Voices are reset to neutral speed and pitch before release/reuse so a prior
transition cannot leak tuning into the next loaded track. Pitch shifting is
best-effort on unsupported just_audio platforms; Android supports the dogfood
path.

The voice pool caches the last applied speed/pitch pair for each deck and does
not resend unchanged tuning on steady gain/sync ticks. BPM ramps still update
when the effective rate changes, but a stable rate should not churn the audio
backend. Active-deck tuning frames are coalesced and applied concurrently; a
slow platform call on one deck must not serialize the peer deck's BPM update or
resume.

## Beat, downbeat, key, and Camelot analysis

The analyzer uses the MIT-licensed Beat This `final0` model for beat and
downbeat inference. Model downbeat candidates vote on a dominant four-beat
phase. Agreement and song coverage determine confidence; sparse or conflicting
candidates remain low-confidence markers instead of being expanded into a
synthetic full-song grid. BPM is derived from tracked beat intervals with robust
outlier rejection instead of quantized transient buckets. Sparse or irregular
tempo grids remain below the client's automatic beat-sync threshold. Downbeat
confidence travels with session tempo metadata; automatic phrase overlap and
downbeat snap ignore generated markers below that threshold, while manual
corrections are treated as authoritative.

Key detection uses librosa's constant-Q chroma over the harmonic signal and
Pearson correlation against the Krumhansl major/minor profiles. The winning
pitch class is converted to Camelot notation by the Go response boundary. Key
confidence reflects both profile fit and separation from the runner-up. Flat or
ambiguous chroma produces no generated key rather than an arbitrary label. BPM,
downbeat, and key summaries are optional: waveform/spectral results still persist
when one of those musical estimates is unavailable. Generated key remains an
estimate, not catalog authority, because commercial databases can also disagree
on harmonically ambiguous recordings.

Decoded PCM duration is the timing authority for waveform bins, beats, and
downbeats. Provider/catalog duration is retained separately for duration-sanity
diagnostics, preventing marker drift when source metadata is slightly wrong.

Spectral channels use librosa mel energy aggregated onto the exact Go-requested
waveform frame count (80 Hz until the existing frame cap applies). Fixed
perceptual weights are applied first, then all three named channels are divided
by one shared peak scalar. This preserves real low/mid/high ratios instead of
making every band independently look full scale. `channels` is the canonical
`bands3-v1` contract; `spectral_bands` is dual-written for one release. Channel
and waveform arrays live only in the per-track `artifacts` object, while
`summary.waveform` carries bounded descriptors and artifact references.

The analyzer image pins PyTorch CPU, Beat This, librosa, and the model checksum,
then runs real model inference against a generated 120 BPM audio fixture.
The normal backend image uses a separate Docker target and does not carry those
MIR dependencies. Reanalysis replaces generated summaries and artifacts while
retaining user-authored `overrides_json` corrections. Backend dispatch is
bounded by the same analyzer concurrency setting before its per-track timeout
starts, so a bulk repair queues locally instead of launching enough model
processes to exhaust memory or timing out behind the service semaphore.

## Beat-locked transition defaults

Fresh queue sessions stay contiguous when analysis is missing or low
confidence. When adjacent clips both have reliable BPM and downbeat metadata,
the canonical session model creates a default 16-beat overlap, bounded between
4s and 12s and never longer than half of either clip. The incoming clip's first
usable downbeat is snapped onto the outgoing downbeat grid, so the default
crossfade starts on a predictable musical boundary before the playback-rate
automation above runs.

Manual timeline edits still use the same downbeat snap math, and freeform timing
remains available because persisted placements are preserved unless queue
insert/remove/reorder needs to reflow downstream defaults.

The canonical playback session stores the selected transition snap mode. The
timeline's Free, Downbeat, 1 beat, 4 beats, and 16 beats options therefore drive
the same queue timing model used by playback and survive queue snapshot restore;
they are not widget-only display state.

Locked auto layouts and drag commits are refined against the rate-adjusted
timeline model after tempo automation is applied. This closes residual phase
error for trimmed clips whose first usable marker lands inside a BPM ramp. The
refinement is bounded by overlap and snap tolerance; explicit freeform/bypass
placements are preserved unchanged.

## Transition diagnostics

Timeline overlap bands classify each crossfade with the same metadata consumed
by playback: reliable BPM, downbeat positions, and Camelot key. The client shows
compact labels for beat-locked overlaps, low-confidence/missing BPM, missing or
offset downbeats, large BPM pulls, and harmonic key clashes. Those warnings are
advisory UI only, but they make analyzer or manual-correction problems visible
before the user hears a broken transition.

## Failure modes

- `415 Unsupported Media Type` or `422 Unprocessable Entity` marks analysis `unsupported`.
- Other non-2xx responses, network errors, malformed JSON, or missing summaries mark analysis `failed`.
- Import/share completion is not blocked by analyzer work; analysis runs asynchronously after storage and library insertion.
