# Device downloads (native preview)

## Scope and selection

Device downloads are explicit account/server-scoped copies, not backend `/downloads` import jobs. `DeviceDownloads` owns staged transfers and the bounded index under the application's no-backup directory. Library admission uses its acknowledged `LibraryTrackCapture`. Account epochs revoke pending actions and local read handles; scope keys include the canonical endpoint and account ID.

The installed Media3 ExoPlayer artifact already contains `offline.DownloadManager`; using it would not require guessing a new downloader dependency. Its Android database/cache lifecycle would still need custom scope keys, refreshed descriptor admission, rejected-index handling and lease-aware removals. This slice instead uses the existing OkHttp client for full immutable objects and one private index. No dependency or second playback owner was added. Media3 still owns playback and queue state.

## Storage invariants

- Transfer publication is staged, synced, exact-size checked and atomically promoted. Index publication uses a synced temporary file plus atomic replacement.
- Descriptor metadata comes from the existing authenticated API. The index retains byte size, SHA-256, MIME, optional ETag/storage version and bounded display metadata, never signed URLs or credentials.
- Each artifact needs an independent app-created ownership receipt matching its scoped relative UUID filename, size and hash. An index path alone cannot authorize playback or deletion of a foreign UUID-named file.
- Initial unreadable/future/missing-with-existing-files indexes and externally changed bytes refuse ordinary writes. Unknown bytes are preserved; there is no silent reset, scan-to-adopt or recursive cleanup.
- Symlinks and traversal are refused. Cleanup checks the directory chain again instead of following a replaced parent into foreign files. This is an app-private single-owner store, not a security boundary against another process concurrently rewriting the sandbox.
- In-flight rows reconstruct as Interrupted. Validation checks both size and digest before device availability or a new lease. Reconstruction is not normal-process-death evidence.
- A transfer incarnation survives progress row replacement, so Cancel still works on a retained progress callback but cannot cancel a replacement retry. Progress is published synchronously before terminal state.
- Confirmed removal drops discoverability first. Existing read handles survive until close; deletion is deferred for leased files. Unknown/corrupt files are preserved. Backend Library membership is never mutated.

## Product and playback

Library track menu: Download to device / Open Downloads. Downloads: progress, cancel, retry, validated device playback, per-row remove and clear with confirmation. Current canonical SoundQ primitives are used; this functional composition does not claim final R4 design approval.

`SignedAudioDataSource` selects a validated private read lease before fetching any descriptor. It preserves the opaque `soundq://` URI, local seek and bounded read semantics, and account/grant checks. It does not expose a file URI or signed URL in controller metadata.

## Verification boundaries

`DeviceDownloadsTest` uses trusted real loopback TLS with generated WAV bytes and an actual descriptor. It proves exact transfer, atomic publication, store reconstruction and exact local bytes after the fixture server closes, plus cancellation, retry, scopes, rejected indexes, leases, foreign files and symlink refusal.

`OfflineDownloadsJourneyTest` is a compiled ordinary `MainActivity`/login/Library/Downloads/Media3 journey under `ProductFixtureRunner`. It includes cancel/retry, Activity recreation, network-blocked playback, local range reads through the real data source, and confirmed clear without Library mutation. Activity recreation is not process restart. Runtime execution, verified old normal-process absence/relaunch, native decoder acceptance and final design remain parent-owned gates; compiling the test does not establish them.

Known limitations: foreground app-lifetime transfers only (no background download service/resume); interrupted stages and crash-orphaned ownership files are preserved rather than auto-deleted; no rejected-store destructive reset; no cross-process writer lock or power-loss durability claim.
