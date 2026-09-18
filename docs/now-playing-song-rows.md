# Now-playing song rows

Song-row playback identity is projected by `songRowPresentationFor(snapshot, trackId:, queueItemId:)`.
`NowPlayingRow` selects only this enum from `PlaybackState.snapshot`; `SongRowTreatment` owns
Library-orange fill/title/border and selected semantics. `TrackTile.fromTrack` supplies the library
ID automatically. Direct `TrackTile` constructors must supply a canonical `trackId`; listening
queue entries additionally supply their cue's stable `queueItemId`. No title/context matching.
No playback authority is added (ADR 0001/0012). Status icons are deliberately static and out of flow. Selected
tracks stay highlighted while paused/loading; only a coherent ready cue with active voices
can say “Now playing”. All other selected states use “Current track”, not a playing claim.

## Renderer inventory

| Surface | Renderer / integration | Identity / exception |
| --- | --- | --- |
| Home mobile recent/top | `_TrackTile` → `NowPlayingRow` + `SongListItem` | Library track ID; unavailable rows retain existing disabled actions |
| Home desktop rotation | `_DesktopPoster` → `NowPlayingRow` | Track ID; playlist posters have null identity |
| Library, including local search/filter results | `LibraryTrackListTile` → `NowPlayingRow` + `SongListItem` | Exact library ID; downloaded/local payloads retain that ID |
| Liked Songs | `TrackTile.fromTrack` | Shared adapter; custom heart/actions preserved |
| Playlist normal/edit/select | `TrackTile.fromTrack` | Cross-context track identity; no playlist-context gate |
| Playlist mixed view | `TrackTile(trackId:)` | Track identity; seam/badge editor unaffected |
| Playlist add-tracks picker | `TrackTile.fromTrack` | Selection checkboxes preserved |
| Listening queue List | `TrackTile(trackId:, queueItemId:)` | Snapshot cue occurrence, not every duplicate track |
| Listening history | `TrackTile.fromTrack(entry.track)` | Canonical track, not history event ID |
| Local artist/album browse | `_LocalBrowseView` → `NowPlayingRow` | Same IDs as `toPlaybackJson`; no path/title normalization |
| Downloads | `_DownloadListTile` → `NowPlayingRow` | Download's track ID, unknown metadata stays unselected |
| Discover/search/assist/research song candidates | `_buildResultTile` → `NowPlayingRow` | Only playable imported candidate's explicit `playbackTrackId`; unresolved candidates and external previews not guessed |
| Album discovery | `_buildTrackList` → `NowPlayingRow` | Playable library IDs only; catalog MBIDs not confused with library IDs |
| Harmonic suggestions | result `ListTile` → `NowPlayingRow` | Backend match track ID |
| DJ-session browsing rails | `_DjTrackCard` → `NowPlayingRow` | Library track ID; not independent DJ-deck voice state |
| Import queue / playlist import progress | `QueueItem` / job `ListTile` | Intentionally NOT playback rows; no invented current job or queue-position match |

Timeline clips/waveforms, mini/full-player chrome, independent experimental DJ-deck headers,
artist/album/playlist cards, metadata match suggestions, action-menu commands, skeletons and
provider/status rows are not song-list renderers and retain their existing responsibilities.

## Canonical compact list layout

`SongListItem` owns actual list geometry for mobile Home, Library and every `TrackTile`
consumer (including the listening queue); `NowPlayingRow` remains the snapshot selector
and decoration owner. Desktop Home posters deliberately remain cards. Surface wrappers
still own their state, capabilities, swipe/reorder gestures and command callbacks.

Normal text uses a 72 logical-pixel minimum row: a minimum 48-pixel leading slot,
flexible ellipsized title/artist on the left, bounded metadata/duration/actions on the
right, vertically centered on the same horizontal row. Library's 40-pixel verification
artwork remains inside that slot; Queue's 48-pixel grip remains the reorder target.
Home now shows duration on the right, and Library no longer appends it to the artist.
The right budget is 60% of the post-leading width, preserving at least 40% minus the
gap for title/artist. Existing compact chips can fit that budget at normal text.
Only enlarged text (>1.3x) wraps metadata/actions within the right-hand region and grows
row height; it does not place them beneath the title. Selected rows never change height
or action position. The old metadata-triggered expanded renderer and textual status
pill are deleted: orange title/border, a static corner icon and selected/status semantics
communicate the same playing/paused/current states without adding layout height.

## Verification and scope

`test/song_row_presentation_test.dart` covers exact identity, same-title different IDs, A→B,
no item, pause/resume, loading/stopped/stale/unavailable state, local IDs, duplicate occurrences,
shuffled cue ordering, shared widget transitions, row actions and zero position-tick rebuilds.
`test/song_row_authority_guard_test.dart` guards the enumerated adapters and rejects reinstated
per-surface matching/TrackTile current flags and tile-owned styling. It is a bounded source
contract, not an exhaustive detector for arbitrary future renderers; update this inventory when
adding one. Existing Library rebuild test and QueueScreen structure selector remain in use.
`track_tile_active_test.dart` checks compact geometry, selected-height/action-position
stability, status semantics and readable enlarged metadata at 320/390/480/800 pixels.
`track_tile_interaction_regression_test.dart` retains the real keyboard/held-pointer
A→B→clear tests and adds metadata at 2x/3x. `queue_screen_test.dart` mounts actual
QueueScreen, HomeScreen and LibraryTrackListTile at 320/390/480 and 1x/2x/3x, asserting
equal comparable row heights, 72-pixel normal rows, left/right alignment, selection
height invariance, no Flutter layout errors and zero SongListItem rebuilds on ticks.
Existing real queue reorder/swipe/like/menu and Library capability/action tests remain.
Physical-device visuals/accessibility/audio remain parent release gates; widget geometry
is not a substitute for fresh exact-head APK screenshot approval.
