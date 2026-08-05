import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_continuation.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/screens/queue_screen.dart'
    show ListeningQueueEntry, listeningQueueEntries;

import 'support/fake_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('end-of-queue continuation trigger', () {
    test('a natural completion continues playback exactly once', () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5), _track(91, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
      ]);
      await harness.playToEndOfQueue();

      expect(source.calls, hasLength(1));
      expect(
        harness.playback.queue.map((item) => item.id),
        ['1', '2', '90', '91'],
      );
      // Playback moved into the appended segment instead of staying silent.
      expect(harness.playback.currentIndex, 2);
      expect(harness.playback.isPlaying, isTrue);

      // Ticking again at the same clock position must not re-fire: the trigger
      // is per completion, not per tick.
      harness.tick();
      await pumpEventQueue();
      expect(source.calls, hasLength(1));

      await harness.dispose();
    });

    test('appended items are tagged as auto-continuation, not user-built',
        () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      final queue = harness.playback.queue;
      expect(queue, hasLength(2));
      expect(itemOrigin(queue[0]), queueOriginContext);
      expect(itemOrigin(queue[1]), queueOriginContinuation);

      await harness.dispose();
    });

    test('the first batch excludes every track the listener just heard',
        () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
        _track(3, seconds: 5),
      ]);
      await harness.playToEndOfQueue();

      expect(source.calls.single.excludeTrackIds, {'1', '2', '3'});
      expect(source.calls.single.limit, 2);

      await harness.dispose();
    });

    test('a continuation that plays out triggers a second fetch', () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5), _track(91, seconds: 5)],
          [_track(92, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      expect(source.calls, hasLength(1));
      expect(source.calls[0].excludeTrackIds, {'1'});
      expect(harness.playback.queue.map((item) => item.id), ['1', '90', '91']);

      // The appended batch now plays out on its own. Its last track completing
      // naturally is a fresh exhaustion, not a re-fire of the first one, so the
      // continuation chains rather than stopping after one batch.
      await harness.playToEndOfQueue();

      expect(source.calls, hasLength(2));
      // Exclusion is "everything currently queued", so the second call covers
      // the first continuation batch as well as the listener's own tracks.
      expect(source.calls[1].excludeTrackIds, {'1', '90', '91'});
      expect(
        harness.playback.queue.map((item) => item.id),
        ['1', '90', '91', '92'],
      );
      expect(harness.playback.currentIndex, 3);
      expect(harness.playback.isPlaying, isTrue);
      // Every appended segment stays labelled auto-generated, not just the
      // first one.
      expect(
        harness.playback.queue.map(itemOrigin),
        [
          queueOriginContext,
          queueOriginContinuation,
          queueOriginContinuation,
          queueOriginContinuation,
        ],
      );

      await harness.dispose();
    });

    test('a source with nothing left to offer stops instead of looping',
        () async {
      final source = _RecordingContinuationSource(batches: [[]]);
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      expect(source.calls, hasLength(1));
      expect(harness.playback.queue.map((item) => item.id), ['1']);
      expect(harness.playback.isPlaying, isFalse);
      expect(harness.playback.playbackError, isNull);

      await harness.dispose();
    });
  });

  group('end-of-queue mode gating', () {
    test('off never asks the continuation source for tracks', () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);

      // Default mode; asserted rather than assumed so a changed default fails
      // here instead of silently continuing playback for every listener.
      expect(harness.playback.endOfQueueMode, EndOfQueueMode.off);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      expect(source.calls, isEmpty);
      expect(harness.playback.queue.map((item) => item.id), ['1']);
      expect(harness.playback.isPlaying, isFalse);

      await harness.dispose();
    });

    test('a build without a continuation source stays inert', () async {
      final harness = _Harness();
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      expect(harness.playback.queue.map((item) => item.id), ['1']);
      expect(harness.playback.isPlaying, isFalse);

      await harness.dispose();
    });
  });

  group('manual transport never triggers a continuation', () {
    test('skipping past the last track does not continue', () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
      ]);
      await harness.playback.skipToNext();
      await harness.playback.skipToNext();
      await pumpEventQueue();

      expect(source.calls, isEmpty);

      await harness.dispose();
    });

    test('pause and stop do not continue', () async {
      final source = _RecordingContinuationSource(
        batches: [
          [_track(90, seconds: 5)],
        ],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playback.pause();
      await pumpEventQueue();
      await harness.playback.stop();
      await pumpEventQueue();

      expect(source.calls, isEmpty);

      await harness.dispose();
    });

    test('a stop while the batch is in flight abandons it', () async {
      final gate = _GatedContinuationSource(
        batch: [_track(90, seconds: 5)],
      );
      final harness = _Harness(continuationSource: gate);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      harness.advance(const Duration(seconds: 6));
      await pumpEventQueue();
      expect(gate.pending, isTrue);

      await harness.playback.stop();
      gate.release();
      await pumpEventQueue();

      expect(harness.playback.queue.map((item) => item.id), ['1']);
      expect(harness.playback.isPlaying, isFalse);

      await harness.dispose();
    });
  });

  group('offline fallback', () {
    test('a failing fetch degrades silently to stopping', () async {
      final harness = _Harness(
        continuationSource: _ThrowingContinuationSource(),
      );
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();

      expect(harness.playback.queue.map((item) => item.id), ['1']);
      expect(harness.playback.isPlaying, isFalse);
      // The listener never asked for this fetch, so a failure must not surface.
      expect(harness.playback.playbackError, isNull);
      expect(harness.playback.isResolvingSignedUrl, isFalse);

      await harness.dispose();
    });

    test('a later completion can still continue after a failed one', () async {
      final source = _FlakyContinuationSource(
        batch: [_track(90, seconds: 5)],
      );
      final harness = _Harness(continuationSource: source);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);

      await harness.playback.playQueue([_track(1, seconds: 5)]);
      await harness.playToEndOfQueue();
      expect(harness.playback.queue, hasLength(1));

      // Replaying the same queue re-arms the clock, so the next natural end is
      // a fresh trigger rather than a retry of the failed one.
      await harness.playback.play();
      await harness.playToEndOfQueue();

      expect(source.calls, 2);
      expect(harness.playback.queue.map((item) => item.id), ['1', '90']);

      await harness.dispose();
    });
  });

  group('continuation persistence', () {
    test('the origin marker survives a queue snapshot round trip', () {
      const item = MediaItem(
        id: '90',
        title: 'Continued',
        duration: Duration(seconds: 5),
        extras: {'url': 'https://signed/90'},
      );
      final json = mediaItemToPlaybackJson(
        markOrigin(item, queueOriginContinuation),
      );

      expect(json['itemOrigin'], queueOriginContinuation);
      expect(
        QueueSnapshot(tracks: [json]).toJson()['tracks'],
        [containsPair('itemOrigin', queueOriginContinuation)],
      );
    });

    test('an unmarked item stays unmarked', () {
      const item = MediaItem(id: '1', title: 'Plain');
      expect(mediaItemToPlaybackJson(item).containsKey('itemOrigin'), isFalse);
    });
  });

  group('queue screen continuation marker', () {
    test('marks only the first item of a continuation segment', () {
      final entries = listeningQueueEntries(
        queue: [
          _mediaItem('1'),
          markOrigin(_mediaItem('2'), queueOriginManual),
          markOrigin(_mediaItem('90'), queueOriginContinuation),
          markOrigin(_mediaItem('91'), queueOriginContinuation),
        ],
        currentIndex: 0,
      );

      expect(
        entries.map((entry) => entry.isContinuationStart),
        [false, false, true, false],
      );
    });

    test('a queue with no continuation has no section header', () {
      final entries = listeningQueueEntries(
        queue: [_mediaItem('1'), _mediaItem('2')],
        currentIndex: 0,
      );
      expect(
        entries.every((ListeningQueueEntry e) => !e.isContinuationStart),
        isTrue,
      );
    });
  });
}

