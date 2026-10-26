# Opt-in production-root EPHEMERAL STORAGE renderer diagnostic

Bounded successor to the separately reviewed filesystem fixture. It removes path
bootstrap entirely: no input files, source-manifest reads, output directories,
settings workaround, permission expansion, or bootstrap HTTP endpoint. Default-off
production behavior is unchanged. This is a renderer diagnostic, not disk/cache,
artwork acquisition, audio, full-app, or matched-native performance evidence.

The parent owns source/artifact verification, independent review, profile build,
actual launch, finite private report broker, backend, credentials, process receipt,
shutdown, and publication. Implementation workers only edit/analyze/unit-test;
no commits, app builds/launches, signer or entitlement changes are required here.

## Admission contract

One compile-time switch: `SOUNDQ_PERFORMANCE_FIXTURE=true` (default false).
Preflight precedes binding, preferences, token storage and database initialization.
Opt-in requires native macOS profile mode and these exact build defines:

- `OMP_API_BASE_URL=http://127.0.0.1:54761/api/v1`
- `SOUNDQ_FIXTURE_SOURCE_COMMIT`: 40 lowercase hex
- `SOUNDQ_FIXTURE_SOURCE_TREE`: 40 lowercase hex
- `SOUNDQ_FIXTURE_SOURCE_SHA256`: 64 lowercase hex

Resolved API endpoint must equal that literal, without aliases, extra paths,
queries or trailing slash. Runtime environment must contain
`SOUNDQ_FIXTURE_DISPOSABLE=1` and `SOUNDQ_FIXTURE_DESCRIPTOR`, JSON bounded to
16 KiB UTF-8 with exactly nine string fields:

```json
{"schema":"soundq.flutter.fixture.process.v1","endpoint":"http://127.0.0.1:54761/api/v1","email":"<disposable-account>","password":"<private>","run_id":"<run-token>","source_commit":"<40-lowerhex>","source_tree":"<40-lowerhex>","source_manifest_sha256":"<64-lowerhex>","report_token":"<64-lowerhex>"}
```

Source fields must equal compiled pins. Run ID matches
`[A-Za-z0-9][A-Za-z0-9_.-]{0,79}` exactly. Email/password are nonempty and bounded
to 320/4096 UTF-8 bytes. Report token is exactly 64 lowercase hex. Unknown keys,
wrong types, missing keys and invalid pins fail closed. Credentials and report
token stay in private process environment, never build defines, logs, or reports.
No former `ROOT`, `CREDENTIALS`, `SOURCE_MANIFEST`, `RUN_ID`, or `OUTPUT` environment
input participates in admission.

Descriptor source identity is an external assertion, not authenticated compilation.
Parent must independently verify manifest bytes against exact compiled source,
compiler arguments, final post-signing artifact hashes and launch/process receipt.
App performs no source-byte verification or filesystem access for admission.

## Storage and cache boundary

All SecureStorage constructors retain the existing single in-memory token backend
and session epoch/retirement/refresh fences. Login still uses real AuthState,
AuthService and unified authenticated API client against the disposable endpoint.
SharedPreferences uses the process-wide ephemeral platform adapter. Preferences,
queue/settings restart persistence and plugin storage timing are excluded.

Only `main.dart` constructs production `OfflineDatabase`. Its existing instance
and opening-future retention remain intact; fixture databasePathProvider returns
sqflite's `inMemoryDatabasePath`. Real native sqflite opens the production schema;
no fake DB or alternate artwork schema shares this handle. After registration,
real factory database root is pinned to `/dev/null/soundq-fixture-no-disk` and read
back without native path dispatch. Nothing creates that impossible directory.
Legacy default lookup therefore cannot discover personal storage.

Process-wide PathProviderPlatform refuses every destination with fixed
`StateError('fixture-filesystem-refused')`, including external Android methods.
Download/cache-directory getters also throw. No generated `/tmp` path or personal
fallback exists. Downloads, playback-cache files, prepared local assets and disk
performance are excluded operations. Pinned just_audio 0.10.5 AudioPlayer
constructor calls `_removeOldAssetCacheDir`; its outer catch swallows refused
`getTemporaryDirectory` before constructing/deleting an OS directory. Actual
playback/asset preparation remains excluded and is never requested by this journey.

