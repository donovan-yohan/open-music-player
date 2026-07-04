import 'dart:async';

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

    test('direct replacement silences old audio while next URL resolves',
        () async {
      SharedPreferences.setMockInitialValues({});
      final signed = _DelayedSignedRequester();
      final playback = _playbackState(signedAudioUrlService: signed.service);

      final firstStart = playback.playQueue([_track(1, seconds: 60)]);
      await signed.waitForRequestCount(1);
      signed.completeRequest(0);
      await firstStart;
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentItem?.id, '1');
      expect(playback.isPlaying, isTrue);

      final replacement = playback.playQueue([_track(2, seconds: 30)]);
      await signed.waitForRequestCount(2);
      await Future<void>.delayed(Duration.zero);

      expect(playback.hasTrack, isFalse);
      expect(playback.currentItem, isNull);
      expect(playback.isPlaying, isFalse);
      expect(playback.isResolvingSignedUrl, isTrue);

      signed.completeRequest(1);
      await replacement;
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentItem?.id, '2');
      expect(playback.position, Duration.zero);
      expect(playback.isPlaying, isTrue);
      playback.dispose();
    });

    test('pause cancels a pending direct replacement autoplay', () async {
      SharedPreferences.setMockInitialValues({});
      final signed = _DelayedSignedRequester();
      final playback = _playbackState(signedAudioUrlService: signed.service);

      final firstStart = playback.playQueue([_track(1, seconds: 60)]);
      await signed.waitForRequestCount(1);
      signed.completeRequest(0);
      await firstStart;
      await Future<void>.delayed(Duration.zero);

      final replacement = playback.playQueue([_track(2, seconds: 30)]);
      await signed.waitForRequestCount(2);
      await playback.pause();

      expect(playback.isResolvingSignedUrl, isFalse);
      expect(playback.isPlaying, isFalse);

      signed.completeRequest(1);
      await replacement;
      await Future<void>.delayed(Duration.zero);

      expect(playback.hasTrack, isFalse);
      expect(playback.currentItem, isNull);
      expect(playback.isPlaying, isFalse);
      playback.dispose();
    });

    test('signed URL refresh preserves active local position', () async {
      SharedPreferences.setMockInitialValues({});
      var descriptorCalls = 0;
      final playback = _playbackState(
        signedAudioUrlService:
            SignedAudioUrlService.withRequester((body) async {
          descriptorCalls++;
          final id = (body['trackIds'] as List).cast<int>().single;
          return {
            'urls': [
              {
                'trackId': id,
                'url': 'https://example.com/$id-v$descriptorCalls.mp3',
                'expiresAt': DateTime.now()
                    .toUtc()
                    .add(const Duration(seconds: 30))
                    .toIso8601String(),
              },
            ],
            'unavailable': <Map<String, dynamic>>[],
          };
        }),
      );

      await playback.playQueue([_track(1, seconds: 60)]);
      await playback.seek(const Duration(seconds: 15));
      await playback.play();
      await Future<void>.delayed(Duration.zero);

      expect(descriptorCalls, 2);
      expect(playback.position, const Duration(seconds: 15));
      expect(
        playback.currentItem?.extras?['url'],
        'https://example.com/1-v2.mp3',
      );
      playback.dispose();
    });
  });
}

PlaybackState _playbackState({SignedAudioUrlService? signedAudioUrlService}) {
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
    signedAudioUrlService: signedAudioUrlService ??
        SignedAudioUrlService.withRequester((body) async {
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

class _DelayedSignedRequester {
  final requests = <_SignedRequest>[];

  late final SignedAudioUrlService service =
      SignedAudioUrlService.withRequester((body) {
    final ids = (body['trackIds'] as List).cast<int>();
    final request = _SignedRequest(ids);
    requests.add(request);
    return request.completer.future;
  });

  Future<void> waitForRequestCount(int count) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (requests.length >= count) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail(
        'Timed out waiting for $count signed-url requests; saw ${requests.length}');
  }

  void completeRequest(int index) {
    final request = requests[index];
    request.completer.complete({
      'urls': [
        for (final id in request.trackIds)
          {
            'trackId': id,
            'url': 'https://example.com/$id.mp3',
            'expiresAt': DateTime.utc(2027, 1, 1).toIso8601String(),
          },
      ],
      'unavailable': <Map<String, dynamic>>[],
    });
  }
}

class _SignedRequest {
  _SignedRequest(this.trackIds);

  final List<int> trackIds;
  final Completer<Map<String, dynamic>> completer = Completer();
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };
