# TASK-285-1 Delivery Report

## Scope and result

Delivered the registry-foundation slice only on
`feat/285-command-registry`. The registry is above `PlaybackState`,
`MixAudioHandler` remains a thin client, command availability is derived from
existing playback state, and queue mutations dispatched by commands use stable
`queueItemId` identity.

No backend, multi-select, keyboard reorder, table mode, desktop IA/theme,
playlist rail, transition, or OS-global media-key work is included.

## Work items

1. **Registry core**
   - `client/lib/core/commands/app_command.dart`
   - `client/lib/core/commands/command_registry.dart`
   - Stable IDs, categories, icon/label/shortcut metadata, injected
     `CommandContext`, derived `ValueListenable<CommandAvailability>`, category
     enumeration, and optional surface delegates that preserve existing UI
     feedback while retaining canonical-authority fallbacks.
   - `client/lib/core/commands/` has no Riverpod import.
2. **Transport commands**
   - Play/pause toggle, discrete play and pause, next, previous, seek +/-10
     seconds, shuffle toggle, and repeat-cycle commands.
   - `client/lib/core/audio/queue_timeline_controller.dart` and
     `client/lib/core/audio/playback_state.dart` expose derived
     `canSkipNext`/`canSkipPrevious` from the canonical play order, including
     shuffle.
3. **Navigation commands**
   - Home, Search, Library, Playlists, Downloads, Queue, Now Playing, Settings,
     focus Search, Back, and shortcut help.
   - Wired through `client/lib/app/app.dart`,
     `client/lib/app/router.dart`,
     `client/lib/core/commands/search_focus_controller.dart`, and
     `client/features/search/search_screen.dart`.
4. **Item commands**
   - Play now, play next, add to queue, stable-ID remove from queue, add to
     playlist, and toggle liked.
   - Existing `PlaybackState`, `PlaylistService.addTracks`, and
     `LikedTracksState` remain the authorities.
5. **Native shortcut dispatch**
   - `client/lib/core/commands/command_shortcuts.dart` and
     `client/lib/core/commands/command_widgets.dart` use Flutter
     `Shortcuts`/`Actions` above the routed child.
   - Focused text fields retain Space, seek keys, `/`, and `?`.
6. **First context menus and overflow parity**
   - `client/lib/features/library/library_screen.dart`,
     `client/lib/screens/queue_screen.dart`, and
     `client/lib/shared/widgets/queue_swipe_action.dart`.
   - Library rows and playback-queue rows open an enumeration-driven menu on
     secondary click. The library overflow sheet enumerates the same command
     objects and preserves existing mobile gestures and surface feedback.
7. **Shortcut help**
   - Enumeration-driven dialog launched by `?` and the Settings keyboard
     shortcuts entry in `client/lib/features/settings/settings_screen.dart`.
8. **audio_service alignment**
   - `client/lib/core/audio/mix_audio_handler.dart` documents the registry as
     the canonical command vocabulary while retaining direct delegation to
     `PlaybackState`.
9. **Architecture documentation**
   - `docs/context-map.md`
   - `docs/adr/0005-command-registry.md`

## Shortcut map

`Primary` is Cmd on macOS/iOS and Ctrl elsewhere.

| Shortcut | Command |
| --- | --- |
| Space | Play / Pause |
| Alt+Right | Next |
| Alt+Left | Previous |
| Primary+Right | Seek forward 10 seconds |
| Primary+Left | Seek back 10 seconds |
| Primary+K or `/` | Focus Search |
| `?` | Keyboard shortcut help |
| Escape | Back |
| Primary+1 | Home |
| Primary+2 | Search |
| Primary+3 | Library |
| Primary+4 | Playlists |
| Primary+5 | Downloads |
| Primary+6 | Queue |
| Primary+7 | Now Playing |
| Primary+8 | Settings |

## Tests and exact verification

New and extended regression coverage:

- derived availability initialization and playback transitions;
- shuffle-aware next/previous capability;
- native `CommandIntent` dispatch, disabled no-op, and text-field precedence;
- queueItemId-only play-next/remove routing and no positional removal;
- `LikedTracksState` authority plus library feedback-delegate fallbacks;
- rendered library context-menu/overflow label and enabled-state parity,
  including live Like/Unlike updates while the sheet is open;
- playback-queue secondary-click registry menu;
- duplicate queue occurrence removal by stable identity;
- existing app audio-default flow after registry construction.

Initial slice-head verification commands and results:

| Command | Exact result |
| --- | --- |
| `cd client && flutter analyze` | Completed with the 9 documented pre-existing info diagnostics; no new diagnostics. Flutter exits 1 because infos are fatal under the current analyzer invocation. |
| `cd client && flutter test` | `+1010: All tests passed!` (1,004 baseline plus 6 new tests). |
| Focused re-review tests | App audio-default flow `+1`; registry/library/queue-screen/queue-timeline `+93`; all passed. |
| `scripts/agentic-harness` | `AGENTIC HARNESS OK` |
| `git diff --check origin/main...HEAD` | Clean at the initial slice code head; repeated after the report commit. |

