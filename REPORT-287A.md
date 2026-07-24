# TASK-287A Report — Truthful Audio Quality

Date: 2026-07-24 UTC  
Branch: `feat/287-truthful-quality`  
Base: `origin/main` at `9b874ac03905797760d85847be03fbc2c9d365ea`  
Tested implementation head: `06610dd717ff7539711af0813ecce32c8ea17f88`

## Outcome

OMP now probes the one stored audio artifact with `ffprobe`, persists immutable
artifact facts, backfills existing rows through a bounded maintenance pass, and
exposes those facts through library, playlist, history, and playback responses.
The client no longer offers fake quality controls. It formats and renders only
server-reported facts and renders nothing when every fact is absent.

No transcoding, quality request parameters, signed-URL behavior changes,
gapless/crossfade behavior changes, engine changes, queue-controller changes,
or secondary schema authority were introduced.

## A. Backend

### A1. Probe, persist, and expose artifact facts

Files:

- `backend/internal/db/db.go`
- `backend/internal/db/track_repository.go`
- `backend/internal/processor/processor.go`
- `backend/internal/processor/processor_test.go`

Implemented:

- Added idempotent `tracks` columns in `db.go` only: `codec`,
  `bitrate_kbps`, `sample_rate_hz`, `channels`, `content_type`, plus the
  internal maintenance-ordering timestamp `audio_quality_probe_attempted_at`.
- Probes the completed local artifact before upload. Incomplete or invalid
  probe output fails ingest before the object is stored.
- Persists probe facts in the new-track insert.
- Uses the probe-derived MIME type as stored-object metadata, including
  container-aware AAC handling.
- A duplicate ingest with a legacy row probes the existing row's referenced
  object rather than assigning facts from the newly downloaded, potentially
  different artifact.

### A2. Bounded existing-row backfill

Files:

- `backend/internal/api/maintenance.go`
- `backend/internal/api/maintenance_quality_test.go`
- `backend/internal/db/track_repository.go`
- `backend/internal/db/track_repository_integration_test.go`
- `backend/internal/processor/processor.go`
- `backend/internal/processor/processor_test.go`

Implemented:

- Extended `POST /api/v1/maintenance/repair` with explicit
  `audioQuality: true`.
- Default batch size is 50 and maximum batch size is 200.
- Complete rows skip idempotently.
- Failed/corrupt objects are logged and returned per row without terminating
  later repairs.
- Failed rows rotate through `audio_quality_probe_attempted_at`, so one corrupt
  object cannot starve later candidates.
- Combined quality plus metadata/analysis requests reserve bounded capacity for
  both candidate classes and deduplicate overlaps without starving either
  class. A combined `limit: 1` request is rejected because fair progress is
  impossible.

### A3. Client-facing projections and issue #293 source URL

Files:

- `backend/internal/db/library_repository.go`
- `backend/internal/db/playlist_repository.go`
- `backend/internal/db/play_event_repository.go`
- `backend/internal/api/library.go`
- `backend/internal/api/playlist_handlers.go`
- `backend/internal/api/play_event_handlers.go`
- `backend/internal/api/playback.go`
- `backend/internal/api/playback_test.go`
- `backend/internal/api/track_analysis_response_test.go`

Implemented:

- Library payloads expose snake-case `codec`, `bitrate_kbps`,
  `sample_rate_hz`, `channels`, `content_type`, and `file_size_bytes`.
- Library payloads now expose `source_url`, closing the scoped #293 Share gap.
- Playlist, recently-played, history, and top-track payloads expose equivalent
  camel-case fields consistent with those APIs.
- Playback descriptors expose codec, bitrate, sample rate, channel count,
  content type, and size so every remote playback origin can carry truth to
  the player.

### A4. Ingest/backfill/API contract

File:

- `backend/internal/api/audio_quality_contract_integration_test.go`

Coverage:

- Ingests deterministic fixture audio.
- Reads the stored object and runs an independent real `ffprobe`.
- Asserts exact equality with library API facts, `source_url`, MIME type, and
  object size.
- Clears facts, backfills them through the maintenance HTTP handler, and
  repeats the equality assertion.
