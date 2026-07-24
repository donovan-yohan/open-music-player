## Found by SoT/duplication audit (2026-07-24, baseline 244046d). All items adversarially cross-checked.

Batch of fold-ins toward single sources of truth. No behavior change intended except where noted.

### Track models (canonical: client/lib/shared/models/track.dart Track)
- Delete dead `class Track` at client/lib/core/models/track.dart:4-148 + client/lib/core/models/mb_suggestion.dart (byte-identical dup of shared MBSuggestion); keep TrackResult/TrackDetail, move to search_result.dart to end the three-way `Track` name collision.
- Delete dead client/lib/shared/models/library_track.dart + TrackTile.fromLibraryTrack (never invoked) + the unreferenced parallel search UI (client/lib/features/search/screens/search_screen.dart + features/search/widgets/ tiles) after a final import check.
- Rename client/lib/models/track.dart `Track` to `QueueTrack` (genuinely distinct: queue-item identity + download lifecycle; the shared NAME is the drift vector).

### Playback payload (5 hand-rolled serializers, one drops analysis)
- Extract `analysisPlaybackFields(TrackAnalysis?)` next to trackAnalysisFromTrackJson and replace the six copy-pasted analysis-forwarding blocks (shared/models/track.dart:87-94,145-152,253-259; models/track.dart:190-197,208-215; search_screen.dart:460-469).
- albumTrackToPlaybackJson (album_detail_screen.dart:24-37) omits analysis entirely — album-launched queues start without tempo/beat data until backfill. Fold into the shared helper.
- Unify id typing (int vs string) and duration units (ms vs s) at the single builder.

### Queue vocabulary
- Remove dead `repeatMode`/`shuffled` from client/lib/models/queue_state.dart:8-9 (+4 copyWith sites in queue_provider.dart) — backend QueueState has no such fields; shuffle/repeat's only home is QueueTimelineController.
- Backend import queue retains phantom playback identity post-#266: `Service.SetCurrentPosition` (backend/internal/queue/queue.go:469) has zero callers/routes — delete it; rename playback-flavored vocabulary (playqueue key, PlaybackState item field) toward import/readiness terms on the next schema-touching change.
- Extract one shared "play collection (shuffled)" helper for the four inconsistent `tracks.shuffle()` copies (playlist_detail_screen.dart:281, album_detail_screen.dart:51, liked_songs_screen.dart:73, local_browse_screens.dart:118), deciding once whether one-shot shuffle sets the controller's shuffleEnabled flag.

### Resolution policy + misc helpers
- Extract the download > cache > signedURL ordering into one shared function used by BOTH PlaybackSourceResolver (playback_source_resolver.dart:47-121) and DefaultEngineAudioSourceResolver (engine_audio_source_resolver.dart:92-133); add a conformance test asserting identical ordering/invalidation. Fold voice_pool._stableUriIdentity (:945-954) into playback_cache_manager.audioObjectIdentity (:52-58).
- One shared formatBytes helper (with GB branch) replacing three copies (cache_provider.dart:13-23, download_state.dart:26-35, downloads_screen.dart:206-210 — the last renders >1GB as "1200.0 MB").
- Dead MixNowPlayingInfo/nowPlayingStream + loadSequentialQueue in playback_engine.dart (:9-19,109-110,149-155) — delete (unused alternate authorities).
- Dead local playlist tables (offline_database.dart:118-138,641-656) — delete or comment as reserved; nothing writes them.
- Per-clip fadeInMs/fadeOutMs on MixSessionClip are serialized but never consumed (envelopes derive solely from overlap in _envelopeFor) — delete fields or wire them; do not leave a third fade path trap.