# Dynamic workflow contract for issues #40-#44

Scope: local MinIO discovery-to-mobile-playback MVP for:

- #40 discovery provider abstraction
- #41 mobile discovery -> queue insertion
- #42 non-playable queue items
- #43 mobile playback via signed MinIO URLs
- #44 final local smoke

This is an implementation contract for the Kanban chain rooted at `t_f96bdbf8`. It is deliberately concrete so downstream workers do not need to infer API shape, state transitions, or gate ownership.

## Evidence inspected

- GitHub issue summaries for #37-#44.
- Existing backend routes in `backend/internal/api/router.go`:
  - `POST /api/v1/downloads`
  - `GET /api/v1/downloads/{job_id}`
  - `GET/POST/PUT/DELETE /api/v1/queue`
  - `POST /api/v1/playback/urls`
- Existing signed URL response model in `backend/internal/api/playback.go`.
- Existing queue model in `backend/internal/queue/queue.go` / `handlers.go`.
- Existing download job lifecycle in `backend/internal/download/job.go` / `worker.go` / `service.go`.
- Existing track/storage schema in `backend/internal/db/track_repository.go` and `backend/internal/db/migrations/*`.
- Existing mobile/client queue/audio code in `client/lib/models/queue_state.dart`, `client/lib/core/services/queue_service.dart`, and `client/lib/core/audio/audio_player_service.dart`.
- Existing planning boundary in `docs/BACKEND_CONTROL_PLANE_CONTRACT.md`.

Important current drift: existing queue/download APIs are track-only or URL-only, while the client has a different queue shape. The PRs for #40-#43 must converge on the contract below instead of preserving incompatible half-contracts.

## Non-negotiable architecture boundary

1. Backend is the control plane:
   - Authenticates users.
   - Normalizes external source candidates.
   - Starts and tracks download/store jobs.
   - Persists track/library/storage metadata.
   - Issues signed object URLs for playable tracks.

2. Client is the playback engine:
   - Owns actual audio element/player state.
   - Must not require backend byte proxying for normal playback.
   - Must not attempt to play queue items whose `playbackState` is not `playable`.

3. Redis/download workers are opt-in:
   - Real download tests must use `WORKER_COUNT=1`.
   - Control-plane-only checks may use worker count `0` or disabled workers.
   - Do not make Redis mandatory for auth/library/read-only server startup unless the test profile explicitly enables queue/download.

4. #44 cannot honestly pass unless #37 and #39 are actually satisfied:
   - #37: fresh startup runs the full backend SQL schema, including `tracks`, `user_library`, `playlists`, `playlist_tracks`, and `download_jobs`.
   - #39: a real worker path creates a playable object in MinIO and sets the track storage fields.
   - #38 can cover deterministic fixture playback, but fixture-only evidence does not prove live source download.

## Contract conventions

Use camelCase JSON for newly introduced or revised mobile-facing endpoints. Existing legacy routes may keep snake_case temporarily, but the #40-#44 integration path should expose one coherent mobile contract.

All endpoints below are authenticated unless marked otherwise. Return JSON error objects:

```json
{
  "code": "STABLE_ERROR_CODE",
  "message": "human readable message",
  "details": {}
}
```

Do not log signed URLs. Log track IDs, job IDs, object keys, provider names, status, and error codes only.

## 1. Discovery API contract (#40)

### Endpoint

```http
GET /api/v1/discovery/search?q=<query>&providers=youtube,soundcloud&limit=10
Authorization: Bearer <token>
```

### Request rules

- `q` is required after trimming whitespace.
- `providers` is optional; default is the enabled local allowlist for this profile.
- `limit` defaults to `10`, minimum `1`, maximum `25` for the MVP.
- Backend must apply an overall request timeout and per-provider timeout.
- Provider adapters must be replaceable; `yt-dlp` search/extract is acceptable for local dogfood behind this boundary.

Recommended timeout/rate-limit defaults for first pass:

- Overall discovery request timeout: `8s`.
- Per-provider timeout: `3s`.
- Per-user discovery rate limit: target `10/minute` for live providers; tests can use fakes.
- Provider concurrency: bounded; no unbounded goroutines.

### Response: partial success is success

HTTP `200` even when one provider fails and another succeeds:

