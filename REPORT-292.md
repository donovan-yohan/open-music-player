# Issue 292 — Unification Cleanup Report

## Delivery state

- Branch: `chore/292-unification-cleanup`
- Base: `f988290`
- Implementation code head: `a95b1d8` (before the report-only amend)
- Scope: 64 implementation/test files, 1,407 insertions and 1,668 deletions
- `TASK-292.md` and `ISSUE-292.md` are input artifacts and remain intentionally untracked and excluded from the commits.

## Issue-item verification

| Item | Status | Result and key files |
| --- | --- | --- |
| Dead core `Track` and duplicate `MBSuggestion` | Done | Zero-reference/import checks in `client/lib` and `client/test` confirmed the duplicate model was dead. Deleted `core/models/track.dart` and `mb_suggestion.dart`; retained search-only types in `core/models/search_result.dart`. |
| Dead `LibraryTrack`, `TrackTile.fromLibraryTrack`, and parallel search UI | Done | Deleted `shared/models/library_track.dart`, the dead constructor, `features/search/screens/search_screen.dart`, and its three private tile widgets after reference checks. Canonical shared `Track` and the live search screen remain. |
| Queue model `Track` → `QueueTrack` | Done | Dedicated mechanical rename across `models/track.dart`, queue provider/state/screens/widgets, waveform/timeline users, and their tests. Imports no longer need aliases solely to disambiguate this model. |
| Analysis forwarding and one playback-payload builder | Deviated intentionally | Added `analysisPlaybackFields` in `models/track_analysis.dart` and `buildPlaybackPayload` in `models/playback_payload.dart`; all shared/search/queue/album paths use them, including album analysis. Liked tri-state, trimmed source URL, quality extras, and camel-over-snake resolver behavior are preserved. The builder centralizes duration and ID policy but retains source-specific `int`/`String` IDs because changing established expectations was forbidden; `PlaybackSourceResolver` normalizes both forms at ingress. |
| Dead queue repeat/shuffle fields | Done | Removed `repeatMode`/`shuffled` and provider `copyWith` plumbing from `models/queue_state.dart` and `providers/queue_provider.dart`; persistent shuffle/repeat truth remains in `QueueTimelineController`. |
| Backend phantom playback position | Done | Deleted uncalled `Service.SetCurrentPosition` from `backend/internal/queue/queue.go`. Per scope, the schema-facing `playqueue` vocabulary remains with a comment deferring its rename to the next schema change. |
| Collection launch shuffle | Done | Added injectable-RNG `playCollectionOrder` in `core/audio/queue_ordering.dart` and migrated album, playlist, liked-song, and local-library launches. A one-shot shuffle deliberately does not enable persistent controller shuffle. |
| Shared audio-source resolution and stable identity | Done | Added the download → cache → signed-remote policy in `core/audio/audio_source_resolution_policy.dart`; both source resolvers use it. Conformance coverage asserts ordering/invalidation. `voice_pool.dart` now reuses `playback_cache_manager.audioObjectIdentity`. |
| Shared byte formatter | Done / partly already resolved | The old cache-provider call site was already gone on this base after the settings/cache rewiring. The remaining download-state, downloads-screen, and source-quality formatting now use `shared/formatters/byte_formatter.dart`, including the GB branch. |
| Dead engine alternate authorities | Done | Removed `MixNowPlayingInfo`, `nowPlayingStream`, and `loadSequentialQueue` from `core/engine/playback_engine.dart`; canonical timeline/playback state remains authoritative. |
| Dead offline playlist tables | Done, non-destructively | Fresh databases no longer create `playlists`/`playlist_tracks`, and unused accessors were removed from `core/storage/offline_database.dart`. Existing upgraded databases retain the legacy tables because this cleanup intentionally adds no destructive migration. |
| Unconsumed `MixSessionClip` fades | Done | Removed `fadeInMs`/`fadeOutMs` fields and serialization from `core/audio/playback_session.dart`; overlap-derived envelopes remain the only fade path. Old snapshots remain readable because unknown legacy keys are ignored. Persistence tests cover the new round trip. |

## Commits

These are the four conventional implementation commits before the report-only amend:

1. `5074a2e` — `refactor: remove redundant client authorities`
2. `4378ae7` — `refactor(client): centralize source and display helpers`
3. `2c6d89d` — `refactor(client): rename queue track model`
4. `a95b1d8` — `refactor(client): unify playback payload building`

## Verification

| Command | Exact result |
| --- | --- |
| `cd client && flutter analyze` | Exit 1 with exactly 9 known pre-existing infos; 0 warnings and 0 errors. |
| `cd client && flutter test` | Passed: 1,031 tests. |
| `go -C backend vet ./...` | Passed. |
| `go -C backend build ./...` | Failed only with `error obtaining VCS status: exit status 128`. |
| `GOFLAGS=-buildvcs=false go -C backend build ./...` | Passed. |
| `GOFLAGS=-buildvcs=false go -C backend test ./...` | Passed all packages. External integration infrastructure was not separately started; the package suite itself was green. |
| `scripts/agentic-harness` | Passed: `AGENTIC HARNESS OK`. |
| `scripts/agentic-cycle --run --base origin/main --evidence /tmp/omp-292-cycle.json` | Passed all planned delivery/backend/client gates, including 1,031 Flutter tests. Evidence: `/tmp/omp-292-cycle.json`. |
| `git diff --check origin/main...HEAD` | Passed. |

The agentic cycle conservatively classified the broad client/audio diff as
`mobile-audio-device` and listed Android dogfood as a manual gate. It was not
run because this batch makes no new Android/audio/gesture behavior claim: its
central claims are behavior-preserving model, serialization, persistence, and
source-policy invariants covered by focused conformance tests and the full
suite.

## Adversarial review

The broad review found:

- P1: explicit-empty analysis persistence could be collapsed. Fixed by preserving field presence and adding regression coverage.
- P2: the deferred backend vocabulary comment was ambiguous. Fixed to state
  explicitly that playback-flavored `playqueue` names move toward
  import/readiness terms at the next schema-touching change.
- P2: migrated shuffled-launch integration lacked a persistent-flag assertion.
  Fixed with a widget test proving one-shot shuffle starts playback without
  toggling persistent shuffle.

A focused re-review of the changed hunks found no remaining P0, P1, or P2 issues.

## Residual risks and caveats

- Existing SQLite installations keep the now-unused legacy playlist tables; only fresh schemas omit them.
- Playback payload IDs intentionally remain source-typed (`int` or `String`) and rely on canonical ingress normalization.
- The literal Go build is blocked by VCS metadata in this scratchpad worktree; disabling build-VCS stamping passed build and test compilation.
- Nine analyzer infos remain at the known baseline, with no warnings or errors.
- External backend integration services were not separately started; the full
  package suite passed. Android dogfood was not run for the rationale recorded
  above.
