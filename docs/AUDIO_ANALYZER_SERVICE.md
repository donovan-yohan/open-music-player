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
    "key": { "value": "A minor", "confidence": 0.82, "provenance": "chroma" },
    "camelot": { "value": "8A", "confidence": 0.82, "provenance": "chroma" },
    "energy": { "value": 0.73, "confidence": 0.88, "provenance": "rms_spectral_flux" },
    "waveform": { "sample_count": 6, "confidence": 0.99, "provenance": "waveform" },
    "intro": { "start_ms": 320, "end_ms": 16000, "confidence": 0.74, "provenance": "sections" },
    "outro": { "start_ms": 180000, "end_ms": 197500, "confidence": 0.69, "provenance": "sections" },
    "sections": [],
    "cue_candidates": []
  },
  "artifacts": {
    "waveform_resolution": "coarse"
  },
  "provenance": {
    "analyzer": "local-service",
    "analyzer_version": "dev"
  }
}
```

The client also accepts `summary_json`, `artifacts_json`, and `provenance_json` field names to match the persistence schema directly.

## Failure modes

- `415 Unsupported Media Type` or `422 Unprocessable Entity` marks analysis `unsupported`.
- Other non-2xx responses, network errors, malformed JSON, or missing summaries mark analysis `failed`.
- Import/share completion is not blocked by analyzer work; analysis runs asynchronously after storage and library insertion.