class _Harness {
  _Harness({QueueContinuationSource? continuationSource}) {
    clock = DefaultTimelineClock(
      now: () => now,
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
      continuationSource: continuationSource,
      continuationBatchSize: 2,
      persistenceDebounce: Duration.zero,
    );
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final PlaybackState playback;
  DateTime now = DateTime.utc(2026);

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }

  void tick() => clock.tickForTest();

  /// Plays the queue out to its natural end and settles every follow-up task.
  Future<void> playToEndOfQueue() async {
    advance(const Duration(minutes: 1));
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    playback.dispose();
    await pumpEventQueue();
  }
}

class _ContinuationCall {
  const _ContinuationCall(this.excludeTrackIds, this.limit);

  final Set<String> excludeTrackIds;
  final int limit;
}

class _RecordingContinuationSource implements QueueContinuationSource {
  _RecordingContinuationSource({required this.batches});

  final List<List<Map<String, dynamic>>> batches;
  final calls = <_ContinuationCall>[];

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  }) async {
    calls.add(_ContinuationCall(excludeTrackIds, limit));
    if (calls.length > batches.length) return const [];
    return batches[calls.length - 1];
  }
}

class _ThrowingContinuationSource implements QueueContinuationSource {
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  }) async {
    throw Exception('offline');
  }
}

class _FlakyContinuationSource implements QueueContinuationSource {
  _FlakyContinuationSource({required this.batch});

  final List<Map<String, dynamic>> batch;
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  }) async {
    calls++;
    if (calls == 1) throw Exception('offline');
    return batch;
  }
}

class _GatedContinuationSource implements QueueContinuationSource {
  _GatedContinuationSource({required this.batch});

  final List<Map<String, dynamic>> batch;
  Completer<void>? _gate;

  bool get pending => _gate != null && !_gate!.isCompleted;

  void release() => _gate?.complete();

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  }) async {
    final gate = Completer<void>();
    _gate = gate;
    await gate.future;
    return batch;
  }
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

MediaItem _mediaItem(String id) => MediaItem(
      id: id,
      title: 'Track $id',
      duration: const Duration(seconds: 5),
    );
