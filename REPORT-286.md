# TASK-286 Delivery Report

Date: 2026-07-24

Branch: `feat/286-honest-surfaces-liked-sot`

Base: `origin/main` at `244046d`

Reviewed and fully tested implementation head:
`96fb460bd42501119ec28065806a42beba95c761`

## A. Liked Single Source Of Truth

Implemented `LikedTracksState` as the one account-scoped client authority over
the backend `track_favorites` persistence authority.

- `client/lib/core/services/liked_tracks_state.dart`
  - Stores the current per-track value exposed by `isLiked`.
  - Seeds collections, individual tracks, and playback payload values.
  - Applies optimistic like/unlike writes through `LibraryService`.
  - Rolls back every observing surface on an API failure.
  - Prevents an in-flight seed from overwriting an optimistic write.
  - Clears account-scoped state on logout without allowing a stale in-flight
    write to restore the previous account's value.
- `client/lib/main.dart`
  - Provides `LikedTracksState` app-wide and clears it when authentication ends.
- `client/lib/core/services/library_service.dart`
  - Defines the Library projection in one place and includes `is_liked`.
- `client/lib/features/library/library_screen.dart`
  - Seeds remote Library results and reads/toggles the notifier for row and
    action-sheet hearts. There is no widget-owned liked copy.
  - A row unliked under the Liked filter remains in the fetched list until the
    next refresh, avoiding mid-scroll removal.
- `client/lib/features/library/liked_songs_screen.dart`
  - Seeds fetched Liked Songs and reads/toggles the same notifier. Unliked rows
    remain until refresh.
- `client/lib/shared/models/track.dart` and
  `client/lib/core/audio/playback_source_resolver.dart`
  - Carry `isLiked` through playback JSON and `MediaItem.extras`.
- `client/lib/features/player/player_screen.dart`
  - Parses the backend track id from `MediaItem.id`, seeds from playback extras,
    renders the shared value, toggles through `LikedTracksState`, and disables
    the action for local-only or genuinely unknown tracks.

Regression coverage:

- `client/test/liked_tracks_state_test.dart`
- `client/test/library_service_liked_filter_test.dart`
- `client/test/library_track_row_layout_test.dart`
- `client/test/liked_songs_screen_state_test.dart`
- `client/test/player_screen_test.dart`
- `client/test/shared_track_playback_test.dart`

The real-surface tests share the notifier contract: the player mutation test
proves the write, while the Library and Liked Songs widget tests prove their
hearts rebuild from external notifier changes. Failure rollback and logout
generation behavior are asserted directly.

## B. Settings Surface Honesty

- Deleted the unused SharedPreferences estimate stub:
  `client/lib/core/providers/cache_provider.dart`.
- `client/lib/main.dart` now provides the real nullable
  `PlaybackCacheManager`.
- `client/lib/features/settings/settings_screen.dart`
  - Reads cache bytes from `PlaybackCacheManager.currentSizeBytes()`.
  - Clears only playback-cache-owned audio with
    `PlaybackCacheManager.clear()`.
  - Displays the separate `DownloadState` total without merging download and
    cache ownership.
  - Routes Downloads to `/downloads`.
  - Clears the real playback cache before logout when selected.
  - Disables the logout cache option with an honest reason on platforms with no
    playback cache.
  - Uses copy that explicitly leaves downloads and album artwork untouched.
- `client/test/settings_storage_section_test.dart` asserts the real size,
  clear call, Downloads navigation, and null-manager disabled state.

Streaming/download quality and delete-account behavior were not changed, as
required.

## C. Player And Library Action Honesty

- Added `share_plus` `12.0.2` in `client/pubspec.yaml` and lockfile.
- Player share opens the OS share sheet with `title — sourceUrl` and supplies a
  share origin for platforms that require one.
- Share is disabled with `No public source link` when the payload has no usable
  source URL.
- Removed the device/output-selection button.
- Replaced both enabled metadata no-ops with disabled controls and explicit
  tooltip/semantics reasons:
  - Fix metadata: no metadata editor yet.
  - Find match: no metadata editor contract yet.
