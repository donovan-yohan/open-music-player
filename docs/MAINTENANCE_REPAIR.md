# Backend maintenance repair controls

The global maintenance repair endpoint lets an explicitly admitted operator re-run metadata matching, audio analysis, and stored-audio quality probes without hand-editing database rows. Authentication alone is not authorization.

## Operator admission

Set `MAINTENANCE_ADMIN_USER_IDS` in trusted **server configuration** to a comma-separated list of existing user UUIDs, for example:

```text
MAINTENANCE_ADMIN_USER_IDS=53b676c8-7b11-4705-89a6-08dcebcbe674,32bf6be2-e5a5-490b-9364-32a119d3a85a
```

This example uses placeholder identities, not pre-created accounts. Use the real account IDs and restart the server to apply changes. Unset, empty, or whitespace-only configuration denies every HTTP repair caller. Entries must be nonzero hyphenated UUIDs; surrounding whitespace and duplicate IDs are accepted, but malformed/empty entries, compact UUIDs, URNs, and nil UUIDs reject startup before database/service initialization. A malformed list never partially admits its valid prefix.

The handler checks the authenticated user ID against a constructor-time allowlist snapshot **before reading the request body or selecting tracks**. Missing/invalid identity receives `401 UNAUTHORIZED`; an authenticated nonoperator receives `403 FORBIDDEN`, including for explicit IDs, global scans, force flags, and audio-quality repair. Email, request headers/body role flags, and self-asserted JWT admin roles cannot grant access. Direct handler construction without configuration also defaults to deny.

Trusted internal analyzer-version reconciliation remains a direct application/processor call. It needs neither an HTTP operator identity nor an allowlist entry and is not routed through this admission check.

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

- `trackIds`: optional selected tracks, at most `200` entries (including duplicates), each a positive integer. The entire array is validated before any track lookup. When omitted, the backend selects global stale/repairable candidates up to `limit`.
- `metadata`: re-run MusicBrainz/Ollama metadata matching. Defaults to `true`.
- `analysis`: enqueue/re-run audio analysis. Defaults to `true`.
- `audioQuality`: probe stored audio to backfill codec, bitrate, sample rate, channels, and content type. Defaults to `false`.
- `forceMetadata`: requests forced metadata repair; processor-level protections still apply. Defaults to `false`.
- `forceAnalysis`: allows re-analysis of already analyzed/unsupported rows. Defaults to `false`.
- `staleAfterMinutes`: pending/analyzing analysis rows older than this are considered stuck and repairable. Omitted or `0` defaults to `30`; explicit values must be `1`–`10080` (seven days), validated before duration conversion.
- `limit`: maximum selected tracks. Omitted or `0` defaults to `50`, positive values cap at `200`; negative values are rejected.

Requests must contain exactly one non-null JSON object, with no unknown fields or trailing JSON/garbage. The body, including trailing whitespace, is bounded to `16 KiB`; larger requests receive `413 REQUEST_TOO_LARGE`. Invalid JSON or out-of-bounds values receive `400` without track selection or processor work. At least one repair class must be enabled. Combined quality plus metadata/analysis global selection requires `limit >= 2` to reserve bounded progress for both candidate classes.

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
