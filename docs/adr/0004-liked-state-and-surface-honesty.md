# ADR 0004: Liked State And Surface Honesty

Date: 2026-07-24

## Status

Accepted.

## Context

Liked state arrived on collection payloads, but individual widgets copied it
into local fields. A successful toggle on one surface therefore left other
hearts stale, and the Library projection omitted `is_liked` entirely. Playlist
membership also had two client write paths, one of which sent string ids in a
shape the backend could not parse.

Several visible player and settings controls were enabled even though their
handlers did nothing or only reported that the destination was unavailable.
Those controls made the shipped surface promise behavior it did not have.

## Decision

- Backend `track_favorites` remains the persistence authority for liked state.
- `LikedTracksState` is the single client authority. Collection and playback
  payloads seed it; every interactive heart reads and toggles it. Logout clears
  its account-scoped values.
- Seeding is limited to values traceable to a backend `is_liked` annotation.
  Unknown remains nullable end to end; model defaults and offline database rows
  never become liked authority, and stale responses cannot overwrite a newer
  local write.
- Liked state never becomes playback, queue, `MixSession`, or
  `PlaybackState` truth. Liked Songs remains a filtered library collection,
  never a materialized playlist.
- `PlaylistService.addTracks(int, List<int>)` is the only playlist-membership
  write path.
- A visible control must perform its advertised action, be disabled with an
  honest reason, or be absent. It must never expose an enabled no-op handler.
- Sharing uses the platform share sheet only when a public source URL exists.
  Playback cache and explicit downloads remain separate storage authorities.

## Consequences

- Optimistic like toggles update all mounted surfaces and roll back everywhere
  when the API write fails.
- Unliking a row in the Liked Songs view changes its heart immediately but does
  not remove the row mid-scroll; collection membership changes on refresh.
- Player output selection is absent until a real output-selection contract
  exists. Metadata repair/matching remains discoverable but honestly disabled.
- Settings cache size and clearing reflect `PlaybackCacheManager`; Downloads
  navigates to the real downloads route and reports `DownloadState` size.

## Enforcement

- `client/test/liked_tracks_state_test.dart` covers optimistic success,
  rollback, and account reset.
- Player, Library, Liked Songs, settings, and playlist service/widget tests
  assert the visible controls and canonical write payloads.
- `docs/context-map.md` maps the authority chain and guardrails for future
  changes.