- `client/test/player_screen_test.dart` asserts the device action is absent,
  missing-link share is disabled, and favorite is enabled and performs the
  notifier/API write.

## D. Playlist Membership Single Write Path

- The Library picker now calls
  `PlaylistService.addTracks(int, List<int>)` with integer ids.
- Deleted `LibraryService.getPlaylists`,
  `LibraryService.addTrackToPlaylist`, the duplicate string-id
  `client/lib/core/models/playlist.dart`, and its barrel export.
- `client/lib/shared/widgets/playlist_picker_sheet.dart` now uses the shared
  integer-id Playlist model.
- Removed the discovery/search `TrackActionSheet` playlist affordance because
  those results carry MusicBrainz/source ids, not a backend library track id.
  The removed action was guaranteed to send the invalid string payload; absence
  is honest until a real add-to-library/result-to-track-id contract exists.
- `client/test/library_track_row_layout_test.dart` asserts the picker invokes
  `PlaylistService.addTracks` with an integer id.
- `client/test/playlist_service_test.dart` asserts the exact payload
  `{"trackIds":[123]}`.

## E. Architecture Documentation

- Added `docs/adr/0004-liked-state-and-surface-honesty.md`.
- Added the `Liked State And Collections` authority chain and guardrails to
  `docs/context-map.md`.

The documents record:

- backend favorites as persistence authority;
- `LikedTracksState` as the sole client authority;
- no liked truth in playback, queue, or `MixSession`;
- no materialized Liked Songs playlist;
- `PlaylistService.addTracks` as the sole playlist-membership write path; and
- the act, honestly disable, or remove policy for visible controls.

## Adversarial Review

One broad review ran before the full gates. It found and batched these valid
issues:

- the cache dialog claimed it cleared album artwork although the real manager
  owns only temporary playback audio;
- the web/null-manager logout cache checkbox could be enabled but perform no
  work; and
- an older test still referenced the deleted optimistic-like helper and would
  have blocked the full suite.

Commit `96fb460` fixed all three. The focused re-review of those hunks found no
remaining P0/P1 issue. Boundary scans found no backend, `core/engine`,
`queue_timeline_controller.dart`, old playlist write, cache stub, or production
device-button changes/references.

## Verification Results

All requested commands were run from this worktree by the primary agent on
implementation head `96fb460bd42501119ec28065806a42beba95c761`.

### Flutter analyze

Command:

```text
cd client && flutter analyze
```

Exact result:

- Exit code: `1`
- Analyzer result: `9 issues found. (ran in 2.9s)`
- Severity: all 9 are info-level, known pre-existing diagnostics outside the
  changed files; there were no errors or warnings and no diagnostic in a
  TASK-286-changed file.
- Pre-existing locations:
  - `lib/features/playlists/playlist_detail_screen.dart:254`
  - `lib/features/playlists/playlist_detail_screen.dart:255`
  - `lib/features/playlists/playlist_detail_screen.dart:261`
  - `lib/features/playlists/playlist_detail_screen.dart:609`
  - `lib/shared/widgets/match_suggestions_sheet.dart:58`
  - `lib/shared/widgets/match_suggestions_sheet.dart:151`
  - `lib/shared/widgets/match_suggestions_sheet.dart:193`
  - `lib/shared/widgets/match_suggestions_sheet.dart:324`
  - `lib/shared/widgets/match_suggestions_sheet.dart:327`

This matches TASK-286's stated baseline of 9 known infos. The focused
changed-file analysis also reported `No issues found.`

### Flutter test

Command:

```text
cd client && flutter test
```

Exact result:

- Exit code: `0`
- Final line: `00:35 +950: All tests passed!`
- Total: `950` tests passed, `0` failed.

The focused TASK-286 regression selection also passed `29/29` before the full
suite.

### Delivery and boundary checks

```text
scripts/agentic-harness
```

- Exit code: `0`
- Result: `AGENTIC HARNESS OK`

