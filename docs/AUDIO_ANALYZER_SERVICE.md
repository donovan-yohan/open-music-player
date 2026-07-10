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
    "bpm": { "value": 124.0, "confidence": 0.94, "provenance": "beat_grid" },
    "beat_grid": {
      "bpm": 124.0,
      "offset_ms": 320,
      "beats_ms": [320, 804, 1288, 1772],
      "confidence": 0.91,
      "provenance": "beat_grid"
    },
    "downbeats": {
      "positions_ms": [320],
      "confidence": 0.86,
      "provenance": "beat_grid"
    },
    "key": { "value": "A minor", "confidence": 0.82, "provenance": "zero_crossing_chroma_proxy" },
    "camelot": { "value": "8A", "confidence": 0.82, "provenance": "zero_crossing_chroma_proxy" },
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
        "low": { "sample_count": 6, "artifact_ref": "spectral_bands.overview.low" },
        "mid": { "sample_count": 6, "artifact_ref": "spectral_bands.overview.mid" },
        "high": { "sample_count": 6, "artifact_ref": "spectral_bands.overview.high" }
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
      "overview": { "sample_rate_hz": 2, "peaks": [0.0, 0.21, 0.65], "rms": [0.0, 0.14, 0.41] },
      "detail": { "sample_rate_hz": 4, "peaks": [0.0, 0.12, 0.21], "rms": [0.0, 0.08, 0.14] }
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
    "analyzer": "local-service",
    "analyzer_version": "dev",
    "model_versions": {
      "tempo": "tempo-v1",
      "key": "zero-crossing-chroma-v1",
      "loudness": "loudness-v1",
      "waveform": "waveform-v1"
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

When an analyzer version or model version changes, backend maintenance can mark matching `analyzed` rows as `stale`; playback remains usable because stale analysis is metadata only, and the repair path re-queues those rows as `pending` without blocking import/share completion.

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
  "overrides": {
    "bpm": { "value": 124.0, "confidence": 1.0 },
    "beat_grid": { "bpm": 124.0, "beats_ms": [120, 604, 1088] },
    "downbeats": { "positions_ms": [120, 2056] },
    "key": { "value": "A minor" },
    "camelot": { "value": "8A" }
  }
}
```

The response is the normal analysis envelope plus `overrides`. The queue list
and selected timeline clip expose the current editor sheet. It lets users edit
BPM, first downbeat offset, phrase length, key, and Camelot; the client expands
BPM/offset/phrase edits into beat-grid and downbeat arrays before saving them,
then refreshes queue/timeline analysis caches so markers and labels consume the
corrected summary immediately.

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

## Key and Camelot analysis

The built-in ffmpeg analyzer now emits `key` and `camelot` summaries for real
audio using a lightweight zero-crossing pitch-class proxy. This is intentionally
lower-confidence than a full chroma model, but it gives the queue/timeline UI a
stable harmonic hint and provenance while leaving room for a future analyzer
version to replace it with richer chroma or stem-aware key detection.

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
