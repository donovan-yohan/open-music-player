# Cross-platform music-player benchmark and OMP staple audit

- **Research snapshot:** 2026-07-23
- **OMP baseline:** `12ce95f` (`main`)
- **Target platforms:** Windows, macOS, and Android; iOS is out of scope
- **Primary product question:** Does Open Music Player (OMP / Sound Q) have the
  primitives and interaction quality expected of a daily-driver music player,
  particularly on desktop?

## Executive verdict

OMP has a stronger playback and queue foundation than its current product
surface suggests. The active playback queue, persisted session state, playlist
flows, library search/sort/filter, explicit downloads, bounded cache, persistent
mini-player, Android media service, and responsive Sound Q shell are real.
Several older gap documents understate this work because the corresponding
issues have since closed.

The main gap is not another queue engine or more DJ metadata. It is shipping and
operating as a desktop application:

1. **OMP does not currently have native Windows or macOS applications in the
   repository.** The Flutter client has only `android/` and `web/` platform
   runners. CI runs on Ubuntu and tests the client; pull-request runs additionally
   build and upload an Android debug APK. No CI job builds desktop clients.
   [#179]'s responsive desktop web shell is not equivalent to Windows/macOS
   product support. The baseline README's broader cross-platform client claim was
   therefore ahead of the repository's current shippable platform set and is
   corrected with this audit.
2. **The desktop shell is visually adaptive but interaction-light.** It has
   focusable rail navigation and basic Enter/Space activation, but no evidence
   of track-level right-click menus, a music-player shortcut map, desktop
   drag/drop, system tray behavior, global media shortcuts, output-device
   selection, or dense sortable library tables.
3. **Some visible controls are decorative or misleading.** The now-playing
   device, favorite, and share buttons have empty handlers. Settings advertises
   selectable streaming/download quality, gapless playback, and crossfade, but
   the preferences are only found in the settings model/provider; no playback
   wiring was found. The streaming row simultaneously says “Always 320k.” The
   Downloads route exists, while Settings still says the screen is not
   implemented. The library metadata-fix action is a TODO.
4. **Android integration exists but is not fully proven.** The manifest and
   `audio_service` wiring cover foreground playback, media notification, and
   media buttons. [#149] remains open specifically for notification polish and
   cross-device verification. It should be treated as unfinished until
   lock-screen, Bluetooth/headset, interruption, and Android Auto behavior are
   exercised on a release candidate.
5. **The open roadmap is skewed toward DJ/mix work.** Of the 13 open issues in
   this snapshot, most are DJ engine/timeline concerns. There is no explicit
   desktop-readiness epic. Daily-driver desktop work should be inserted ahead of
   further optional DJ surface expansion.

## Method and confidence rules

There is no shared “rating” system across open-source music players. This audit
uses GitHub stars as a rough popularity signal, then checks project activity,
license, official documentation, release artifacts, and official screenshots.
Stars are not treated as a quality score.

A player counts as having the requested platform coverage only when first-party
sources or release assets demonstrate Windows, macOS, and Android delivery.
Merely containing platform folders or supporting a browser does not satisfy the
strict platform criterion.

Evidence labels used below:

- **Implemented:** current OMP source, tests, and/or a completed issue show the
  primitive is present.
- **Partial:** meaningful implementation exists, but platform coverage,
  interaction quality, runtime wiring, or verification is incomplete.
- **Missing:** no implementation or issue evidence was found after targeted
  source, dependency, workflow, and issue-ledger searches.
- **Deferred:** a current open issue owns the work.
- **Product decision:** a competitor primitive that is not automatically right
  for OMP.

Absence claims are scoped to the 2026-07-23 repository snapshot. They are not
claims about unmerged branches or private deployments.

## Benchmark set

### Strict cross-platform references

| Player | Popularity snapshot | License | Windows + macOS + Android evidence | Why it matters to OMP |
| --- | ---: | --- | --- | --- |
| [Spotube] | 47,824 stars | BSD-4-Clause | The [v5.1.2 release][spotube-release] publishes Windows, macOS, and Android packages. | Largest directly relevant modern Flutter reference. Persistent navigation/player, responsive library presentation, lyrics, downloads, local music, and platform-specific media behavior are useful comparators. Its Spotify-shaped catalog model is not OMP’s product model. |
| [Kodi] | 20,996 stars | GPL-2.0-or-later | The project supports Windows, macOS, and Android. | Mature baseline for library nodes, filter/sort, temporary queue semantics, context menus, remote/keyboard navigation, and broad device playback. It is a TV/media-center product, so its spatial scale and interaction model should not be copied wholesale. |
| [VLC] | 19,094 stars | GPL-2.0 | VideoLAN distributes VLC for Windows, macOS, and Android. | Mature baseline for local/network media, playlists, configurable hotkeys, audio output/device selection, equalizer/filters, and Android background playback. It is a general media player rather than a library-first music product. |
| [musikcube] | 4,804 stars | BSD-3-Clause | Desktop runs on Windows and macOS; the official `musikdroid` Android client streams from and remotely controls a musikcube server. | Excellent specialist reference for dense library/queue workflows, explicit keyboard commands, context actions, queue save/load/reorder, global Windows hotkeys, and headless/server operation. Android is a companion client, not an equivalent standalone local-library app. |
| [OpenSpot] | 2,440 stars | MIT | The [v3.1.5 release][openspot-release] publishes Android, Windows, and macOS artifacts. | Modern Flutter reference for responsive navigation, offline/download flows, playlist import, background downloads, and a compact product surface. Its online-catalog behavior and recent project age make it a secondary rather than authoritative baseline. |
| [Rune] | 990 stars | MPL-2.0 source | The [v1.1.0 release][rune-release] includes Android APKs, a macOS DMG, and Windows MSIX/ZIP packages. | Direct local-library reference with Flutter UI, audio analysis, recommendations, lyrics, scrobbling, tag editing, desktop drag/drop, `Ctrl+O`, and tray behavior. Latest stable binaries are older than current repository activity. The README separately asks users to purchase a license for official use/support, so source-code licensing and binary/support terms should not be conflated. |
| [Crossonic] | 10 stars | MPL-2.0 | The [v0.5.1 release][crossonic-release] and install docs cover Android, Windows, and macOS. | Low-adoption but unusually direct self-hosted comparator. Its [v0.5.1 feature matrix][crossonic-features] documents OpenSubsonic servers, offline playback, ReplayGain, gapless playback, lyrics, editable normal/priority queues, Sonos and native AirPlay casting, Android Auto playlists, desktop tray behavior, and a responsive player. Chromecast remains unchecked. Use it as a feature-shape reference, not popularity evidence. |

### Useful references that fail the strict “open-source exact-platform” filter

| Project | Disposition |
| --- | --- |
| [Harmonoid] | Strong product and Flutter reference with Windows, macOS, and Android releases, but its PolyForm Strict 1.0.0 license is source-available rather than OSI open source. Its local-library UX, ReplayGain, gapless/crossfade, lyrics, native media controls, and output quality features are still useful observation targets. Do not copy code or describe it as FOSS. |
| [MusicPod] | Active GPL-3.0 Flutter project and useful desktop/mobile-layout reference, but it was not retained as a primary exact-platform benchmark because the reviewed release evidence did not establish the same production-grade Android + Windows + macOS artifact story as the strict set. |
| [Musly] | Visually relevant multi-platform Navidrome/Subsonic client, but its CC BY-NC-SA 4.0 licensing is a poor fit for software reuse and the release evidence was weaker than the strict set. Treat screenshots as product research only. |

## What the strongest players consistently expose

Official screenshots and documentation show several recurring patterns despite
very different products:

1. **Navigation and playback remain visible together.** Modern desktop players
   use a side rail or top category strip while reserving a persistent horizontal
   player. Mobile players use three to five primary bottom destinations with a
   mini-player immediately above them.
2. **Desktop gains density rather than merely width.** Harmonoid, Crossonic,
   musikcube, Kodi, and VLC expose more rows, metadata, sort/filter controls, and
   simultaneous context on larger screens. A desktop breakpoint that only adds
   columns of cards leaves productivity on the table.
3. **The queue is durable inspectable product state.** It is reachable without
   losing the current library context, supports explicit play-next/add/remove,
   and usually supports reorder, save, or bulk operations.
4. **Every track has a predictable action surface.** Desktop uses right-click or
   an overflow menu; mobile uses overflow and/or long press. The underlying
   commands should be the same: play, play next, add to queue, add to playlist,
   like, download, inspect metadata, and remove where applicable.
5. **Keyboard and media controls are first-class on desktop.** Mature players
   expose play/pause, previous/next, seek, volume, shuffle/repeat, focus/search,
   queue, and navigation commands. Reorder and destructive operations need
   keyboard-accessible alternatives to drag gestures.
6. **A daily-driver audio layer sits below specialist features.** Across several
   reviewed references, gapless, crossfade, ReplayGain/loudness normalization,
   output selection, sleep timer, lyrics, and truthful quality indicators are
   recurring daily-driver expectations. This audit did not perform a
   frequency-weighted feature count.
7. **OS integration is part of playback correctness.** Background playback,
   lock-screen metadata/actions, media keys, headset/Bluetooth events, audio
   focus, tray/window behavior, and resume after interruptions are not polish;
   they determine whether the app behaves like a player.
8. **Mobile keeps controls touch-safe and limits simultaneous context.** Large
   primary transport controls, clear scrub position/duration, persistent current
   track, bottom navigation, and explicit queue access are more important than
   exposing every desktop command at once.

### Screenshot observations

The reviewed first-party screenshots support the patterns above without proving
hidden behavior:

- Spotube desktop shows a persistent left library rail and full-width bottom
  player; its mobile material shows the same product reduced to bottom
  navigation and a compact player.
- Harmonoid desktop visibly uses top-level Albums/Tracks/Artists/Folders/Genres/
  Playlists categories, search/sort controls, a dense album grid, and a detailed
  fixed bottom player. Mobile preserves search, sort, a two-column album grid,
  mini-player, and bottom categories.
- Crossonic desktop combines a left rail, horizontally dense recent releases,
  a track list with per-row overflow, and a persistent bottom player. Mobile
  splits Home, Browse, and Playlists into compact bottom destinations while
  keeping playback visible.
- musikcube demonstrates the opposite extreme: a dense two-pane text library,
  explicit selected-row state, persistent queue/player status, and discoverable
  key commands. Its Android companion uses dedicated artist/album/song/queue
  tabs and always-visible transport.

These are information-architecture observations only. Runtime claims come from
first-party documentation or release notes, not screenshots.

## OMP issue-ledger reconciliation

The ledger contained **100 issues: 87 closed and 13 open**. Eighty-six closed
issues were marked completed; [#85] was closed as not planned. Closed is useful
implementation evidence, but it is not automatically release or cross-device
proof.

### Closed foundations that are materially present

- Discovery-to-playback and signed object delivery: [#36], [#39], [#43], [#44].
- Queue navigation, list management, durable timing, and timeline: [#55], [#56],
  [#57], [#58], [#59], [#60].
- Grounded search, URL import, explicit offline downloads, and bounded cache:
  [#71], [#73], [#80], [#81].
- Mobile auth persistence and biometrics: [#110].
- Unified playback engine and Android notification foundation: [#144], [#145],
  [#146], [#147], [#148], [#155].
- Persistent shell navigation and active-row feedback: [#157], [#174].
- Sound Q responsive visual shell and shared player components: [#176], [#179],
  [#180], [#181].
- Queue persistence regression coverage: [#249].
- Separation of import/download jobs from the playback queue: [#266].

### Current issues that still qualify related claims

- [#107] keeps playlist source sync open.
- [#149] keeps polished media notification and cross-device verification open.
- [#159], [#189], [#196], [#198], [#199], [#200], [#202], and [#261] keep the
  mix-engine/timeline/DSP roadmap explicitly unfinished.
- [#186] owns shared playback state and handoff between OMP app clients. It
  explicitly excludes DLNA, Chromecast, and AirPlay casting, and should not be
  treated as proof of local output selection, casting, or released handoff.

### Historical documents that should not be read as current truth

`docs/UX_GAP_ANALYSIS.md` and `docs/ROADMAP_SPOTIFY_PARITY.md` accurately record
an earlier period when playlist-context playback and queue/session ownership
were incomplete. Current engine/controller code and the closed issue sequence
show substantial later implementation. They remain useful baselines, but claims
such as “Add to queue is inaudible” should not be repeated without a fresh
reproduction.

## Staple-primitives matrix

| Primitive | Expected daily-driver behavior | OMP evidence | Status | Priority |
| --- | --- | --- | --- | --- |
| Native Windows and macOS apps | Installable clients with native runners, window lifecycle, release artifacts, and supported upgrade path | `client/` contains Android and web runners only. CI tests on Ubuntu; pull-request runs additionally build an Android debug APK. No Windows/macOS client jobs or artifacts were found. The baseline README claimed a broader target set; this audit corrects it. | **Missing** | **P0** |
| Responsive persistent shell | Navigation and current playback survive content navigation; wider screens expose more context | `client/lib/app/router.dart`; `client/test/desktop_shell_test.dart`; [#157], [#179]. Breakpoints provide mobile navigation below 960px, compact/extended rails, and 3–4 desktop grid columns. | **Implemented for Flutter web UI** | Maintain |
| Core transport | Play/pause, seek, previous/next, shuffle, repeat, position/duration | `PlaybackState`, `QueueTimelineController`, player controls, and tests expose the expected transport set. | **Implemented** | Maintain |
| Queue and session persistence | Play-next/add/remove/reorder, current item, restore after restart, clear feedback | [#55]–[#60], [#147], [#249]; queue/controller/engine tests. [#196] remains open for the canonical durable mix model across queue/playlist/timeline. | **Implemented, architecture still partial** | P1 under [#196] |
| Playlist management | Create/edit/delete, play/shuffle, search/sort, reorder, bulk remove, import | Playlist screens and service tests; playlist detail has edit, reorder, selection, and batch removal. [#107] owns optional source sync. | **Implemented, source sync deferred** | P1 |
| Library browse/search/filter/sort | Fast local/library search, multiple browse dimensions, clear active track, liked collection | `LibraryScreen` has pagination, in-library query, sort, filters, downloaded-only/verification views, liked songs, artist/album navigation, and per-track actions. | **Implemented** | Maintain |
| Persistent queue/player access | Mini-player plus explicit queue route from every main destination | Router shell, `MiniPlayer`, queue destination, [#56], [#157]. | **Implemented** | Maintain |
| Offline downloads and cache | User-owned downloads distinct from evictable cache; offline playback prefers valid local artifacts | [#80], [#81], `DownloadState`, `PlaybackCacheManager`, local artifact resolver, Downloads screen. File-backed behavior is non-web and has Android-oriented evidence. | **Partial across target platforms** | P0 with desktop delivery |
| Background/system playback | Correct lock-screen metadata/actions, headset/media buttons, audio focus, interruptions, resume | Android manifest and `audio_service` provide the foundation; [#149] remains open for polish and device verification. No native Windows/macOS system-media integration was found; browser-media behavior was not runtime-verified. | **Partial Android; native desktop missing** | **P0** |
| Desktop keyboard commands | Search/focus, transport, seek, volume, shuffle/repeat, queue, navigation, selection, reorder | Router maps Tab to the navigation rail and Enter/Space to rail activation. No application-wide music command map was found. | **Partial** | **P0** |
| Desktop context menus | Right-click exposes the same track/album/playlist commands as mobile overflow/long press | OMP uses bottom sheets, overflow buttons, and long press. No `onSecondaryTap`, `showMenu`, or desktop context-menu implementation was found. | **Missing** | **P0** |
| Selection and drag/drop | Shift/Ctrl/Cmd multi-select, keyboard selection, bulk queue/playlist/download operations, external file/folder drop where product-fit | Playlist detail has selection/batch remove; queue and playlist reorder gestures exist. No broad desktop selection model or external desktop drag/drop was found. | **Partial** | P1 |
| Dense desktop library/queue | Optional compact rows/table, useful columns, column sort, scalable density, queue/inspector pane | Sound Q desktop emphasizes poster-grid composition; track rows exist, but no sortable-column table, density preference, or split queue/inspector pane was found. | **Partial** | P1 |
| Player action integrity | Every visible icon either works, explains why unavailable, or is absent | Device, favorite, and share icons in `player_screen.dart` have empty handlers. Library liking and inbound shared-URL import exist elsewhere, but no outbound player-share behavior is wired here. | **Broken affordances** | **P0** |
| Downloads destination integrity | Every Downloads link opens the implemented Downloads screen | `/downloads` and `DownloadsScreen` exist. Settings still displays “Downloads screen not yet implemented.” | **Broken navigation/copy** | **P0** |
| Metadata correction | User can inspect and correct wrong metadata or resolve a MusicBrainz match | Metadata info and enrichment evidence exist, but the library “Fix metadata” action contains a navigation TODO. | **Partial** | P1 |
| Streaming/download quality | Selected setting changes the requested/served artifact and UI reports actual quality | Settings persist quality values, but no playback/download consumption was found. Streaming also displays “Always 320k.” | **Misleading / unverified** | **P0** |
| Gapless and simple crossfade | Preference changes ordinary sequential playback, with an audible automated acceptance test | Settings persist both values. DJ gain envelopes and overlaps exist, but no wiring from these preferences to normal playback was found. | **Unverified / likely UI-only** | **P0** |
| Output device and volume | Select local output where supported; visible volume/mute on desktop; do not conflate with remote handoff | Now-playing device icon is a no-op. No desktop output dependency or picker was found. [#186] is a different account-level handoff problem. | **Missing** | P1 |
| Sleep timer | Stop after duration/end of track, visible remaining time, cancel/extend | No implementation or issue was found. | **Missing** | P1 |
| ReplayGain/loudness normalization | Off/track/album modes or an explicit product decision; clipping-safe gain application | [#197] and analysis models carry loudness/true-peak data, but no user-facing normalization or playback gain policy was found. | **Analysis exists; playback feature missing** | P1 |
| Equalizer | Either ship a real audio EQ or avoid using EQ terminology for waveform color/analysis | Frequency-semantic waveform rendering exists; no user-facing playback equalizer was found. | **Missing** | P2 |
| Lyrics | Search/display cached lyrics with clear source and failure state, or explicitly defer | No dedicated lyrics route, model, provider, or issue was found. | **Missing** | P2 |
| Account-level OMP device handoff | All signed-in clients observe one session; inactive clients control the active OMP output until explicit transfer | [#186] owns this exact Connect-style OMP-client model; no shipped implementation was found. | **Deferred** | P2 under [#186] |
| Cast / remote playback targets | Discover DLNA/Chromecast/AirPlay/Sonos targets, show connection state, and recover from target loss | No implementation or owning issue was found. [#186] explicitly excludes these protocols. | **Missing / product decision** | P2 |
| Accessibility | Labels, focus order, keyboard equivalent actions, scalable text, non-color state | Queue/player widgets contain semantics, tooltips, focus nodes, and tested desktop rail focus. Drag/reorder and icon-only actions still need desktop keyboard equivalents and end-to-end screen-reader verification. | **Partial, promising** | P1 |

## Recommended roadmap

### P0 — make support claims true

#### 1. Native Windows and macOS client delivery epic

**Suggested title:** `[Epic] Ship supported Windows and macOS Sound Q clients`

Acceptance should include:

- Add and maintain Flutter `windows/` and `macos/` runners.
- Prove authentication, signed-URL playback, queue restore, library/search,
  playlist playback, and settings on each OS.
- Decide whether explicit downloads/cache are supported on desktop; do not
  silently expose controls that cannot work.
- Add Windows and macOS CI jobs that analyze/test and build installable or
  clearly labeled unsigned artifacts.
- Add package identity, version/build/source metadata, icons, window minimum
  size, deep-link policy, and single-instance behavior.
- Define signing/notarization and release-channel follow-ups separately from the
  first reproducible unsigned build.
- Update README platform claims only after artifact links are continuously
  available.

#### 2. Desktop interaction parity epic

**Suggested title:** `[Epic] Add desktop keyboard, context-menu, selection, and density workflows`

Acceptance should include:

- Central command layer shared by menu, shortcut, context menu, and buttons.
- Default shortcuts for play/pause, previous/next, seek, search, queue, volume,
  shuffle/repeat, and navigation; show them in a discoverable shortcut sheet.
- Right-click menus for tracks, albums, playlists, and queue rows with parity to
  mobile actions.
- Shift-range and Ctrl/Cmd-toggle selection with batch queue/playlist/download/
  remove actions where valid.
- Keyboard-accessible queue/playlist reorder and destructive-action
  confirmation.
- Optional compact list/table presentation with meaningful metadata and sort;
  preserve the poster-grid home rather than turning every screen into a table.
- Focus, tooltip, semantics, and 200% text-scale tests at desktop breakpoints.

#### 3. Product-surface integrity issue

**Suggested title:** `Wire or remove placeholder player actions and truthful playback settings`

Acceptance should include:

- Device, favorite, and share actions work or are removed until they can work.
- Settings Downloads opens `/downloads`.
- “Fix metadata” opens a real correction flow or is clearly unavailable.
- Streaming/download quality settings alter a request/artifact or are replaced
  by truthful read-only source-quality information.
- Gapless/crossfade preferences are wired to ordinary playback and tested, or
  the controls are removed pending implementation.
- Add a regression test that fails on enabled empty callbacks for primary
  player/settings actions.

#### 4. Finish system playback as a release gate

Extend, do not duplicate, [#149]:

- Verify notification metadata and actions during single-track and overlapping
  playback.
- Verify lock screen, wired headset, Bluetooth, audio focus/interruption,
  process backgrounding, and force-stop/relaunch behavior on a release build.
- Record Android Auto as explicitly supported, limited, or unsupported based on
  a real test; a manifest receiver alone is not proof.
- Add Windows media keys/SMTC and macOS Now Playing/remote-command validation to
  the desktop epic once native clients exist.

### P1 — daily-driver quality

1. Add a compact desktop library/table mode and optional inspectable queue pane.
2. Add local output-device and desktop volume/mute behavior; keep this separate
   from account-level handoff in [#186].
3. Add a sleep timer.
4. Define and implement ReplayGain/loudness normalization using the existing
   loudness/true-peak analysis, with clipping protection and an explicit
   fallback when analysis is absent.
5. Finish metadata correction and MusicBrainz rematching.
6. Extend selection/bulk actions beyond playlist batch removal.
7. Run accessibility verification with keyboard-only navigation and a screen
   reader on one desktop OS plus Android TalkBack.

### P2 — useful differentiation after fundamentals

- Lyrics with source/provenance and caching.
- Real playback EQ; keep it conceptually separate from frequency-colored
  waveform analysis.
- Account-level OMP-client device handoff through [#186]. Create a separate
  cast/remote-target issue only if those protocols fit the product; [#186]
  explicitly excludes them.
- Scrobbling and richer library statistics if they fit the personal-library
  product.
- Desktop external file/folder import only after deciding whether OMP owns local
  file scanning or remains source-import/server-library first.

## Product boundaries: what not to copy blindly

- Do not turn OMP into a Spotify client because Spotube/OpenSpot are popular.
  OMP’s self-hosted library, owned downloads, source provenance, and mix model
  are differentiators.
- Do not copy Kodi’s TV-scale navigation into desktop productivity screens.
- Do not treat VLC’s exhaustive option surface as the default information
  architecture.
- Do not add desktop-only state controllers. Commands should mutate the existing
  `PlaybackState` / `QueueTimelineController` source of truth.
- Do not allow DJ roadmap work to certify ordinary playback settings by
  implication. A mix gain envelope is not proof that the Settings crossfade
  slider affects sequential playback.
- Do not claim Windows/macOS support from a responsive web layout or dormant
  Flutter source. Require repeatable native artifacts.

## Verification targets for the recommended work

A desktop-readiness gate should minimally exercise each target OS at the exact
candidate head:

1. Launch, login, restore session, and render shell at compact and wide widths.
2. Search library; sort/filter; play from track, album, playlist, and liked
   collection contexts.
3. Play/pause/seek/previous/next/shuffle/repeat by mouse, keyboard, and media
   key.
4. Add next/add queue/remove/reorder and restore queue after process restart.
5. Open track context menu; add to playlist; like/unlike; download where
   supported; share; inspect/correct metadata.
6. Background/minimize/close-window behavior and OS now-playing integration.
7. Audio output, volume/mute, interruption recovery, and device disappearance.
8. Keyboard-only focus path, screen reader labels, 200% text scale, and
   high-contrast state distinction.
9. Artifact provenance: platform, version, source commit, build ID, checksum,
   signing state, and installation instructions.

## Source index

All external sources were accessed on 2026-07-23.

### Competitors and platform evidence

- [Spotube repository][Spotube] and [v5.1.2 release][spotube-release]
- [VLC repository][VLC], [official download page][vlc-download], and
  [user-guide index][vlc-guide]
- [Kodi repository][Kodi] and [official music navigation guide][kodi-music]
- [musikcube repository][musikcube], [v3.0.5 release][musikcube-release], and
  [keyboard-oriented user guide][musikcube-guide]
- [OpenSpot repository][OpenSpot] and [v3.1.5 release][openspot-release]
- [Rune repository][Rune] and [v1.1.0 release][rune-release]
- [Crossonic repository][Crossonic] and [v0.5.1 release][crossonic-release]
- [Harmonoid repository][Harmonoid] and [license][harmonoid-license]
- [MusicPod repository][MusicPod]
- [Musly repository][Musly]

### OMP source evidence

- Platform claim corrected by this audit: `README.md`
- Platform runners: `client/android/`, `client/web/`
- CI: `.github/workflows/ci.yml`
- Client dependencies: `client/pubspec.yaml`
- Shell/navigation: `client/lib/app/router.dart`
- Desktop breakpoints/focus: `client/test/desktop_shell_test.dart`
- Playback state: `client/lib/core/audio/playback_state.dart`
- Timeline/queue controller: `client/lib/core/audio/queue_timeline_controller.dart`
- Engine: `client/lib/core/engine/`
- Android media integration:
  `client/android/app/src/main/AndroidManifest.xml`
- Library: `client/lib/features/library/library_screen.dart`
- Playlist detail: `client/lib/features/playlists/playlist_detail_screen.dart`
- Queue: `client/lib/screens/queue_screen.dart`
- Now playing: `client/lib/features/player/player_screen.dart`
- Settings: `client/lib/features/settings/settings_screen.dart`
- Downloads: `client/lib/features/downloads/downloads_screen.dart`

[Spotube]: https://github.com/KRTirtho/spotube
[spotube-release]: https://github.com/KRTirtho/spotube/releases/tag/v5.1.2
[VLC]: https://github.com/videolan/vlc
[vlc-download]: https://www.videolan.org/vlc/
[vlc-guide]: https://wiki.videolan.org/Documentation:User_Guide/
[Kodi]: https://github.com/xbmc/xbmc
[kodi-music]: https://kodi.wiki/view/Music_navigation
[musikcube]: https://github.com/clangen/musikcube
[musikcube-release]: https://github.com/clangen/musikcube/releases/tag/3.0.5
[musikcube-guide]: https://github.com/clangen/musikcube/wiki/user-guide
[OpenSpot]: https://github.com/BlackHatDevX/openspot-music-app
[openspot-release]: https://github.com/BlackHatDevX/openspot-music-app/releases/tag/v3.1.5
[Rune]: https://github.com/Losses/rune
[rune-release]: https://github.com/Losses/rune/releases/tag/v1.1.0
[Crossonic]: https://github.com/juho05/crossonic
[crossonic-release]: https://github.com/juho05/crossonic/releases/tag/v0.5.1
[crossonic-features]: https://github.com/juho05/crossonic/tree/v0.5.1#features
[Harmonoid]: https://github.com/harmonoid/harmonoid
[harmonoid-license]: https://github.com/harmonoid/harmonoid/blob/master/LICENSE
[MusicPod]: https://github.com/ubuntu-flutter-community/musicpod
[Musly]: https://github.com/dddevid/Musly

[#36]: https://github.com/donovan-yohan/open-music-player/issues/36
[#39]: https://github.com/donovan-yohan/open-music-player/issues/39
[#43]: https://github.com/donovan-yohan/open-music-player/issues/43
[#44]: https://github.com/donovan-yohan/open-music-player/issues/44
[#55]: https://github.com/donovan-yohan/open-music-player/issues/55
[#56]: https://github.com/donovan-yohan/open-music-player/issues/56
[#57]: https://github.com/donovan-yohan/open-music-player/issues/57
[#58]: https://github.com/donovan-yohan/open-music-player/issues/58
[#59]: https://github.com/donovan-yohan/open-music-player/issues/59
[#60]: https://github.com/donovan-yohan/open-music-player/issues/60
[#71]: https://github.com/donovan-yohan/open-music-player/issues/71
[#73]: https://github.com/donovan-yohan/open-music-player/issues/73
[#80]: https://github.com/donovan-yohan/open-music-player/issues/80
[#81]: https://github.com/donovan-yohan/open-music-player/issues/81
[#85]: https://github.com/donovan-yohan/open-music-player/issues/85
[#107]: https://github.com/donovan-yohan/open-music-player/issues/107
[#110]: https://github.com/donovan-yohan/open-music-player/issues/110
[#144]: https://github.com/donovan-yohan/open-music-player/issues/144
[#145]: https://github.com/donovan-yohan/open-music-player/issues/145
[#146]: https://github.com/donovan-yohan/open-music-player/issues/146
[#147]: https://github.com/donovan-yohan/open-music-player/issues/147
[#148]: https://github.com/donovan-yohan/open-music-player/issues/148
[#149]: https://github.com/donovan-yohan/open-music-player/issues/149
[#155]: https://github.com/donovan-yohan/open-music-player/issues/155
[#157]: https://github.com/donovan-yohan/open-music-player/issues/157
[#159]: https://github.com/donovan-yohan/open-music-player/issues/159
[#174]: https://github.com/donovan-yohan/open-music-player/issues/174
[#176]: https://github.com/donovan-yohan/open-music-player/issues/176
[#179]: https://github.com/donovan-yohan/open-music-player/issues/179
[#180]: https://github.com/donovan-yohan/open-music-player/issues/180
[#181]: https://github.com/donovan-yohan/open-music-player/issues/181
[#186]: https://github.com/donovan-yohan/open-music-player/issues/186
[#189]: https://github.com/donovan-yohan/open-music-player/issues/189
[#196]: https://github.com/donovan-yohan/open-music-player/issues/196
[#197]: https://github.com/donovan-yohan/open-music-player/issues/197
[#198]: https://github.com/donovan-yohan/open-music-player/issues/198
[#199]: https://github.com/donovan-yohan/open-music-player/issues/199
[#200]: https://github.com/donovan-yohan/open-music-player/issues/200
[#202]: https://github.com/donovan-yohan/open-music-player/issues/202
[#249]: https://github.com/donovan-yohan/open-music-player/issues/249
[#261]: https://github.com/donovan-yohan/open-music-player/issues/261
[#266]: https://github.com/donovan-yohan/open-music-player/issues/266