```text
git diff --check origin/main...HEAD
```

- Exit code: `0`
- Result: no whitespace errors.

Production stale-authority scan:

- Exit code: `0`
- Result: no `addTrackToPlaylist`, `runOptimisticLikeToggle`, `cacheProvider`,
  `estimated_cache_size`, or `Icons.devices` reference under `client/lib`.

## Commits

- `1dd82357b6b8cf7037da1c897a5d36952702b746`
  `feat(client): unify liked and honest actions`
- `076cf4c8cb8a7314a6eb649da512c3d4d5fb8f1d`
  `docs(architecture): record liked authority`
- `96fb460bd42501119ec28065806a42beba95c761`
  `fix(settings): keep cache actions truthful`
- This report is packaged in a separate conventional
  `docs(report): record task 286 delivery` commit.

## Intentional Decisions, Deviations, And Residual Risks

- No backend file was changed. The current backend Library handler does not
  emit `source_url` in its selected response even though the repository row has
  that field. The client requests/parses/threads it correctly, and other shared
  Track payloads can supply it, but a Library-origin playback item will keep
  Share honestly disabled until that backend projection is added in a separate
  backend-authorized change.
- Discovery/search playlist action removal is intentional: those surfaces have
  no backend integer track id, so they cannot call the sole valid membership
  write path. Keeping the old action would preserve a guaranteed parse
  failure/400.
- The platform share sheet is structurally covered, including disabled state,
  payload preservation, and share origin. It was not exercised on a physical
  device in this client-only unit/widget task.
- No quality, gapless, crossfade, delete-account, backend, queue-controller, or
  engine work was included.
- `TASK-286.md` remains untracked and unmodified as the supplied work packet.

## Fix pass 2 (cross-model review)

The twelve review findings were handled as one coherent fix batch under the
rule that only backend-annotation-traceable values may seed
`LikedTracksState`. No finding was refuted.

| Finding | Action |
| --- | --- |
| 1 | Made `Track.isLiked` nullable, preserved absent `is_liked` as unknown in both payload factories, and made `toPlaybackJson`/`toJson` omit liked metadata when unknown. |
| 2 | Added conditional `isLiked` and trimmed `sourceUrl` passthroughs to `mediaItemToPlaybackJson`, with present/absent round-trip assertions. |
| 3 | Removed notifier seeding from both initial and paginated local/offline Library loads; an offline-style unknown row is tested not to overwrite a known true value. |
| 4 | Made the share handler await `share_plus`, disabled the web mailto fallback, and surfaces async failures through `Could not open the share sheet`. |
| 5 | Added request-start seed-version tokens and per-track local-write versions. Library and Liked Songs capture the version before each fetch, so a response begun before a now-settled toggle cannot revert it. |
| 6 | Tagged durable queue snapshots and live resolved `MediaItem` annotations with the JWT `user_id`. A different or unknown account strips durable liked/source metadata, while the player rejects still-live extras from another account. |
| 7 | Added an explicit disabled player branch and tooltip: `Liked status not loaded yet`. Local-only ids retain their separate honest unavailable reason. |
| 8 | Exposed `isToggling`, disabled Player and Liked Songs hearts during writes, and notified again when the write settles so both controls re-enable. |
| 9 | Reworded the disabled share tooltip to `Source link unavailable`. |
| 10 | Added regression assertions for a seed during an unresolved toggle, a second toggle being a no-op, and a non-numeric player item id producing a null favorite handler. |
| 11 | Added a `Provider<PlaybackCacheManager?>.value(null)` storage widget test asserting `Unavailable on this platform` and a disabled Clear button. |
| 12 | Added the backend-annotation-only seeding rule, nullable unknown state, offline/model-default prohibition, and stale-response guard to ADR 0004. |

### Verification

Focused regression command:

```text
cd client && flutter test \
  test/liked_tracks_state_test.dart \
  test/shared_track_playback_test.dart \
  test/queue_persistence_test.dart \
  test/player_screen_test.dart \
  test/liked_songs_screen_state_test.dart \
  test/settings_storage_section_test.dart
```