```json
{
  "query": "bury a friend",
  "results": [
    {
      "candidateId": "youtube:BaW_jenozKc",
      "provider": "youtube",
      "sourceId": "BaW_jenozKc",
      "sourceUrl": "https://www.youtube.com/watch?v=BaW_jenozKc",
      "title": "Bury a Friend",
      "artist": "Billie Eilish",
      "uploader": "BillieEilishVEVO",
      "durationMs": 193000,
      "thumbnailUrl": "https://example.invalid/thumb.jpg",
      "downloadable": true,
      "playable": false,
      "explicit": null,
      "metadata": {
        "providerRawType": "video"
      }
    }
  ],
  "providers": [
    {
      "provider": "youtube",
      "status": "ok",
      "resultCount": 1,
      "elapsedMs": 824
    },
    {
      "provider": "soundcloud",
      "status": "failed",
      "resultCount": 0,
      "elapsedMs": 3000,
      "error": {
        "code": "PROVIDER_TIMEOUT",
        "message": "soundcloud search timed out"
      }
    }
  ]
}
```

### Provider failure shape

Provider failures are isolated in the `providers[]` array. The endpoint returns a non-200 only when the request itself is invalid or no provider can be attempted.

Stable provider statuses:

- `ok`
- `partial`
- `timeout`
- `rateLimited`
- `failed`
- `disabled`

Stable provider error codes:

- `PROVIDER_TIMEOUT`
- `PROVIDER_RATE_LIMITED`
- `PROVIDER_DISABLED`
- `PROVIDER_UNSUPPORTED`
- `PROVIDER_UNAVAILABLE`
- `PROVIDER_BAD_RESPONSE`

### Backend tests required

- Normalization from fake provider result to `DiscoveryCandidate`.
- One provider failure does not fail the whole response.
- Timeout produces provider-level failure.
- Auth required.
- Unknown provider rejected or reported as disabled/unsupported without panics.

## 2. Download/store contract (#39 pulled into backend foundation)

A discovery candidate becomes a playable local track through this dataflow:

```text
DiscoveryCandidate
  -> source-backed QueueItem created immediately
  -> DownloadJob queued with the same source fields
  -> Worker downloads to bounded temp file
  -> Worker uploads to MinIO with stable storage key
  -> Track row is created/updated with storage metadata
  -> User library row is inserted/confirmed
  -> QueueItem resolves to trackId and playbackState=playable
```

### Add source candidate to queue

Prefer one endpoint for queue insertion that can accept either an existing track or a source candidate:

```http
POST /api/v1/queue/items
Authorization: Bearer <token>
Content-Type: application/json
```

Existing track request:

```json
{
  "position": "next",
  "trackId": 123
}
```

Source candidate request:

```json
{
  "position": "next",
  "sourceCandidate": {
    "candidateId": "youtube:BaW_jenozKc",
    "provider": "youtube",
    "sourceId": "BaW_jenozKc",
    "sourceUrl": "https://www.youtube.com/watch?v=BaW_jenozKc",
    "title": "Bury a Friend",
    "artist": "Billie Eilish",
    "uploader": "BillieEilishVEVO",
    "durationMs": 193000,
    "thumbnailUrl": "https://example.invalid/thumb.jpg",
    "downloadable": true
  }
}
```

Response should return the full queue projection:

```json
{
  "items": [
    {
      "queueItemId": "q_01j...",
      "position": 0,
      "kind": "source",
      "playbackState": "queued",
      "sourceCandidate": {
        "candidateId": "youtube:BaW_jenozKc",
        "provider": "youtube",
        "sourceUrl": "https://www.youtube.com/watch?v=BaW_jenozKc",
        "title": "Bury a Friend",
        "artist": "Billie Eilish",
        "uploader": "BillieEilishVEVO",
        "durationMs": 193000,
        "thumbnailUrl": "https://example.invalid/thumb.jpg"
      },
      "downloadJobId": "job_01j...",
      "trackId": null,
      "progress": 0,
      "error": null,
      "addedAt": "2026-06-03T04:00:00Z",
      "updatedAt": "2026-06-03T04:00:00Z"
    }
  ],
  "currentPosition": 0,
  "updatedAt": "2026-06-03T04:00:00Z"
}
```

### Download job fields

Download jobs must carry enough source and queue correlation for state resolution:

```json
{
  "jobId": "job_01j...",
  "userId": "<authenticated user uuid/string>",
  "queueItemId": "q_01j...",
  "provider": "youtube",
  "sourceId": "BaW_jenozKc",
  "sourceUrl": "https://www.youtube.com/watch?v=BaW_jenozKc",
  "status": "queued",
  "progress": 0,
  "trackId": null,
  "error": null,
  "createdAt": "2026-06-03T04:00:00Z",
  "startedAt": null,
  "completedAt": null
}
```

