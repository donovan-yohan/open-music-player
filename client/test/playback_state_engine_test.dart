import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaybackState engine cutover', () {
    test('restore rebuilds queue paused at saved index and position', () async {
      SharedPreferences.setMockInitialValues({
        QueuePersistenceStore.storageKey: QueueSnapshot(
          tracks: [_track(1, seconds: 30), _track(2, seconds: 45)],
          currentIndex: 1,
          positionMs: 12000,
        ).encode(),
      });
      final playback = _playbackState();

      await playback.restore();
      await Future<void>.delayed(Duration.zero);

      expect(playback.hasTrack, isTrue);
      expect(playback.currentIndex, 1);
      expect(playback.currentItem?.id, '2');
      expect(playback.position, const Duration(seconds: 12));
      expect(playback.duration, const Duration(seconds: 45));
      expect(playback.isPlaying, isFalse);
      playback.dispose();
    });

    test('playQueue start index exposes local position and current media item',
        () async {
      final playback = _playbackState();

      await playback.playQueue([
        _track(1, seconds: 30),
        _track(2, seconds: 45),
      ], startIndex: 1);
      await playback.seek(const Duration(seconds: 7));
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentIndex, 1);
      expect(playback.currentItem?.id, '2');
      expect(playback.position, const Duration(seconds: 7));
      expect(playback.duration, const Duration(seconds: 45));
      expect(playback.isPlaying, isTrue);
      playback.dispose();
    });
  });
}

PlaybackState _playbackState() {
  final clock = DefaultTimelineClock(
    now: () => DateTime.utc(2026),
    uiTickInterval: const Duration(hours: 1),
  );
  final engine = PlaybackEngine.withClock(
    clock: clock,
    voiceFactory: () => FakeVoice('v'),
  );
  return PlaybackState(
    engine,
    signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://example.com/$id.mp3',
              'expiresAt': DateTime.utc(2027, 1, 1).toIso8601String(),
            },
        ],
        'unavailable': <Map<String, dynamic>>[],
      };
    }),
    persistence: QueuePersistenceStore(),
  );
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };
