import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaybackState engine cutover', () {
    test('empty queue keeps the configured crossfade facade value', () async {
      SharedPreferences.setMockInitialValues({});
      final playback = _playbackState();
      await playback.applyAudioDefaults(
        const AudioPlaybackDefaults(defaultCrossfadeMs: 3000),
      );
      await playback.playQueue([_track(1, seconds: 10)]);

      await playback.removeFromQueue(0);

      expect(playback.hasTrack, isFalse);
      expect(playback.defaultCrossfadeMs, 3000);
      playback.dispose();
    });

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

    test('restore preserves canonical mix-session timing metadata', () async {
      final session = MixSession.fromQueue(
        sessionId: 'session_restore',
        queue: [
          const MediaItem(
            id: '1',
            title: 'Track 1',
            duration: Duration(seconds: 30),
          ),
          const MediaItem(
            id: '2',
            title: 'Track 2',
            duration: Duration(seconds: 45),
          ),
        ],
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: '2',
          sourceDurationMs: 45000,
          sourceStartMs: 5000,
          sourceEndMs: 40000,
          timelineStartMs: 25000,
        ),
      );
      SharedPreferences.setMockInitialValues({
        QueuePersistenceStore.storageKey: QueueSnapshot(
          tracks: [_track(1, seconds: 30), _track(2, seconds: 45)],
          currentIndex: 1,
          positionMs: 12000,
          session: session,
        ).encode(),
      });
      final playback = _playbackState();

      await playback.restore();
      await Future<void>.delayed(Duration.zero);

      final restoredClip = playback.timelineModel.clips[1].placement;
      expect(restoredClip.sourceStartMs, 5000);
      expect(restoredClip.sourceEndMs, 40000);
      expect(restoredClip.timelineStartMs, 25000);
      expect(playback.position, const Duration(seconds: 12));
      expect(playback.timelinePositionMs, 37000);
      expect(playback.isPlaying, isFalse);
      playback.dispose();
    });

    test('restore protects persisted session from seeded emissions', () async {
      final session = MixSession.fromQueue(
        sessionId: 'session_startup_gate',
        queue: [
          const MediaItem(
            id: '1',
            title: 'Track 1',
            duration: Duration(seconds: 30),
          ),
          const MediaItem(
            id: '2',
            title: 'Track 2',
            duration: Duration(seconds: 45),
          ),
        ],
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: '2',
          sourceDurationMs: 45000,
          sourceStartMs: 5000,
          sourceEndMs: 40000,
          timelineStartMs: 25000,
        ),
      );
      final storedSnapshot = QueueSnapshot(
        tracks: [_track(1, seconds: 30), _track(2, seconds: 45)],
        currentIndex: 1,
        positionMs: 12000,
        session: session,
      );
      SharedPreferences.setMockInitialValues({
        QueuePersistenceStore.storageKey: storedSnapshot.encode(),
      });
      final store = QueuePersistenceStore();
      final playback = _playbackState(persistence: store);

      // Queue and index streams emit their seeded empty values before startup
      // calls restore. They must not erase the durable snapshot.
      await Future<void>.delayed(Duration.zero);
      final beforeRestore = await store.load();
      expect(beforeRestore.tracks, hasLength(2));
      expect(beforeRestore.session?.sessionId, 'session_startup_gate');

      await playback.restore();
      await Future<void>.delayed(Duration.zero);

      final afterRestore = await store.load();
      expect(playback.queue.map((item) => item.id), ['1', '2']);
      expect(playback.currentIndex, 1);
      expect(playback.position, const Duration(seconds: 12));
      expect(playback.timelineModel.clips[1].placement.sourceStartMs, 5000);
      expect(afterRestore.tracks, hasLength(2));
      expect(afterRestore.session?.sessionId, 'session_startup_gate');
      expect(afterRestore.session?.clips[1].placement.timelineStartMs, 25000);

      await playback.removeFromQueue(1);
      await playback.removeFromQueue(0);
      await Future<void>.delayed(Duration.zero);

      expect((await store.load()).isEmpty, isTrue);
      playback.dispose();
    });

    test('queue mutation during restore resolve wins and is persisted',
        () async {
      final session = MixSession.fromQueue(
        sessionId: 'session_delayed_restore',
        queue: [
          const MediaItem(
            id: '1',
            title: 'Track 1',
            duration: Duration(seconds: 30),
          ),
          const MediaItem(
            id: '2',
            title: 'Track 2',
            duration: Duration(seconds: 45),
          ),
        ],
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: '2',
          sourceDurationMs: 45000,
          sourceStartMs: 5000,
          sourceEndMs: 40000,
          timelineStartMs: 25000,
        ),
      );
      final store = _ControllableQueuePersistenceStore();
      final signed = _DelayedSignedRequester();
      final playback = _playbackState(
        signedAudioUrlService: signed.service,
        persistence: store,
      );

      final restore = playback.restore();
      await store.waitForLoad();
      store.completeLoad(
        QueueSnapshot(
          tracks: [_track(1, seconds: 30), _track(2, seconds: 45)],
          currentIndex: 1,
          positionMs: 12000,
          session: session,
        ),
      );
      await signed.waitForRequestCount(1);

      final mutation = playback.playQueue([_track(3, seconds: 60)]);
      await signed.waitForRequestCount(2);
      signed.completeRequest(1);
      await mutation;

      expect(playback.queue.map((item) => item.id), ['3']);
      expect(store.savedSnapshots, isEmpty);

      signed.completeRequest(0);
      await restore;
      await Future<void>.delayed(Duration.zero);

      expect(playback.queue.map((item) => item.id), ['3']);
      expect(store.savedSnapshots, isNotEmpty);
      expect(store.savedSnapshots.last.tracks.single['id'], 3);
      expect(store.savedSnapshots.last.session?.sessionId,
          isNot('session_delayed_restore'));
      playback.dispose();
    });

    test('empty restore opens persistence without replaying startup seeds',
        () async {
      final store = _ControllableQueuePersistenceStore();
      final playback = _playbackState(persistence: store);

      final restore = playback.restore();
      await store.waitForLoad();
      store.completeLoad(const QueueSnapshot());
      await restore;

      expect(store.savedSnapshots, isEmpty);

      await playback.playQueue([_track(4, seconds: 30)]);
      await Future<void>.delayed(Duration.zero);

      expect(store.savedSnapshots.last.tracks.single['id'], 4);
      playback.dispose();
    });

    test('restore failure opens persistence for later queue changes', () async {
      final store = _ControllableQueuePersistenceStore();
      final playback = _playbackState(persistence: store);

      final restore = playback.restore();
      await store.waitForLoad();
      store.failLoad(StateError('test load failure'));
      await restore;

      expect(store.savedSnapshots, isEmpty);

      await playback.playQueue([_track(5, seconds: 30)]);
      await Future<void>.delayed(Duration.zero);

      expect(store.savedSnapshots.last.tracks.single['id'], 5);
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

    test('audio defaults facade reaches the current mix session', () async {
      SharedPreferences.setMockInitialValues({});
      final playback = _playbackState();

      await playback.playQueue([
        _track(1, seconds: 10),
        _track(2, seconds: 10),
      ]);
      await playback.applyAudioDefaults(
        const AudioPlaybackDefaults(defaultCrossfadeMs: 3000),
      );

      expect(playback.defaultCrossfadeMs, 3000);
      expect(playback.timelineModel.clips[1].timelineStartMs, 7000);
      expect(playback.timelineModel.clips[0].envelope.fadeOutMs, 3000);
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

    test('toggle cancels a pending direct replacement autoplay', () async {
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
      await playback.togglePlayPause();

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
                'codec': descriptorCalls == 1 ? 'unknown' : 'mp3',
                'bitrateKbps': descriptorCalls == 1 ? 1 : 137,
                'sampleRateHz': descriptorCalls == 1 ? 8000 : 44100,
                'channels': descriptorCalls == 1 ? 1 : 2,
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
      expect(playback.currentItem?.extras?['codec'], 'mp3');
      expect(playback.currentItem?.extras?['bitrateKbps'], 137);
      expect(playback.currentItem?.extras?['sampleRateHz'], 44100);
      expect(playback.currentItem?.extras?['channels'], 2);
      playback.dispose();
    });

    test('analysis refresh updates active timeline tempo automation', () async {
      SharedPreferences.setMockInitialValues({});
      final playback = _playbackState();

      await playback.playQueue([
        _track(1, seconds: 20),
        _track(2, seconds: 20),
      ]);
      await playback.setQueueTimelineStartMs(
        1,
        12000,
        snapToDownbeat: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(playback.timelineModel.clips[0].tempo.nativeBpm, isNull);
      expect(playback.timelineModel.clips[1].tempo.nativeBpm, isNull);

      await playback.refreshTrackAnalysis(
        '1',
        _analysis(
          bpm: 100,
          downbeatsMs: [0, 8000, 16000],
          updatedAt: DateTime.utc(2026, 7, 10, 11, 0, 0, 123, 456),
        ),
      );
      await playback.refreshTrackAnalysis(
        '2',
        _analysis(
          bpm: 125,
          downbeatsMs: [0, 8000, 16000],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final clips = playback.timelineModel.clips;
      expect(clips[0].tempo.nativeBpm, 100);
      expect(clips[1].tempo.nativeBpm, 125);
      expect(clips[1].timelineStartMs, 12000);
      expect(
        playback.queue[0].extras?['analysisUpdatedAt'],
        '2026-07-10T11:00:00.123456Z',
      );
      expect(clips[0].playbackRateAt(12000), 1);
      expect(clips[1].playbackRateAt(12000), closeTo(0.8, 0.0001));
      expect(playback.currentIndex, 0);
      playback.dispose();
    });

    test('analysis refresh backfills beat-aware overlap for default queue',
        () async {
      SharedPreferences.setMockInitialValues({});
      final playback = _playbackState();

      await playback.playQueue([
        _track(1, seconds: 20),
        _track(2, seconds: 20),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(playback.timelineModel.clips[1].timelineStartMs, 20000);

      await playback.refreshTrackAnalysis(
        '1',
        _analysis(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      await playback.refreshTrackAnalysis(
        '2',
        _analysis(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final clips = playback.timelineModel.clips;
      expect(clips[0].tempo.nativeBpm, 120);
      expect(clips[1].tempo.nativeBpm, 120);
      expect(clips[1].timelineStartMs, 12000);
      expect(clips[0].playbackRateAt(12000), 1);
      expect(clips[1].playbackRateAt(12000), 1);
      playback.dispose();
    });

    test('analysis refresh preserves non-default timeline placement', () async {
      SharedPreferences.setMockInitialValues({});
      final playback = _playbackState();

      await playback.playQueue([
        _track(1, seconds: 20),
        _track(2, seconds: 20),
      ]);
      await playback.setQueueTimelineStartMs(
        1,
        23000,
        snapToDownbeat: false,
      );
      await Future<void>.delayed(Duration.zero);

      await playback.refreshTrackAnalysis(
        '1',
        _analysis(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      await playback.refreshTrackAnalysis(
        '2',
        _analysis(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(playback.timelineModel.clips[1].tempo.nativeBpm, 120);
      expect(playback.timelineModel.clips[1].timelineStartMs, 23000);
      playback.dispose();
    });
  });
}

PlaybackState _playbackState({
  SignedAudioUrlService? signedAudioUrlService,
  QueuePersistenceStore? persistence,
}) {
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
    persistence: persistence ?? QueuePersistenceStore(),
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

class _ControllableQueuePersistenceStore extends QueuePersistenceStore {
  final Completer<void> _loadStarted = Completer<void>();
  final Completer<QueueSnapshot> _loadResult = Completer<QueueSnapshot>();
  final List<QueueSnapshot> savedSnapshots = <QueueSnapshot>[];

  @override
  Future<QueueSnapshot> load() {
    if (!_loadStarted.isCompleted) _loadStarted.complete();
    return _loadResult.future;
  }

  Future<void> waitForLoad() => _loadStarted.future;

  void completeLoad(QueueSnapshot snapshot) => _loadResult.complete(snapshot);

  void failLoad(Object error) => _loadResult.completeError(error);

  @override
  Future<void> save(QueueSnapshot snapshot) async {
    savedSnapshots.add(snapshot);
  }
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

TrackAnalysis _analysis({
  required double bpm,
  required List<int> downbeatsMs,
  DateTime? updatedAt,
}) =>
    TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': bpm, 'confidence': 1.0},
        'beat_grid': {'bpm': bpm, 'confidence': 1.0},
        'downbeats': {'positions_ms': downbeatsMs},
      },
      updatedAt: updatedAt,
    );