Worker statuses should stay compatible with current code where possible:

- `queued`
- `downloading`
- `processing`
- `uploading`
- `complete`
- `failed`

### Worker guardrails

The real worker path must:

- Use authenticated user context from the job; no anonymous download endpoint.
- Use a narrow provider allowlist for MVP.
- Run `WORKER_COUNT=1` for real download/local smoke.
- Enforce job timeout.
- Enforce maximum output file size.
- Download into a bounded temp directory.
- Clean temp files on success and failure.
- Store useful failure text on the job and queue item without exposing secrets.

### Track/store fields after success

On success, the worker must produce or reuse a track row with:

- `tracks.id`
- `tracks.identity_hash`
- `tracks.title`
- `tracks.artist`
- `tracks.duration_ms`
- `tracks.source_url`
- `tracks.source_type`
- `tracks.storage_key`
- `tracks.file_size_bytes`
- `tracks.metadata_json`

The MinIO object key should be stable and non-secret. Recommended shape:

```text
users/<userId>/tracks/<trackId-or-identityHash>/audio.<ext>
```

If object key generation uses content hash before track insertion, update the track row after insertion and keep the key deterministic enough for cleanup/debugging.

After object upload:

1. `storage.PutObject` succeeds.
2. `storage.StatObject` confirms object exists and captures size/content type/etag.
3. `tracks.storage_key` and `tracks.file_size_bytes` are set.
4. `user_library` contains `(user_id, track_id)`.
5. The queue item is updated to `playbackState=playable` and `trackId=<id>`.

## 3. Queue state machine (#42)

The mobile-facing queue item is not just a track id anymore. Use this projection:

```json
{
  "queueItemId": "q_01j...",
  "position": 0,
  "kind": "track",
  "playbackState": "playable",
  "trackId": 123,
  "downloadJobId": null,
  "sourceCandidate": null,
  "title": "Bury a Friend",
  "artist": "Billie Eilish",
  "uploader": "BillieEilishVEVO",
  "durationMs": 193000,
  "thumbnailUrl": "https://example.invalid/thumb.jpg",
  "progress": 100,
  "error": null,
  "canPlay": true,
  "canRetry": false,
  "canRemove": true,
  "playbackUrlExpiresAt": null,
  "addedAt": "2026-06-03T04:00:00Z",
  "updatedAt": "2026-06-03T04:02:00Z"
}
```

### States

```text
source candidate selected
  -> queued
  -> downloading
  -> processing
  -> uploading
  -> playable
```

Failure can occur from any active worker state:

```text
queued/downloading/processing/uploading -> failed
failed -> queued       // retry
failed -> removed      // remove from queue
```

Existing local track insertion skips worker states:

```text
existing track -> playable
```

### State meanings

| playbackState | canPlay | Required fields | Client behavior |
| --- | --- | --- | --- |
| `queued` | false | `queueItemId`, `sourceCandidate`, `downloadJobId` | Show pending row; no play attempt. |
| `downloading` | false | `downloadJobId`, `progress` | Show progress; no play attempt. |
| `processing` | false | `downloadJobId`, `progress` | Show processing; no play attempt. |
| `uploading` | false | `downloadJobId`, `progress` | Show storing; no play attempt. |
| `playable` | true | `trackId` | Request signed URL before playback. |
| `failed` | false | `error`, source or job id | Show retry/remove. No player crash. |
| `removed` | false | none in active queue | Not returned from normal queue listing. |

### Queue endpoints

Minimum mobile contract:

```http
GET /api/v1/queue
POST /api/v1/queue/items
POST /api/v1/queue/items/{queueItemId}/retry
DELETE /api/v1/queue/items/{queueItemId}
PUT /api/v1/queue/reorder
```

`PUT /api/v1/queue/reorder` request:

```json
{
  "queueItemId": "q_01j...",
  "toPosition": 2
}
```

The client should keep slide/reorder interactions local-feeling, but server queue projection must remain coherent enough for refresh/polling during the MVP smoke.

### Polling / updates

For MVP, polling is enough:

- Poll `GET /api/v1/queue` every 1-2 seconds while any item is not terminal.
- Stop aggressive polling when all items are `playable` or `failed`.
- WebSocket progress can remain optional.

## 4. Playback URL contract (#43)

Use the existing signed URL endpoint and response shape from `backend/internal/api/playback.go`:

```http
POST /api/v1/playback/urls
Authorization: Bearer <token>
Content-Type: application/json
```