- Exit code: `0`
- Result: `46` tests passed, `0` failed.

Focused changed-hunk re-review command:

```text
cd client && flutter test \
  test/library_track_actions_test.dart \
  test/liked_tracks_state_test.dart \
  test/player_screen_test.dart \
  test/liked_songs_screen_state_test.dart
```

- Exit code: `0`
- Result: `19` tests passed, `0` failed.

Required analyzer command:

```text
cd client && flutter analyze
```

- Exit code: `1`
- Exact result: `9 issues found. (ran in 1.7s)`
- All nine are the known pre-existing info-level diagnostics listed earlier in
  this report. There were no warnings, errors, or diagnostics in changed files.

The first full-suite attempt was run before the explicit adversarial-review
boundary and is retained here honestly:

- Exit code: `1`
- Result: `961` passed, `1` failed.
- Failure:
  `client/test/library_track_actions_test.dart` still expected a missing
  `is_liked` annotation to default to false. The test was corrected to assert
  null, matching the fix-pass rule.

The subsequent adversarial diff review found two additional valid changed-hunk
issues: toggle completion removed the in-flight marker without notifying
listeners, and a still-live previous-account `sourceUrl` was not gated with its
liked annotation. Both were fixed in the same batch. The focused changed-hunk
re-review above then passed before the final full gate.

Required final full-suite command:

```text
cd client && flutter test
```

- Exit code: `0`
- Exact final line: `00:31 +963: All tests passed!`
- Total: `963` passed, `0` failed.

Delivery harness:

```text
scripts/agentic-harness
```

- Exit code: `0`
- Result: `AGENTIC HARNESS OK`

No backend, `client/lib/core/engine/`, or
`queue_timeline_controller.dart` file was changed. The supplied
`TASK-286.md` and `FIXPASS-286.md` packets remain untracked and unmodified.
The conventional fix-pass commit is intentionally left to the primary agent
after final integration review.

### Focused re-review follow-up

A focused review of the fix-pass hunks found three additional gaps. They were
patched without widening the task:

| Gap | Follow-up action |
| --- | --- |
| Account-switch response race | `LikedTracksState.clear()` now always advances an account/request epoch, even when state is empty, and rejects every response captured before that floor. The async account-id callback in `main.dart` also carries a generation and cannot apply after a later logout or auth transition. |
| Persistence relabel race | `mediaItemToPlaybackJson` preserves `likedAccountId`, and `QueuePersistenceStore.save` scopes each track before stamping the current snapshot account. Old-account liked/source metadata is stripped instead of being relabeled as the new user. |
| Downloaded-only harness gap | Both remote and local Library paths now pass through the same test-visible `seedLikedTracksFromLibraryLoad` decision. The local/downloaded source is asserted not to overwrite an already seeded true value. |

Focused follow-up command:

```text
cd client && flutter test \
  test/liked_tracks_state_test.dart \
  test/queue_persistence_test.dart \
  test/library_track_actions_test.dart \
  test/playback_source_resolver_test.dart
```

- Exit code: `0`
- Exact result: `39` tests passed, `0` failed.

Follow-up analyzer command:

```text
cd client && flutter analyze
```

- Exit code: `1`
- Exact result: `9 issues found. (ran in 1.1s)`
- All nine remain the known pre-existing info-level diagnostics; there are no
  diagnostics in changed files.

The earlier `963/963` full-suite result predates these focused-review changes
and remains historical evidence only. The primary agent then ran the required
final exact-head gates:

```text
cd client && flutter analyze
```

- Exit code: `1`
- Exact result: `9 issues found. (ran in 1.1s)`
- All nine are the same known pre-existing info-level diagnostics, with no
  diagnostic in a changed file.

```text
cd client && flutter test
```

- Exit code: `0`
- Exact final line: `00:34 +966: All tests passed!`
- Total: `966` passed, `0` failed.

The `966/966` result is the final exact-head full-suite evidence for this fix
pass.
