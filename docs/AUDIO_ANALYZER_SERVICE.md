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
    "key": { "value": "A minor", "confidence": 0.82, "provenance": "chroma" },
    "camelot": { "value": "8A", "confidence": 0.82, "provenance": "chroma" },
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
      "key": "key-v1",
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

## Failure modes

- `415 Unsupported Media Type` or `422 Unprocessable Entity` marks analysis `unsupported`.
- Other non-2xx responses, network errors, malformed JSON, or missing summaries mark analysis `failed`.
- Import/share completion is not blocked by analyzer work; analysis runs asynchronously after storage and library insertion.