## Adversarial review

The initial self-review found and fixed:

- Back was enabled at the root and could no-op;
- shortcut help could use a context above the Navigator;
- `/` and `?` could steal input from focused text fields;
- popup coordinates were not converted against the overlay;
- unresolved transient queue identity could expose a no-op removal;
- added gesture wrappers initially violated Reorderable/Dismissible key
  contracts.

The independent adversarial review found no P0 and two P1 issues:

- the first disabled-to-enabled availability notification could be suppressed
  because `_lastEmitted` was not initialized from the first derivation;
- library registry actions bypassed existing add-to-queue feedback and
  like-in-flight handling.

One batched fix pass initialized the derived signal before subscription and
added optional surface delegates with canonical fallbacks. The same pass added
open-sheet liked-state reactivity, actual rendered parity assertions,
queue-row secondary-click coverage, and shuffle-order skip capability.
A focused independent re-review found no remaining P0/P1 issue and no
regression in the fix hunks.

## Deviations and residual risks

- Volume commands were skipped because `PlaybackState` has no volume/mute seam;
  adding one would exceed this foundation slice.
- The existing `track_action_sheet.dart` is a MusicBrainz/add-to-library flow,
  not the library-track action overflow, so it was not converted.
- Playback-queue rows expose only commands applicable with their existing
  dependencies. Liked-state and playlist-picker actions are omitted there
  rather than inventing a second picker or state path; library rows provide
  those commands through the existing authorities.
- No physical desktop or Android dogfood was run. Shortcut focus, secondary
  click, overflow gestures, stable queue identity, and mobile-preserving
  wrappers are covered by widget/controller tests; platform-native Cmd key
  behavior remains a device-level residual risk.
- OS-global media keys remain explicitly out of scope.

## Fix pass (cross-model review)

The fix-then-approve findings were handled as one bounded batch under the
accepted policies that Space is a global transport key outside text input and
that queue-row affordance rules live in the registry.

| Finding | Action |
| --- | --- |
| 1. Queue-row Play now replaced the queue | Added a `CommandContext.playNow` surface delegate. Playback queue rows delegate to `_skipToPlaybackIndex`; the registry keeps `playTrack` only as the non-queue fallback. A widget regression asserts one skip, zero `playTrack` calls, and unchanged queue length. |
| 2. Space handling diverged by availability/focus | The registry action consumes Space while Play / Pause is unavailable, yields all shortcuts to focused text input, and retains loaded-track transport dispatch. Tests cover list-tile focus, an unloaded focused button, and typing Space in a `TextField`. The ADR and help overlay state the convention. |
| 3. iOS hardware keyboards used Ctrl | One `_isApple` helper now drives shortcut activators and the exported primary-modifier label used by registry hints. Tests cover Apple and non-Apple bindings/hints. |
| 4. Current-row remove diverged between menu and swipe | `removeFromQueue` availability returns `disabled('Currently playing')` for the current `queueItemId`. The swipe affordance reads that same registry availability; a widget parity test covers both surfaces. |
| 5. Escape discarded focused input routes | The command action unfocuses a focused text field and does not dispatch Back until no text field has focus. |
| 6. Repeated `?` stacked help dialogs | App-level help dispatch now has an in-flight dialog guard reset in `finally`. |
| 7. `/` and `?` assumed a US logical key | Both shortcuts use `CharacterActivator`; help copy notes that physical key position follows the active layout. |
| 8. Queue command category was unused | Removed the unused `CommandCategory.queue`; item commands remain enumerated from the single item category used by both menu surfaces. |
| 9. Previous was enabled by loop-all at the first entry | `QueueTimelineController` now exposes the loop-independent derived capability `hasPreviousInPlayOrder`, `PlaybackState` forwards it, and registry availability uses it below the restart threshold. This stays correct when natural queue index 0 has a predecessor in shuffled play order; controller behavior is unchanged. |
| 10. Popup availability was a stale snapshot | Added the requested guard comment: popup state is a display snapshot, while `AppCommand.execute()` re-checks current availability before dispatch. |

Final exact-head verification results:

| Command | Exact result |
| --- | --- |
| `cd client && flutter analyze` | 9 known info diagnostics only; no new diagnostics. |
| `cd client && flutter test test/command_registry_test.dart test/queue_timeline_controller_test.dart` | `+39: All tests passed!` |
| `cd client && flutter test test/queue_screen_test.dart` | `+57: All tests passed!` |
| `cd client && flutter test test/app_audio_defaults_flow_test.dart` | `+1: All tests passed!` |
| `cd client && flutter test` | `+1014: All tests passed!` (0 failures). |
| `git diff --check origin/main...HEAD` | Exit 0 at final fix head. |

## Commits

- `aeff30a feat(client): add command registry foundation`
- `docs: add TASK-285 command registry report` (the commit containing this
  report)
- `fix(client): close command registry findings` (this commit)