AudioService.init eagerly selects a cache even without artwork. Fixture injects
one `CacheManager(Config(..., repo: NonStoringObjectProvider(), fileSystem:
MemoryCacheSystem()))`, using public flutter_cache_manager 3.4.1 exports. The same
instance becomes CachedNetworkImageProvider.defaultCacheManager before app start.
Existing locked 3.4.1 becomes direct dependency; no package version changes.
MemoryCacheSystem uses package:file's memory filesystem; its temporary directory
is virtual, not an OS path. NonStoringObjectProvider excludes disk metadata and
legacy migration. Backend fixture must return 500 tracks with artwork `none`;
production placeholder rendering remains real. Actual image acquisition, cache
persistence and artwork performance are excluded. Native audio/plugins unchanged.

## Journey and report custody

`actual_root_profile_fixture.dart` calls production.main, uses mounted production
router `/library`, warms ordinary API pagination to 500 list slots, and scrolls
actual ListView controller. No replacement root, test binding, injected rows,
fake audio, synthetic cursor or motion override. Framework/platform error capture
starts before production main. Playback must stay idle. Populated idle lasts 3.2s;
scrolling uses four 2s legs with destination and elapsed-duration completion checks.

Real FrameTiming supplies all six phase timestamps, frame number, UI/raster/span/
vsync overhead. Explicit boundary frames define `(start,end]` using scheduler
system-frame timestamps. Zero-frame windows fail. A 2s drain retains batching.
Report includes windows, legs, row witnesses, list slots, viewport and scale.
No inferred refresh rate, FPS/deadline, GPU, CPU/RSS, or native-audio claim.

Journey awaits `fixture.exportReport(report)`. App sends JSON only to fixed
`http://127.0.0.1:54762/report` using dart:io HttpClient, DIRECT proxy policy,
redirects disabled, 5s connection timeout and 10s total export deadline. Authorization
is `Bearer <report_token>`. Body is at most 16 MiB; fixed report schema/keys,
provenance, metadata and numeric frame/window/leg shapes are checked before send.
Unknown fields, paths/credentials, nonfinite values and unsupported statuses fail.
Parent broker accepts no output filenames from app and privately persists report
and reducer-compatible `{"rawFrames":[...]}`.

Success requires HTTP 200 and at most 4096 bytes of UTF-8 JSON with exactly:

```json
{"run_id":"<matching-run-token>","sha256":"<sha256-of-exact-request-body>","persisted":true}
```

Wrong run/hash, missing durable acknowledgement, redirect, HTTP error, invalid or
oversized acknowledgement, disconnect and timeout fail export with fixed
`soundq-fixture-report-export-failed` diagnostic and StateError. A journey's
`completed-diagnostic` field is not successful collection without acknowledged
custody. No app exit/kill occurs. Parent launch receipt must retain missing/failed
export and clean up its finite broker. No broker/server ships in app.

Every report labels `EPHEMERAL STORAGE`, placeholder-only memory artwork, excluded
operations and `full_app_accepted:false`. Audio remains
`unavailable-native-readback-not-proven`; no playback is requested. AudioPlayer's
extrapolated position or awaited pause cannot qualify native progress. Source
pins and reports are not compiler/process-start proof. Do not feed whole report
to matched_performance.py or claim matched native performance.

## Checks and remaining holds

Use writer-owned source and SDK copies with existing package cache, no downloads
or shared SDK mutations. Set TMPDIR to private scratch. No app build/launch in
writer lane. Analyzer/default-off auth and startup regressions plus opt-in tests
cover descriptor bounds, memory cache without paths, real factory no-dispatch,
constructor session fences, source ordering/mutation controls, leg completion,
report schema/bounds and fake-client transport acknowledgement failures.

```sh
flutter analyze --no-pub lib/main.dart lib/core/performance integration_test/actual_root_profile_fixture.dart test/performance_fixture_test.dart test/performance_fixture_source_test.dart test/performance_fixture_export_test.dart
flutter test --no-pub --concurrency=1 test/performance_fixture_test.dart test/performance_fixture_source_test.dart test/performance_fixture_export_test.dart test/api_client_auth_interceptor_test.dart test/desktop_application_startup_test.dart
flutter test --no-pub --concurrency=1 --dart-define=SOUNDQ_PERFORMANCE_FIXTURE=true test/performance_fixture_test.dart test/performance_fixture_source_test.dart test/performance_fixture_export_test.dart
```

Parent separately owns dependency/artifact contract verification, profile compile,
native plugin/schema runtime qualification, actual sandbox launch and report broker
persistence. Unit fake-client transport is not live networking or app-runtime
qualification. Failure logs remain private evidence; no fabricated successful run.
