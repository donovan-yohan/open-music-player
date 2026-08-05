import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
import 'package:open_music_player/core/audio/playback_state.dart' as app_audio;
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';

import 'support/fake_voice.dart';

void main() {
  group('MixAudioHandler notification mapping', () {
    test(
      'snapshot-backed notification uses source-relative position, duration, queue, and index',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final queues = <List<audio_service.MediaItem>>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        final queueSub = handler.queue.listen(queues.add);
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 5000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '2');
        expect(mediaItems.last?.duration, const Duration(seconds: 5));
        expect(states.last.updatePosition, Duration.zero);
        expect(states.last.queueIndex, 1);
        expect(queues.last.map((item) => item.id), ['1', '2']);

        await stateSub.cancel();
        await mediaSub.cancel();
        await queueSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification seek play and pause use the playback queue path',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await handler.seek(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 7000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, const Duration(seconds: 2));
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, const Duration(seconds: 2));
        expect(states.last.queueIndex, 1);

        await handler.pause();
        await Future<void>.delayed(Duration.zero);
        expect(harness.playback.isPlaying, isFalse);
        expect(states.last.playing, isFalse);

        await handler.play();
        await Future<void>.delayed(Duration.zero);
        expect(harness.playback.isPlaying, isTrue);
        expect(states.last.playing, isTrue);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification speed follows tempo automation during BPM-matched overlap',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 10, analysisSummary: _bpmAnalysis(100)),
          _track(2, seconds: 10, analysisSummary: _bpmAnalysis(125)),
        ]);
        await harness.playback.setQueueTimelineStartMs(
          1,
          5000,
          snapToDownbeat: false,
        );
        await harness.engine.seek(7500);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final stateSub = handler.playbackState.listen(states.add);
        await Future<void>.delayed(Duration.zero);
        final incoming = harness.engine.model.clips[1];
        final expectedSpeed = incoming.playbackRateAt(7500);
        final expectedPosition =
            incoming.sourcePositionAt(7500) - incoming.placement.sourceStartMs;

        expect(harness.playback.currentItem?.id, '2');
        expect(
          harness.playback.snapshot.playbackSpeed,
          closeTo(expectedSpeed, 0.0001),
        );
        expect(states.last.speed, closeTo(expectedSpeed, 0.0001));
        expect(
          states.last.updatePosition.inMilliseconds,
          closeTo(expectedPosition, 1),
        );
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification extras expose pitch preservation fallback',
      () async {
        final harness = _PlaybackHarness(pitchSupported: false);
        await harness.playback.playQueue([
          _track(1, seconds: 10, analysisSummary: _bpmAnalysis(100)),
          _track(2, seconds: 10, analysisSummary: _bpmAnalysis(125)),
        ]);
        await harness.playback.setQueueTimelineStartMs(
          1,
          5000,
          snapToDownbeat: false,
        );
        await harness.engine.seek(7500);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final mediaItems = <audio_service.MediaItem?>[];
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.snapshot.pitchPreservationFallback, isTrue);
        expect(harness.playback.snapshot.pitchFallbackClipIds, isNotEmpty);
        expect(
          harness.playback.snapshot.pitchFallbackClipIds,
          everyElement(allOf(startsWith('session_'), contains('_clip_'))),
        );
        expect(mediaItems.last?.extras?['pitchPreservation'], 'fallback');
        expect(mediaItems.last?.extras?['pitchLockUnavailable'], isTrue);

        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification skipToNext gives immediate app and media-session feedback',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ]);
        await handler.skipToNext();
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 5000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '2');
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification previous and stop keep app and media-session state aligned',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        await handler.skipToPrevious();
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 0);
        expect(harness.playback.currentItem?.id, '1');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '1');
        expect(states.last.queueIndex, 0);

        await handler.stop();
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.isPlaying, isFalse);
        expect(states.last.playing, isFalse);
        expect(
          states.last.processingState,
          audio_service.AudioProcessingState.idle,
        );

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'queue transition keeps app and notification metadata aligned with audio',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ]);
        harness.advance(const Duration(seconds: 6));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, const Duration(seconds: 1));
        expect(harness.engine.model.dominantClipAt(6000)?.trackId, '2');
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, const Duration(seconds: 1));
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'direct play replacement creates a new session and drops old notification state',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playTrack(_track(1, seconds: 5));
        final firstSession = harness.playback.snapshot.sessionId;
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playTrack(_track(2, seconds: 7));
        await Future<void>.delayed(Duration.zero);

        final snapshot = harness.playback.snapshot;
        expect(snapshot.sessionId, isNot(firstSession));
        expect(snapshot.currentMediaItem?.id, '2');
        expect(snapshot.currentQueueIndex, 0);
        expect(snapshot.localPosition, Duration.zero);
        expect(snapshot.localDuration, const Duration(seconds: 7));
        expect(snapshot.globalPosition, Duration.zero);
        expect(snapshot.cues.single.cueId, '${snapshot.sessionId}_clip_0');
        expect(harness.engine.model.clips.single.trackId, '2');
        expect(harness.engine.model.clips.single.id,
            '${snapshot.sessionId}_clip_0');
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, Duration.zero);
        expect(states.last.queueIndex, 0);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );
  });

  group('MixAudioHandler OS command routing', () {
    test('shuffle mode commands set the queue mode and report it back',
        () async {
      final harness = _PlaybackHarness();
      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
        _track(3, seconds: 5),
      ]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      expect(
          states.last.shuffleMode, audio_service.AudioServiceShuffleMode.none);

      await handler.setShuffleMode(audio_service.AudioServiceShuffleMode.all);
      await Future<void>.delayed(Duration.zero);

      expect(harness.playback.shuffleEnabled, isTrue);
      expect(
        states.last.shuffleMode,
        audio_service.AudioServiceShuffleMode.all,
      );

      // Absolute, not a toggle: repeating the same command is a no-op.
      await handler.setShuffleMode(audio_service.AudioServiceShuffleMode.all);
      await Future<void>.delayed(Duration.zero);
      expect(harness.playback.shuffleEnabled, isTrue);

      await handler.setShuffleMode(audio_service.AudioServiceShuffleMode.none);
      await Future<void>.delayed(Duration.zero);

      expect(harness.playback.shuffleEnabled, isFalse);
      expect(
        states.last.shuffleMode,
        audio_service.AudioServiceShuffleMode.none,
      );

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('repeat mode commands map onto the queue loop mode', () async {
      final harness = _PlaybackHarness();
      await harness.playback.playQueue([_track(1, seconds: 5)]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);

      const expected = {
        audio_service.AudioServiceRepeatMode.one: LoopMode.one,
        audio_service.AudioServiceRepeatMode.all: LoopMode.all,
        audio_service.AudioServiceRepeatMode.group: LoopMode.all,
        audio_service.AudioServiceRepeatMode.none: LoopMode.off,
      };
      for (final entry in expected.entries) {
        await handler.setRepeatMode(entry.key);
        await Future<void>.delayed(Duration.zero);
        expect(harness.playback.loopMode, entry.value, reason: '${entry.key}');
      }

      // `group` has no queue equivalent and reports back as `all`.
      expect(states.last.repeatMode, audio_service.AudioServiceRepeatMode.none);
      await handler.setRepeatMode(audio_service.AudioServiceRepeatMode.group);
      await Future<void>.delayed(Duration.zero);
      expect(states.last.repeatMode, audio_service.AudioServiceRepeatMode.all);

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('in-app shuffle and repeat toggles reach the media session', () async {
      final harness = _PlaybackHarness();
      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
      ]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      await harness.playback.toggleShuffle();
      await harness.playback.cycleLoopMode();
      await Future<void>.delayed(Duration.zero);

      expect(
        states.last.shuffleMode,
        audio_service.AudioServiceShuffleMode.all,
      );
      expect(states.last.repeatMode, audio_service.AudioServiceRepeatMode.all);

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('the published state advertises the new OS capabilities', () async {
      final harness = _PlaybackHarness();
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      expect(
        states.last.systemActions,
        containsAll(<audio_service.MediaAction>[
          audio_service.MediaAction.setShuffleMode,
          audio_service.MediaAction.setRepeatMode,
          audio_service.MediaAction.skipToQueueItem,
        ]),
      );
      // Transport stays in the three compact notification slots.
      expect(states.last.androidCompactActionIndices, [0, 1, 2]);
      expect(
        states.last.controls.take(3).map((control) => control.action),
        [
          audio_service.MediaAction.skipToPrevious,
          audio_service.MediaAction.play,
          audio_service.MediaAction.skipToNext,
        ],
      );

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('skipToQueueItem maps a queue position onto its occurrence', () async {
      final harness = _PlaybackHarness();
      // The same track twice: position, not track id, has to disambiguate.
      await harness.playback.playQueue([
        _track(1, seconds: 5),
        _track(2, seconds: 5),
        _track(1, seconds: 5),
      ]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      final queueItemIds = [
        for (final cue in harness.playback.snapshot.cues) cue.queueItemId,
      ];
      expect(queueItemIds.toSet(), hasLength(3));

      await handler.skipToQueueItem(2);
      await Future<void>.delayed(Duration.zero);

      expect(harness.playback.currentIndex, 2);
      expect(harness.playback.currentItem?.id, '1');
      expect(harness.playback.snapshot.currentQueueIndex, 2);
      expect(states.last.queueIndex, 2);

      await handler.skipToQueueItem(0);
      await Future<void>.delayed(Duration.zero);
      expect(harness.playback.currentIndex, 0);

      // Out-of-range positions are ignored rather than throwing at the OS.
      await handler.skipToQueueItem(9);
      await handler.skipToQueueItem(-1);
      await Future<void>.delayed(Duration.zero);
      expect(harness.playback.currentIndex, 0);

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test(
      'a queue rebuilt between publish and tap makes the stale position a '
      'no-op',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
          _track(3, seconds: 5),
        ]);
        final publishedSessionId = harness.playback.snapshot.sessionId;

        MixAudioHandler? handler;
        List<String>? publishedQueueAtTap;
        bool? consumedTransportCommand;
        Future<void>? staleTap;
        // Subscribed ahead of the handler, so it runs while the handler still
        // mirrors the queue the OS was shown: exactly the window in which an
        // already-dispatched queue tap lands on a rebuilt queue.
        final probe = harness.playback.snapshotStream.listen((snapshot) {
          final live = handler;
          if (staleTap != null || live == null) return;
          if (snapshot.sessionId == publishedSessionId) return;
          publishedQueueAtTap = [
            for (final item in live.queue.value) item.id,
          ];
          final generationBefore = harness.playback.transportCommandGeneration;
          staleTap = live.skipToQueueItem(2);
          consumedTransportCommand =
              harness.playback.transportCommandGeneration != generationBefore;
        });

        handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        await Future<void>.delayed(Duration.zero);

        await harness.playback.playQueue([
          _track(4, seconds: 5),
          _track(5, seconds: 5),
        ]);
        await staleTap;
        await Future<void>.delayed(Duration.zero);

        // The race really happened: the tap was resolved against the published
        // three-item queue, so position 2 was in range and named an occurrence
        // that no longer exists.
        expect(publishedQueueAtTap, ['1', '2', '3']);
        expect(
          consumedTransportCommand,
          isFalse,
          reason: 'a dead queue position must not pre-empt live transport '
              'commands',
        );
        expect(harness.playback.queue.map((item) => item.id), ['4', '5']);
        expect(harness.playback.currentIndex, 0);
        expect(harness.playback.currentItem?.id, '4');

        await probe.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test('the like custom action toggles the current track liked state',
        () async {
      final harness = _PlaybackHarness();
      final library = _RecordingLibraryService();
      final likedTracks = LikedTracksState(library);
      await harness.playback.playQueue([
        _track(1, seconds: 5, isLiked: false),
        _track(2, seconds: 5, isLiked: true),
      ]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        likedTracksState: likedTracks,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      final likeControl = _likeControl(states.last);
      expect(likeControl, isNotNull);
      expect(likeControl!.label, 'Like');
      // The heart is an extra beyond the three compact transport slots.
      expect(states.last.controls.indexOf(likeControl), greaterThan(2));

      await handler.customAction(likeCustomActionName);
      await Future<void>.delayed(Duration.zero);

      expect(likedTracks.isLiked(1), isTrue);
      expect(library.liked, [1]);
      expect(_likeControl(states.last)?.label, 'Unlike');

      await handler.customAction(likeCustomActionName);
      await Future<void>.delayed(Duration.zero);

      expect(likedTracks.isLiked(1), isFalse);
      expect(library.unliked, [1]);
      expect(_likeControl(states.last)?.label, 'Like');

      // A like made inside the app repaints the notification heart too.
      likedTracks.seedValue(2, true);
      await handler.skipToNext();
      await Future<void>.delayed(Duration.zero);
      expect(_likeControl(states.last)?.label, 'Unlike');

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('an unknown liked state offers no heart and never guesses', () async {
      final harness = _PlaybackHarness();
      final library = _RecordingLibraryService();
      final likedTracks = LikedTracksState(library);
      // No `isLiked` payload: the app has not resolved this track's like state.
      await harness.playback.playQueue([_track(1, seconds: 5)]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        likedTracksState: likedTracks,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      expect(_likeControl(states.last), isNull);

      await handler.customAction(likeCustomActionName);
      await Future<void>.delayed(Duration.zero);

      expect(likedTracks.isLiked(1), isNull);
      expect(library.liked, isEmpty);
      expect(library.unliked, isEmpty);

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test(
        'a failed like write leaves the reported heart on the rolled-back '
        'value', () async {
      final harness = _PlaybackHarness();
      final library = _RecordingLibraryService()
        ..failure = StateError('offline');
      final likedTracks = LikedTracksState(library);
      await harness.playback.playQueue([_track(1, seconds: 5, isLiked: false)]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        likedTracksState: likedTracks,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      await handler.customAction(likeCustomActionName);
      await Future<void>.delayed(Duration.zero);

      expect(likedTracks.isLiked(1), isFalse);
      expect(_likeControl(states.last)?.label, 'Like');

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('disposing twice releases the liked listener exactly once', () async {
      final harness = _PlaybackHarness();
      final library = _RecordingLibraryService();
      final likedTracks = LikedTracksState(library);
      await harness.playback.playQueue([_track(1, seconds: 5, isLiked: false)]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        likedTracksState: likedTracks,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      // Liked changes reach the notification while the handler is live.
      likedTracks.seedValue(1, true);
      await Future<void>.delayed(Duration.zero);
      expect(_likeControl(states.last)?.label, 'Unlike');

      await handler.dispose();
      // A second teardown must be a no-op, not a throw and not a re-subscribe.
      await handler.dispose();
      final publishedByDispose = states.length;

      // App-side changes no longer reach the notification once the listeners
      // are released...
      likedTracks.seedValue(1, false);
      await harness.playback.playQueue([_track(2, seconds: 5, isLiked: true)]);
      await Future<void>.delayed(Duration.zero);

      // ...and neither do OS commands that were already in flight when the
      // handler was torn down, which push state directly rather than through a
      // subscription.
      await handler.setRepeatMode(audio_service.AudioServiceRepeatMode.all);
      await handler.setShuffleMode(audio_service.AudioServiceShuffleMode.all);
      await handler.seek(const Duration(seconds: 1));
      handler.updateDuration();
      await Future<void>.delayed(Duration.zero);

      expect(
        states.length,
        publishedByDispose,
        reason: 'a disposed handler must publish nothing, from app state or '
            'from a late OS command',
      );

      await stateSub.cancel();
      await harness.dispose();
    });

    test('a handler without liked state publishes transport only', () async {
      final harness = _PlaybackHarness();
      await harness.playback.playQueue([_track(1, seconds: 5, isLiked: false)]);
      final handler = MixAudioHandler(
        playbackState: harness.playback,
        statePushThrottle: Duration.zero,
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final stateSub = handler.playbackState.listen(states.add);
      await Future<void>.delayed(Duration.zero);

      expect(_likeControl(states.last), isNull);
      expect(
        () => handler.customAction(likeCustomActionName),
        returnsNormally,
      );

      await stateSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });
  });
}

audio_service.MediaControl? _likeControl(audio_service.PlaybackState state) {
  for (final control in state.controls) {
    if (control.customAction?.name == likeCustomActionName) return control;
  }
  return null;
}

class _RecordingLibraryService extends LibraryService {
  _RecordingLibraryService() : super(ApiClient());

  /// Raised on the next write when set, built at call time so the test never
  /// creates an unawaited error future.
  Object? failure;
  final List<int> liked = [];
  final List<int> unliked = [];

  @override
  Future<void> like(int trackId) async {
    liked.add(trackId);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> unlike(int trackId) async {
    unliked.add(trackId);
    if (failure != null) throw failure!;
  }
}

Map<String, dynamic> _track(
  int id, {
  required int seconds,
  Map<String, dynamic>? analysisSummary,
  bool? isLiked,
}) =>
    {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
      if (analysisSummary != null) 'analysisSummary': analysisSummary,
      if (isLiked != null) 'isLiked': isLiked,
    };

Map<String, dynamic> _bpmAnalysis(double bpm) => {
      'bpm': {'value': bpm, 'confidence': 0.95},
    };

class _PlaybackHarness {
  _PlaybackHarness({bool pitchSupported = true}) {
    var voiceIndex = 0;
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice(
        'v${voiceIndex++}',
        pitchSupported: pitchSupported,
      ),
    );
    playback = app_audio.PlaybackState(
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
    );
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final app_audio.PlaybackState playback;
  DateTime now = DateTime.utc(2026);

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }

  Future<void> dispose() async {
    playback.dispose();
    await clock.dispose();
  }
}
