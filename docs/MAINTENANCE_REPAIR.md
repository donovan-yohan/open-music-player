# Backend maintenance repair controls

The maintenance repair endpoint gives an authenticated operator a safe way to re-run metadata matching and audio analysis without hand-editing database rows.

```http
POST /api/v1/maintenance/repair
Authorization: Bearer <token>
Content-Type: application/json
```

## Request

```json
{
  "trackIds": [42],
  "metadata": true,
  "analysis": true,
  "forceMetadata": false,
  "forceAnalysis": false,
  "staleAfterMinutes": 30,
  "limit": 50
}
```

Fields:

- `trackIds`: optional selected tracks. When omitted, the backend selects stale/repairable candidates up to `limit`.
- `metadata`: re-run MusicBrainz/Ollama metadata matching. Defaults to `true`.
- `analysis`: enqueue/re-run audio analysis. Defaults to `true`.
- `forceMetadata`: allows metadata repair to overwrite user-edited or already verified metadata. Defaults to `false`.
- `forceAnalysis`: allows re-analysis of already analyzed/unsupported rows. Defaults to `false`.
- `staleAfterMinutes`: pending/analyzing analysis rows older than this are considered stuck and repairable. Defaults to `30`.
- `limit`: maximum selected tracks. Defaults to `50`, capped at `200`.

## Safety rules

- User-edited metadata is skipped unless `forceMetadata=true`.
- Already verified metadata is skipped unless `forceMetadata=true`.
- Metadata matching preserves low-confidence suggestions; it does not auto-apply low-confidence matches.
- Analysis rows in `pending` or `analyzing` are skipped until they are stale, preventing duplicate concurrent analyzer work.
- `failed` analysis rows are retryable by default.
- `unsupported` and `analyzed` analysis rows require `forceAnalysis=true`.
- Analysis repair requires a repair-capable analysis store, a configured analyzer client, and a track `storage_key`; otherwise the response reports the missing dependency.

## Response

```json
{
  "tracks": [
    {
      "trackId": 42,
      "title": "Example Track",
      "metadata": {
        "trackId": 42,
        "status": "processed",
        "reason": "metadata_match_reran"
      },
      "analysis": {
        "trackId": 42,
        "queued": true,
        "status": "pending",
        "previousStatus": "failed",
        "reason": "failed_retry"
      }
    }
  ],
  "summary": {
    "selected": 1,
    "metadataDone": 1,
    "metadataSkipped": 0,
    "analysisQueued": 1,
    "analysisSkipped": 0,
    "errors": 0
  },
  "criteria": {
    "metadata": true,
    "analysis": true,
    "forceMetadata": false,
    "forceAnalysis": false,
    "staleAfterMinutes": 30,
    "limit": 50,
    "trackIds": [42]
  }
}
```

`waitingOn` values identify the operator dependency that must be fixed before a skipped repair can proceed:

- `metadata_verifier`: metadata matching is disabled or failed outside Ollama.
- `ollama`: the metadata verifier is waiting on Ollama availability.
- `analysis_store`: the configured analysis store is missing repair support, such as a legacy store that only exposes the older enqueue API. Repair skips these rows without calling `RequestAnalysis` or dispatching analyzer work.
- `analyzer_config`: analyzer client configuration is missing.
- `analyzer`: analyzer work is already pending/analyzing, or analysis repair cannot be queued until analyzer-side dependencies are available.
- `storage`: the track has no stored audio key to analyze.

## Examples

Set `AUTH_HEADER='Authorization: Bearer <token>'` before running the examples.

Retry failed/stale analysis only:

```bash
curl -fsS -X POST "$OMP_API_BASE_URL/maintenance/repair" \
  -H "$AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"metadata":false,"analysis":true,"staleAfterMinutes":30,"limit":25}'
```

Repair one selected track without overwriting user edits:

```bash
curl -fsS -X POST "$OMP_API_BASE_URL/maintenance/repair" \
  -H "$AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"trackIds":[42],"metadata":true,"analysis":true}'
```

Force a selected track after a deliberate operator decision:

```bash
curl -fsS -X POST "$OMP_API_BASE_URL/maintenance/repair" \
  -H "$AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"trackIds":[42],"forceMetadata":true,"forceAnalysis":true}'
```
