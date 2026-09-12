import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_voice.dart';

/// Measures how many [PlaybackState] notifications one UI position tick costs.
///
/// Every widget that does `context.watch<PlaybackState>()` rebuilds once per
/// notification, so this number multiplies directly into per-frame widget work
/// while a list is on screen. The clock ticks at 150ms, so the steady-state
/// rebuild rate for those widgets is `notificationsPerTick * 6.67 / second`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one position tick costs a bounded number of notifications', () async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026);
    final clock = DefaultTimelineClock(
      now: () => now,
      // Disable the real periodic timer; the test drives ticks by hand.
      uiTickInterval: const Duration(hours: 1),
    );
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
    );
    final playback = _playbackState(engine);
    addTearDown(playback.dispose);

    await playback.playQueue([
      _track(1, seconds: 300),
      _track(2, seconds: 300),
    ]);
    await pumpEventQueue();

    var notifications = 0;
    playback.addListener(() => notifications++);

    const tickCount = 20;
    for (var i = 0; i < tickCount; i++) {
      now = now.add(const Duration(milliseconds: 150));
      clock.tickForTest();
      await pumpEventQueue();
    }

    final perTick = notifications / tickCount;
    // ignore: avoid_print
    print('PERF notificationsPerTick=$perTick '
        'notificationsPerSecond=${(perTick * 1000 / 150).toStringAsFixed(1)}');

    expect(
      perTick,
      lessThanOrEqualTo(1.0),
      reason: 'A steady position tick changes only the position. Duration, '
          'buffered position and current media item republish unchanged '
          'values, and each extra republish rebuilds every PlaybackState '
          'watcher on screen. Budget: one notification per tick.',
    );
  });
}

PlaybackState _playbackState(PlaybackEngine engine) {
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

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'durationMs': seconds * 1000,
    };
