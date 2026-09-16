import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_voice.dart';

/// Playback-truth fixtures for the DJ surfaces (ADR 0012 step 3).
///
/// The deck and the DJ session read "what is playing" from the playback queue,
/// so their tests need a real [PlaybackState] rather than an import-queue
/// snapshot. Everything here is the production object graph over fake voices:
/// `QueueTimelineController` under a real `PlaybackEngine`, so play order,
/// cue identity and the 33 Hz snapshot stream behave exactly as they do on a
/// device.

/// A [PlaybackState] over [FakeVoice]s with a deterministic clock.
///
/// The clock's periodic UI tick is parked an hour out; tests that need position
/// motion drive it by hand through [testTimelineClockOf].
PlaybackState testPlaybackState({PlaybackEngine? engine}) {
  SharedPreferences.setMockInitialValues({});
  return PlaybackState(
    engine ??
        PlaybackEngine.withClock(
          clock: DefaultTimelineClock(
            now: () => DateTime.utc(2026),
            uiTickInterval: const Duration(hours: 1),
          ),
          voiceFactory: () => FakeVoice('playback'),
        ),
    signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://example.com/$id.mp3',
              'expiresAt': DateTime.utc(2027).toIso8601String(),
            },
        ],
        'unavailable': <Map<String, dynamic>>[],
      };
    }),
    persistence: QueuePersistenceStore(),
    persistenceDebounce: Duration.zero,
  );
}

/// The playback-json payload for a library track, shaped like the resolver's
/// input (numeric id, whole-second duration).
Map<String, dynamic> playbackTrackPayload(
  int id, {
  String? title,
  String artist = 'Fixture artist',
  int seconds = 245,
}) =>
    {
      'id': id,
      'title': title ?? 'Track $id',
      'artist': artist,
      'album': 'Fixture album',
      'duration': seconds,
    };

/// Plays [ids] as a collection — the "play an album" path, which populates the
/// listening queue while leaving any import queue untouched.
Future<void> playAlbum(
  PlaybackState playback,
  List<int> ids, {
  int startIndex = 0,
}) async {
  await playback.playQueue(
    [for (final id in ids) playbackTrackPayload(id)],
    startIndex: startIndex,
  );
}
