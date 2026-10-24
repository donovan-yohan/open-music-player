# First native slice acceptance packet

Outcome: An independently runnable additive native preview with a real shared
Rust core, not a replacement for the supported Flutter app.

Owner: Overnight coordinator, feat/native-clients. GUI/audio/emulator/account and
fixture custody exclusive to coordinator. Publication transfers to the parent
only after a frozen immutable source manifest and independent source review.

Reference: frozen 819-file desktop successor overlay, reference-manifest.json in
the external mission evidence home. Content/audio inventories contain 101
semantic rows plus explicit unread areas. Full parity is not established.

Slice: Production Go auth -> Rust API coordination -> native paged library ->
selection -> bounded container-correct cache -> actual AVPlayer/MediaPlayer ->
pause/resume/seek/retry -> OS session dispatch. Purposeful platform differences:
AppKit table/keyboard desktop, RecyclerView/touch Android, no fabricated tabs.

Required acceptance:

- Rust unit/lifecycle and ABI tests, including held HTTP synchronous revocation,
  stale native report and enqueue-owned old seek rejection.
- Real Go auth/library/playback handlers and canonical migrations in a uniquely
  owned empty fixture database. No shared DB TRUNCATE, production deployment or
  live-user account needed.
- Native Mac bundle and Android arm64 APK built from a clean tracked snapshot,
  hashes recorded; Swift/C and Kotlin/JNI consumers actually execute.
- Actual cold and warm platform decoder progress, pause cursor stability, seek,
  resume, retry and session/background controls. Compiler success is separate.
- Populated idle/audio-active workloads and raw source-bound performance samples,
  run counts/spread; retain Instruments and Android frame/Perfetto receipts.
- No staged credentials survive qualification; predecessor app/data untouched.
- Independent review with no unresolved blocking native findings before parent
  publication. Exact-head hosted checks and protected merge remain parent-owned.

Current deliberate exclusions, never called parity: full listening queue editing,
prepared Opus/stem/mix engine composition, playlists/import queues/downloads,
Connect/Jam, biometric lock, production legacy data migration, all-container and
cold offline restart, Windows output and Flutter removal. All are recorded gaps.

Risk seams: asynchronous native readiness after pause; cancellation while HTTP
holds core mutex; refresh-token persistence; account/endpoint namespace; prepared
vs ordinary codec support; physical decoder retirement; UI content topic updates;
uncertain remote mutation outcomes; signed-URL/credential leakage. Native sample
callbacks do no Rust/FFI work. Delivered immutable cache files are conservatively
retained until process/core teardown, not reclaimed on pause/EOF.

Commands: scripts/test native; scripts/build native-macos;
scripts/build native-android; scripts/lint delivery (modern Bash required);
python3 native/tests/core_fixture.py --help;
python3 native/tests/android_journey.py --help. Platform and artifact receipts live
outside source under soundq-native-port-evidence, never private fixture secrets.
