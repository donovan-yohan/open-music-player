# Now-playing song rows

Song-row playback identity is projected by `songRowPresentationFor(snapshot, trackId:, queueItemId:)`.
`NowPlayingRow` selects only this enum from `PlaybackState.snapshot`; `SongRowTreatment` owns
Library-orange fill/title/border and selected semantics. `TrackTile.fromTrack` supplies the library
ID automatically. Direct `TrackTile` constructors must supply a canonical `trackId`; listening
queue entries additionally supply their cue's stable `queueItemId`. No title/context matching.
No playback authority is added (ADR 0001/0012). Badge icons are deliberately static. Selected
tracks stay highlighted while paused/loading; only a coherent ready cue with active voices
can say “Now playing”. All other selected states use “Current track”, not a playing claim.

## Renderer inventory

| Surface | Renderer / integration | Identity / exception |
| --- | --- | --- |
| Home mobile recent/top | `_TrackTile` → `NowPlayingRow` | Library track ID; unavailable rows retain existing disabled actions |
| Home desktop rotation | `_DesktopPoster` → `NowPlayingRow` | Track ID; playlist posters have null identity |
| Library, including local search/filter results | `LibraryTrackListTile` → `NowPlayingRow` | Exact library ID; downloaded/local payloads retain that ID |
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

## Verification and scope

`test/song_row_presentation_test.dart` covers exact identity, same-title different IDs, A→B,
no item, pause/resume, loading/stopped/stale/unavailable state, local IDs, duplicate occurrences,
shuffled cue ordering, shared widget transitions, row actions and zero position-tick rebuilds.
`test/song_row_authority_guard_test.dart` guards the enumerated adapters and rejects reinstated
per-surface matching/TrackTile current flags and tile-owned styling. It is a bounded source
contract, not an exhaustive detector for arbitrary future renderers; update this inventory when
adding one. Existing Library rebuild test and QueueScreen structure selector remain in use.
Physical-device visuals/accessibility/audio and full-suite integration remain parent release gates.
