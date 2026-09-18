// Regressions for starting playback from an explicit user command (enqueue /
// play-next) while the listening queue is empty.
//
// PR #476 fixed the *origin* half of this path: a user-issued "Add to queue" on
// an empty queue must be tagged `manual`, not `context` (that half stays in
// `queue_ordering_test.dart`). It regressed the *transport* half by inserting
// through `enqueueAll` and then calling `play()` after the resolution await.
//
// These tests pin the lifecycle the replaced path used to provide, for BOTH
// entry points, against the real engine over FakeVoice:
//
//   * a stop/pause that arrives while the signed URL is still resolving wins;
//     the late start must not invent playback intent;
//   * a context-less manual start clears `playbackContext` rather than
//     inheriting the attribution of a playlist whose queue was drained;
//   * `isResolvingSignedUrl` and a user-facing `playbackError` stay observable
//     to listeners on this path.
//
// Every test here fails at 547fdc5 (the bare `await play()` version) and passes
// with the shared guarded replacement lifecycle in
// `PlaybackState._startManualTrack`.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

/// A signed-URL requester whose responses are released by the test, so the
/// resolution window is a real await the test can act inside.
class _GatedSignedUrls {
  final requests = <_GatedRequest>[];

  late final SignedAudioUrlService service =
      SignedAudioUrlService.withRequester((body) {
    final request = _GatedRequest((body['trackIds'] as List).cast<int>());
    requests.add(request);
    return request.completer.future;
  });

  /// Resolves a track to a fresh remote descriptor.
  void release(int index) {
    final request = requests[index];
    if (request.completer.isCompleted) return;
    request.completer.complete(_responseFor(request.trackIds));
  }

  /// Resolves every track as unavailable, which is how the backend reports a
  /// track whose audio cannot be served.
  void releaseUnavailable(int index) {
    final request = requests[index];
    if (request.completer.isCompleted) return;
    request.completer.complete(<String, dynamic>{
      'urls': <Map<String, dynamic>>[],
      'unavailable': [
        for (final id in request.trackIds)
          {
            'trackId': id,
            'code': 'audio_unavailable',
            'message': 'not on disk',
          },
      ],
    });
  }

  Future<void> waitForRequestCount(int count) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (requests.length >= count) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('Timed out waiting for $count signed-url requests; '
        'saw ${requests.length}');
  }
}

Map<String, dynamic> _responseFor(List<int> ids) => <String, dynamic>{
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

class _GatedRequest {
  _GatedRequest(this.trackIds);

  final List<int> trackIds;
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();
}

Map<String, dynamic> _track(int id, {int seconds = 60}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

PlaybackState _playbackState(SignedAudioUrlService service) {
  SharedPreferences.setMockInitialValues({});
  return PlaybackState(
    PlaybackEngine.withClock(
      clock: DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1),
      ),
      voiceFactory: () => FakeVoice('v'),
    ),
    signedAudioUrlService: service,
    persistence: QueuePersistenceStore(),
    persistenceDebounce: Duration.zero,
  );
}

/// Drains the microtask queue so a released request has fully landed.
Future<void> _settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The two user commands that start playback on an empty queue. Both must share
/// one lifecycle; naming them here keeps the loop honest.
final _emptyQueueStartCommands =
    <String, Future<void> Function(PlaybackState, Map<String, dynamic>)>{
  'enqueue': (playback, track) => playback.enqueue(track),
  'playNext': (playback, track) => playback.playNext(track),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in _emptyQueueStartCommands.entries) {
    final command = entry.key;
    final start = entry.value;

    group('empty-queue $command', () {
      test('stop while the signed URL resolves is not overridden', () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final pending = start(playback, _track(9001));
        await gated.waitForRequestCount(1);

        await playback.stop();
        expect(playback.isPlaying, isFalse);

        gated.release(0);
        await pending;
        await _settle();

        expect(
          playback.isPlaying,
          isFalse,
          reason: 'a stop issued before resolution returned must win; a late '
              'start would be playback the user explicitly ended',
        );
        expect(playback.queue, isEmpty);
        expect(playback.currentItem, isNull);
      });

      test('pause while the signed URL resolves is not overridden', () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final pending = start(playback, _track(9002));
        await gated.waitForRequestCount(1);

        await playback.pause();

        gated.release(0);
        await pending;
        await _settle();

        expect(playback.isPlaying, isFalse,
            reason: 'pause cancels a pending start, as the replacement path '
                'already guarantees');
        expect(playback.queue, isEmpty);
      });

      test('clears a drained playlist context instead of inheriting it',
          () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final playlist = playback.playQueue(
          [_track(1, seconds: 5), _track(2, seconds: 5)],
          context: const PlaybackContext(
            kind: PlaybackContextKind.playlist,
            label: 'My Playlist',
            id: '77',
          ),
        );
        await gated.waitForRequestCount(1);
        gated.release(0);
        await playlist;
        await _settle();
        expect(playback.playbackContext, isNotNull);

        while (playback.queue.isNotEmpty) {
          await playback.removeFromQueue(0);
          await _settle(3);
        }

        final pending = start(playback, _track(9003));
        await gated.waitForRequestCount(2);
        gated.release(1);
        await pending;
        await _settle();

        expect(playback.queue, hasLength(1));
        expect(playback.isPlaying, isTrue);
        expect(
          playback.playbackContext,
          isNull,
          reason: 'a manual track started without a context must not be '
              'attributed to the playlist whose queue was drained',
        );
      });

      test('surfaces isResolvingSignedUrl while the URL is in flight',
          () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final pending = start(playback, _track(9004));
        await gated.waitForRequestCount(1);

        expect(playback.isResolvingSignedUrl, isTrue,
            reason: 'a resolving indicator must be visible on this path too');
        expect(playback.isPlaying, isFalse);

        gated.release(0);
        await pending;
        await _settle();

        expect(playback.isResolvingSignedUrl, isFalse);
        expect(playback.isPlaying, isTrue);
      });

      test('surfaces a user-facing playbackError when resolution fails',
          () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        Object? thrown;
        try {
          final pending = start(playback, _track(9005));
          await gated.waitForRequestCount(1);
          gated.releaseUnavailable(0);
          await pending;
        } catch (error) {
          thrown = error;
        }
        await _settle();

        expect(thrown, isA<SignedAudioUrlException>());
        expect(
          playback.playbackError,
          'Audio is unavailable for this track.',
          reason: 'the in-app error affordance reads playbackError, so the '
              'state-level error must be set even though the exception also '
              'propagates to the caller',
        );
        expect(playback.queue, isEmpty);
        expect(playback.isPlaying, isFalse);
      });

      test('tags the started item manual and actually plays it', () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final pending = start(playback, _track(9006));
        await gated.waitForRequestCount(1);
        gated.release(0);
        await pending;
        await _settle();

        expect(itemOrigin(playback.queue.single), queueOriginManual);
        expect(playback.currentItem?.id, '9006');
        expect(playback.isPlaying, isTrue);
      });

      test('a different track started meanwhile wins the race', () async {
        final gated = _GatedSignedUrls();
        final playback = _playbackState(gated.service);
        addTearDown(playback.dispose);

        final pending = start(playback, _track(9007));
        await gated.waitForRequestCount(1);

        final other = playback.playTrack(_track(9100));
        await gated.waitForRequestCount(2);

        gated.release(0);
        gated.release(1);
        await pending;
        await other;
        await _settle();

        expect(playback.queue.map((item) => item.id), ['9100']);
        expect(playback.isPlaying, isTrue);
      });
    });
  }
}