- Proves a second pass is idempotent.
- Proves corrupt-object failure is nonfatal and bounded progress resumes.
- Includes a real `storage.Client`/MinIO path, not only an in-memory storage
  fake.

## B. Client

### B1. Delete inert quality settings

Files:

- `client/lib/core/models/settings_model.dart`
- `client/lib/core/providers/settings_provider.dart`
- `client/lib/features/settings/settings_screen.dart`
- `client/test/settings_model_test.dart`
- `client/test/settings_quality_removal_test.dart`

Implemented:

- Deleted `streamingQuality`, `downloadQuality`, `AudioQuality`, both selectors,
  the picker, and the “Always 320k” claim.
- Old persisted quality keys are ignored safely and disappear on the next
  serialization.
- Gapless and crossfade controls remain unchanged.

### B2. Shared Track metadata

Files:

- `client/lib/shared/models/track.dart`
- `client/test/shared_track_quality_test.dart`
- `client/test/home_service_test.dart`
- `client/test/playlist_service_test.dart`
- `client/test/library_service_liked_filter_test.dart`

Implemented:

- Added nullable codec, bitrate, sample-rate, channel-count, content-type, and
  file-size facts.
- Parsing tolerates absent fields, snake/camel casing, OpenSubsonic aliases,
  numeric strings where appropriate, and the playback `sizeBytes` alias.
- Library, playlist, and history service paths retain the facts into playback
  payloads.

### B3. Truthful formatting and rendering

Files:

- `client/lib/shared/formatters/source_quality_formatter.dart`
- `client/lib/features/player/player_screen.dart`
- `client/lib/features/player/widgets/song_info_sheet.dart`
- `client/lib/core/audio/signed_audio_url_service.dart`
- `client/lib/core/audio/playback_source_resolver.dart`
- `client/lib/core/audio/playback_state.dart`
- `client/test/source_quality_formatter_test.dart`
- `client/test/playback_source_quality_test.dart`
- `client/test/signed_audio_url_service_test.dart`
- `client/test/playback_state_engine_test.dart`
- `client/test/player_screen_test.dart`
- `client/test/song_info_sheet_test.dart`

Implemented:

- One shared formatter emits only available segments, for example
  `MP3 · 137 kbps · 44.1 kHz · 2 channels · 3.2 MB`.
- Returns `null` when every fact is absent or unusable.
- Player and read-only song-info sheet render the shared result.
- Signed playback descriptors and refreshes preserve the facts for tracks
  launched outside Library.
- The modal is scroll-controlled, height-constrained, and stacks fact rows at
  narrow widths or large text scale; the 3× text regression test has no
  overflow.
- Downloads and playback continue to use the one original artifact.

## Verification

Test infrastructure:

- `scripts/dev test-infra-isolated`
  - Exit 0.
  - Worker-free Postgres healthy at `127.0.0.1:25224`.
  - Redis healthy at `127.0.0.1:26224`.
  - MinIO healthy at `127.0.0.1:27224`.

Backend:

- `scripts/lint backend`
  - Exit 0; no diagnostics.
- `OMP_POSTGRES_TEST_DSN='postgres://omp:omp_dev_password@127.0.0.1:25224/openmusicplayer?sslmode=disable' OMP_MINIO_TEST_ENDPOINT='http://127.0.0.1:27224' scripts/test backend`
  - Exit 0; every backend package passed.
  - Relevant uncached packages: `internal/api` 1.446s, `internal/db` 16.906s,
    `internal/processor` 2.141s, `internal/search` 0.579s.
- Focused affected-package run with the same Postgres/MinIO environment:
  `go test -p 1 ./internal/processor ./internal/api ./internal/db -count=1`
  - 303 tests passed across 3 packages.
- Real storage contracts:
  `go test ./internal/api -run 'Test(IngestQualityContractAgainstRealMinIO|IngestAndBackfillExposeStoredObjectFFprobeFactsThroughLibraryAPI)' -count=1 -v`
  - 2/2 passed.

Client:

- `cd client && flutter analyze`
  - Raw analyzer exit 1 from exactly 9 known pre-existing info-level findings:
    4 in `playlist_detail_screen.dart` and 5 in
    `match_suggestions_sheet.dart`.
  - No diagnostics in changed files.
- `cd client && flutter test`
  - Exit 0; 981 tests passed (baseline 966 plus 15 net new tests).
- Focused descriptor/origin/refresh/sheet run:
  - 46/46 passed.
- Focused player-modal run:
  - 10/10 passed.

Delivery:

- `scripts/agentic-harness`
  - Exit 0; `AGENTIC HARNESS OK`.
- `OMP_POSTGRES_TEST_DSN=... OMP_MINIO_TEST_ENDPOINT=... scripts/agentic-cycle --run --base origin/main --evidence /tmp/omp-287a-cycle.json`
  - Status `passed` at implementation head `06610dd`.
  - Delivery lint, backend lint, backend tests, client lint policy, and client
    tests all recorded exit 0.
  - Evidence: `/tmp/omp-287a-cycle.json`.
- `git diff --check`
  - Exit 0.

Resource closeout:

- `SERVER_PORT=18224 POSTGRES_PORT=25224 REDIS_PORT=26224 MINIO_PORT=27224 MINIO_CONSOLE_PORT=28224 scripts/local-low-memory.sh stop`
  - Exit 0.
  - Removed the isolated `omp-287-lane` Postgres, Redis, MinIO containers and
    network; persistent test volumes were retained.

## Adversarial Review

One broad pass ran before final expensive gates.

Findings fixed in one batch:

1. Playback facts were emitted by the backend but dropped by
   `SignedAudioDescriptor`, and playlist/history projections omitted them.
   Added descriptor parsing/refresh propagation plus playlist/history
   repository and API coverage.
2. Combined maintenance could starve metadata/analysis work and could falsely
   re-probe complete rows because normal candidates lacked scanned quality
   fields. Added fair bounded selection, overlap dedupe, full scans, and
   regression tests.
3. Stored-object MIME could disagree with probed truth. Upload now uses the
   probe-derived, container-aware content type.
4. The integration contract used fake storage only. Added a real MinIO contract
   with independent `ffprobe`.
5. Duplicate legacy ingest could leave missing facts or assign facts from the
   wrong artifact. It now probes the existing row's referenced object.
6. A long source row could overflow the song-info modal at narrow width and
   large text. Added scrolling, constraints, stacked rows, and a 3× text test.

A single focused re-review of those fix hunks found no unresolved P0/P1 and no
concrete regression. No second broad review was opened.

## Commits

- `4cc89a62322a32fe9b51d27e2d88cc2681cfb644`
  `feat(backend): persist artifact quality facts`
- `06610dd717ff7539711af0813ecce32c8ea17f88`
  `feat(client): show truthful source quality`

## Deviations and reasoning

- Used `scripts/dev test-infra-isolated` rather than the fixed-port
  `scripts/dev test-infra` because this is a parallel worktree. The same
  worker-free Postgres/Redis/MinIO topology was used, with explicit ports
  recorded above.
- Android dogfood was not run. The central claim is deterministic metadata
  persistence/projection/formatting, fully covered by real ffprobe, real MinIO,
  API, model, and widget contracts. No audible transport, codec playback,
  gesture, notification, engine, or queue behavior changed.
- `TASK-287A.md` remains untracked as user-supplied task input and is not part
  of the feature commits.

## Residual risks

- Duplicate ingest still uploads a new object before identity deduplication
  resolves the existing row, preserving the pre-existing orphan-object
  behavior. Generic orphan cleanup is outside this slice.
- If a legacy row's referenced object is missing or corrupt, duplicate ingest
  fails closed rather than assigning facts from different fresh bytes.
  Replacement policy is intentionally undefined here.
- `ffprobe` currently shares one bounded stdout/stderr buffer. A diagnostic on
  stderr with exit 0 could theoretically make otherwise valid JSON fail
  closed; this was not observed for the MP3/WAV production paths.
- The offline SQLite Track round-trip does not persist the new quality
  metadata, so the line can disappear after an offline-app restart. The
  downloaded original artifact remains unchanged and playable; online and
  signed-descriptor paths restore the facts.