Request:

```json
{
  "trackIds": [123],
  "ttlSeconds": 600
}
```

Response:

```json
{
  "urls": [
    {
      "trackId": 123,
      "url": "http://127.0.0.1:9000/omp-audio/...signed...",
      "expiresAt": "2026-06-03T04:12:00Z",
      "contentType": "audio/mpeg",
      "sizeBytes": 1234567,
      "etag": "...",
      "storageKeyVersion": "..."
    }
  ],
  "unavailable": []
}
```

Known backend behavior to preserve:

- Default TTL: 10 minutes.
- Minimum TTL: 1 minute.
- Maximum TTL: 30 minutes.
- Batch limit: 50 track IDs.
- Missing `storage_key`: unavailable item with `code=audio_unavailable`.
- Missing object: unavailable item with `code=artifact_missing`.

Client behavior:

1. Only call this endpoint for `playbackState=playable` queue items with `trackId`.
2. Treat signed URLs as bearer credentials; do not persist them beyond app runtime cache.
3. Refresh before expiry when practical, e.g. when `expiresAt - now < 60s` and track is current or up-next.
4. If direct object URL playback fails with 403/expired-like error, request a fresh URL once before showing error.
5. If backend returns `audio_unavailable` or `artifact_missing`, move the UI item into recoverable unavailable/error display. Do not fall back to proxy streaming as the normal path.
6. The audio player must never construct an `AudioSource.uri` from an empty string for a pending item.

Storage/CORS requirements for #44:

- MinIO/object storage must allow Flutter Web origin for GET/HEAD.
- Range requests must work for browser seeking.
- Bucket must not be public-anonymous as a shortcut.

## 5. Integration order and PR stacking

### Existing Kanban graph

The current graph is valid and should not be deadlocked:

1. `t_f96bdbf8` planner contract, this card.
2. `t_f8a3e7f7` backend foundation PR, parented to planner.
3. Backend exact-head gates, parented to backend PR:
   - `t_52f9702d` QA
   - `t_ee835602` review
4. `t_7c959c42` frontend PR, parented to backend PR.
5. Frontend exact-head gates, parented to frontend PR:
   - `t_f8358bab` QA
   - `t_eabd0e5d` review after frontend QA
6. `t_cb3e0dfc` final #44 e2e smoke, parented to backend QA/review and frontend QA/review.
7. `t_ef58de8b` review #44 smoke evidence, parented to e2e smoke.
8. `t_84859621` ops release/closeout, parented to all gates.

### Backend PR expectations

Backend should be one PR if it stays coherent; split only if the branch becomes too wide to review.

Required backend order inside the PR/stack:

1. Fix #37 migration startup first.
   - Fresh local DB must get the full schema.
   - Do not hide missing tables behind lazy creation.
2. Add discovery provider interfaces and fake-provider tests (#40).
3. Extend queue/download models for source-backed pending items (#42).
4. Implement real download-to-MinIO worker path (#39).
5. Wire queue item resolution from job completion to `trackId` + `playable`.
6. Keep signed URL endpoint compatible with the existing #23/#43 contract.
7. Add deterministic fixture storage/playback smoke if #38 is small enough; otherwise explicitly hand off what remains fixture-only.

Backend handoff must include:

- PR URL or branch/compare URL.
- Exact head SHA.
- Whether it includes #37, #38, and #39 or which remain blockers.
- Changed files.
- Targeted Go tests and smokes run.
- Exact API deltas from this contract if any.

### Frontend PR expectations

Frontend starts after backend handoff because it needs concrete API shape. It may stack on the backend PR branch/head if main does not have the API yet.

Required frontend order:

1. Add typed models for `DiscoveryCandidate`, provider status, queue item playback states, and playback URL descriptor.
2. Add API client methods for discovery search, source queue insertion, queue polling/reorder/retry/remove, and playback URL refresh.
3. Add mobile discovery UI with result list and add/queue action (#41).
4. Update queue UI to render pending/downloading/processing/uploading/playable/failed states (#42).
5. Prevent non-playable queue items from entering `AudioPlayerService` as empty/invalid URLs.
6. For playable items, request signed URL and feed the direct object URL to the web audio player (#43).
7. Add recoverable UI for URL expiry/storage unavailable/fetch failure.
8. Verify 320px/390px mobile widths for search, queue states, and slide/reorder while playback is active or simulated.

Frontend handoff must include:

- PR URL or branch/compare URL.
- Exact head SHA.
- Backend branch/head it was stacked on, if any.
- Flutter test/analyze/build evidence actually run.
- Mock-vs-real backend caveats.

### Merge strategy

Preferred atomic route:

1. Merge backend foundation only after backend QA and review both pass exact live head.
2. Rebase/restack frontend PR onto merged backend or exact approved backend head.
3. Merge frontend only after frontend QA and review pass exact live head.
4. Run #44 e2e smoke against the combined exact heads.
5. Ops closes #40-#44 only according to actual merged evidence.

If backend and frontend are stacked before backend merges:

- Every child gate must record exact head SHA and base/head relationship.
- If a parent PR head changes after a gate, the gate is stale; create fresh gates.
- Do not unblock stale QA/review cards and treat them as approval for different code.

## 6. Final #44 smoke order

#44 is the final integration gate, not a vibes checklist.

### Prerequisite verification

Before running #44 smoke, QA must verify:

1. Backend PR live head equals backend QA/review approved head.
2. Frontend PR live head equals frontend QA/review approved head.
3. #37 evidence exists: fresh DB startup has all required tables.
4. #39 evidence exists: real worker can store downloaded audio in MinIO and set `tracks.storage_key`.
5. If using #38 fixture path, mark it as fixture evidence only.

### Smoke sequence

1. Clean local low-memory stack.
   - Use documented cleanup command from `scripts/local-low-memory.sh` once backend PR updates it.
   - Expected: containers/network/low-memory volumes are removed.
2. Start low-memory stack with MinIO and download worker enabled.
   - Real download smoke must use `WORKER_COUNT=1`.
3. Create/login a test user.
4. Search discovery endpoint for a known small source.
   - Record query, provider, candidate ID, and whether provider was live or fake/fixture.
5. Add source candidate to queue.
   - Record returned `queueItemId` and `downloadJobId`.
6. Observe queue/job state transitions.
   - Required: queued -> downloading or processing -> uploading -> playable, or a classified failure.
7. Verify database and MinIO artifact.
   - DB track row has `storage_key` and `file_size_bytes`.
   - MinIO stat/head confirms object exists.
8. Start Flutter Web mobile viewport.
   - No Android, Gradle, APK, emulator, or SDK commands.
9. Load queue on mobile web.
   - Pending/failed/playable display must be clear.
10. Play the playable item via signed URL.
    - Verify direct object URL path, not backend proxy path, is the normal route.
11. Reorder/slide queue item while playback continues or while a realistic playback simulation is active.
12. Cleanup stack and record logs/artifacts.

### Failure classification

The #44 QA handoff must classify failure as exactly one primary bucket plus notes:

- `discovery`
- `download`
- `storage`
- `queue`
- `playback_url`
- `mobile_ui`
- `environment`
- `stale_head`

Fixture-only caveat:

- If QA uses a seeded MinIO fixture because live providers are flaky, #38/#43 may pass and storage/playback may be proven, but #40/#39/#44 live discovery/download acceptance remains unproven unless the worker actually processed a real source candidate.

## Acceptance checklist for downstream workers

Backend worker must not complete unless:

- [ ] Full migrations run on fresh startup (#37).
- [ ] Discovery search endpoint is authenticated and returns normalized candidates (#40).
- [ ] Provider failures are isolated and tested (#40).
- [ ] Queue can hold source-backed non-playable items (#42).
- [ ] Download worker stores audio in MinIO and sets track storage fields (#39).
- [ ] Queue item resolves to `playable` with a `trackId` when download completes (#42).
- [ ] Signed URL endpoint remains compatible with #43.

Frontend worker must not complete unless:

- [ ] Mobile discovery UI calls the backend contract (#41).
- [ ] Add/queue action creates a source-backed queue item (#41/#42).
- [ ] Queue UI renders all states honestly (#42).
- [ ] Non-playable items cannot crash playback (#42).
- [ ] Playable items request signed URL and use direct MinIO/object URL (#43).
- [ ] URL expiry/storage failure is recoverable (#43).
- [ ] Mobile web widths are checked without Android/native tooling.

E2E QA must not pass #44 unless:

- [ ] Backend and frontend exact-head gates are current.
- [ ] #37 and #39 evidence exists.
- [ ] Search -> queue -> download/store -> playable -> mobile web playback is exercised.
- [ ] Worker concurrency is safe (`WORKER_COUNT=1` for real download).
- [ ] Cleanup reaps local resources.
- [ ] Evidence distinguishes live source proof from fixture proof.
