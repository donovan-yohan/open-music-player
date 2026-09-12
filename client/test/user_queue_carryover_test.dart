import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/models/mix_plan.dart';

import 'support/fake_voice.dart';

/// The user queue (manually queued tracks) is an active queue that outlives the
/// passive queue — library, album, playlist — it was built on top of.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('manual queue placement within one context', () {
    test('add-to-queue lands after an existing manual run', () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2), _track(3)]);

      await harness.playback.enqueue(_track(90));
      await harness.playback.enqueue(_track(91));

      expect(harness.ids, ['1', '90', '91', '2', '3']);
      await harness.dispose();
    });

    test('play-next jumps ahead of an existing manual run', () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2), _track(3)]);

      await harness.playback.enqueue(_track(90));
      await harness.playback.enqueue(_track(91));
      await harness.playback.playNext(_track(92));

      expect(harness.ids, ['1', '92', '90', '91', '2', '3']);
      await harness.dispose();
    });
  });

  group('carry-over across a context switch', () {
    test('the tapped track plays first, then the user queue, then the rest',
        () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));
      await harness.playback.enqueue(_track(91));

      // Playlist B, started from its second track.
      await harness.playback.playQueue(
        [_track(10), _track(11), _track(12)],
        startIndex: 1,
      );

      expect(harness.ids, ['10', '11', '90', '91', '12']);
      // The tapped track is still what is playing.
      expect(harness.playback.currentIndex, 1);
      expect(harness.playback.currentItem?.id, '11');
      await harness.dispose();
    });

    test(
        'carried-over items stay manual, so the next add-to-queue follows them',
        () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));

      await harness.playback.playQueue([_track(10), _track(11)]);
      expect(
        harness.playback.queue.map(itemOrigin),
        [queueOriginContext, queueOriginManual, queueOriginContext],
      );

      await harness.playback.enqueue(_track(91));
      expect(harness.ids, ['10', '90', '91', '11']);
      await harness.dispose();
    });

    test('a manual item the listener already heard is not resurrected',
        () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));
      await harness.playback.enqueue(_track(91));
      expect(harness.ids, ['1', '90', '91', '2']);

      // Listen through 90 and into 91, which is now the current item.
      await harness.playback.skipToIndex(2);
      expect(harness.playback.currentItem?.id, '91');

      await harness.playback.playQueue([_track(10), _track(11)]);

      // 90 is behind the playhead and 91 is the track being left; only the
      // still-upcoming user queue survives, and here there is none.
      expect(harness.ids, ['10', '11']);
      await harness.dispose();
    });

    test('playing a single track keeps the user queue behind it', () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));

      await harness.playback.playTrack(_track(10));

      expect(harness.ids, ['10', '90']);
      await harness.dispose();
    });

    test('with the setting off a new context replaces the whole queue',
        () async {
      final harness = _Harness();
      harness.playback.setPreserveManualQueue(false);
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));
      expect(harness.ids, ['1', '90', '2']);

      await harness.playback.playQueue([_track(10), _track(11)]);

      expect(harness.ids, ['10', '11']);
      await harness.dispose();
    });

    test('a mix plan is never spliced, so its clips stay aligned', () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));

      await harness.playback.playMixPlan(
        [_track(10), _track(11)],
        _mixPlan(const ['10', '11']),
      );

      expect(harness.ids, ['10', '11']);
      await harness.dispose();
    });
  });

  group('swipe default', () {
    test('add-to-queue and play-next are both honored', () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1), _track(2)]);
      await harness.playback.enqueue(_track(90));

      await harness.playback.queueTrack(
        _track(91),
        mode: QueueInsertMode.addToQueue,
      );
      expect(harness.ids, ['1', '90', '91', '2']);

      await harness.playback.queueTrack(
        _track(92),
        mode: QueueInsertMode.playNext,
      );
      expect(harness.ids, ['1', '92', '90', '91', '2']);
      await harness.dispose();
    });
  });

  group('persistence', () {
    test('a carried-over item is still manual after a snapshot round trip',
        () async {
      final harness = _Harness();
      await harness.playback.playQueue([_track(1)]);
      await harness.playback.enqueue(_track(90));
      await harness.playback.playQueue([_track(10)]);

      final snapshot = QueueSnapshot(
        tracks: harness.playback.queue.map(mediaItemToPlaybackJson).toList(),
      );
      final restored = QueueSnapshot.decode(snapshot.encode());

      expect(
        restored.tracks.map((track) => track['itemOrigin']),
        [null, queueOriginManual],
      );
      await harness.dispose();
    });
  });
}

/// A minimal two-clip plan whose clips are positionally bound to [trackIds].
MixPlan _mixPlan(List<String> trackIds) {
  const clipDurationMs = 5000;
  final now = DateTime.utc(2026);
  return MixPlan(
    id: 'plan',
    schemaVersion: 1,
    name: 'Plan',
    clips: [
      for (var index = 0; index < trackIds.length; index++)
        MixPlanClip(
          clipId: 'clip-$index',
          queueItemId: 'queue-$index',
          trackId: trackIds[index],
          sourceStartMs: 0,
          sourceEndMs: clipDurationMs,
          timelineStartMs: index * clipDurationMs,
        ),
    ],
    summary: MixPlanSummary(
      clipCount: trackIds.length,
      trackIds: trackIds,
      durationMs: trackIds.length * clipDurationMs,
    ),
    version: 1,
    createdAt: now,
    updatedAt: now,
  );
}

Map<String, dynamic> _track(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': 5,
    };

class _Harness {
  _Harness() {
    clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
    );
    playback = PlaybackState(
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
      persistenceDebounce: Duration.zero,
    );
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final PlaybackState playback;

  List<String> get ids =>
      playback.queue.map((item) => item.id).toList(growable: false);

  Future<void> dispose() async {
    playback.dispose();
    await pumpEventQueue();
  }
}
