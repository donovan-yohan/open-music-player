import 'dart:async';
import 'package:open_music_player/core/auth/auth_state.dart' as auth;
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/models/mix_plan.dart';

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
import 'package:open_music_player/core/audio/playback_queue_projection.dart'
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

    test('only the current track is hard excluded at natural exhaustion',
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

      expect(source.calls.single.excludeTrackIds, {'3'});
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
      // Retained history is not a hard exclusion: small libraries can cycle.
      expect(source.calls[1].excludeTrackIds, {'91'});
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
      expect(harness.playback.endOfQueueMode, EndOfQueueMode.shuffleLibrary);
      harness.playback.setEndOfQueueMode(EndOfQueueMode.off);

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

  test('manual enqueue while fetching wins over radio', () async {
    final gate = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
    final h = _Harness(continuationSource: gate);
    h.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    await h.playback.enqueue(_track(2, seconds: 5));
    gate.release();
    await pumpEventQueue();
    expect(h.playback.currentItem?.id, '2');
    expect(h.playback.isPlaying, isTrue);
    await h.dispose();
  });

  for (final action in ['off', 'pause', 'seek']) {
    test('$action cancels pending continuation', () async {
      final gate = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
      final h = _Harness(continuationSource: gate);
      h.playback.setEndOfQueueMode(EndOfQueueMode.shuffleLibrary);
      await h.playback.playQueue([_track(1, seconds: 5)]);
      await h.playToEndOfQueue();
      if (action == 'off') h.playback.setEndOfQueueMode(EndOfQueueMode.off);
      if (action == 'pause') await h.playback.pause();
      if (action == 'seek') await h.playback.seek(Duration.zero);
      gate.release();
      await pumpEventQueue();
      expect(h.playback.queue, hasLength(1));
      expect(h.playback.isPlaying, isFalse);
      await h.dispose();
    });
  }

  test('two-track library alternates through multiple cycles, single stops',
      () async {
    final h = _Harness(continuationSource: _LibrarySource([1, 2]));
    await h.playback.playQueue([_track(1, seconds: 5)]);
    for (final expected in ['2', '1', '2', '1', '2']) {
      await h.playToEndOfQueue();
      expect(h.playback.currentItem?.id, expected);
      expect(h.playback.isPlaying, isTrue);
    }
    await h.dispose();
    final single = _Harness(continuationSource: _LibrarySource([1]));
    await single.playback.playQueue([_track(1, seconds: 5)]);
    await single.playToEndOfQueue();
    expect(single.playback.queue, hasLength(1));
    expect(single.playback.isPlaying, isFalse);
    await single.dispose();
  });

  test('old hung attempt cannot block a replacement or clear its attempt',
      () async {
    final source = _MultiGateSource();
    final h = _Harness(continuationSource: source);
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    await h.playback.playQueue([_track(2, seconds: 5)]);
    await h.playToEndOfQueue();
    expect(source.gates, hasLength(2));
    source.gates[0].complete([_track(90, seconds: 5)]);
    await pumpEventQueue();
    expect(h.playback.queue.map((i) => i.id), ['2']);
    source.gates[1].complete([_track(91, seconds: 5)]);
    await pumpEventQueue();
    expect(h.playback.currentItem?.id, '91');
    await h.dispose();
  });

  test('timeout stops once without retrying, later playback re-arms', () async {
    final source = _MultiGateSource();
    final h = _Harness(
        continuationSource: source,
        continuationTimeout: const Duration(milliseconds: 20));
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    h.tick();
    await pumpEventQueue();
    expect(source.gates, hasLength(1));
    expect(h.playback.isPlaying, isFalse);
    await h.playback.play();
    await h.playToEndOfQueue();
    expect(source.gates, hasLength(2));
    await h.dispose();
    for (final gate in source.gates) {
      gate.complete([]);
    }
  });

  test('disposed attempt cannot append or play', () async {
    final source = _MultiGateSource();
    final h = _Harness(continuationSource: source);
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    await h.dispose();
    source.gates.single.complete([_track(90, seconds: 5)]);
    await pumpEventQueue();
  });

  test('fixed mix is finite and eligibility survives serialization and edits',
      () async {
    final source = _LibrarySource([1, 2]);
    final h = _Harness(continuationSource: source);
    final plan = MixPlan.fromJson({
      'id': 'finite',
      'version': 1,
      'schemaVersion': 1,
      'name': 'Finite',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'summary': {
        'clipCount': 1,
        'trackIds': ['1'],
        'durationMs': 5000
      },
      'clips': [
        {
          'clipId': 'clip',
          'queueItemId': 'q1',
          'trackId': '1',
          'timelineStartMs': 0,
          'sourceStartMs': 0,
          'sourceEndMs': 5000
        }
      ]
    });
    await h.playback.playMixPlan([_track(1, seconds: 5)], plan);
    await h.playToEndOfQueue();
    expect(source.calls, 0);
    expect(h.playback.isPlaying, isFalse);
    final session = MixSession.fromMixPlan(plan: plan, queue: h.playback.queue);
    expect(MixSession.fromJson(session.toJson()).continuationAllowed, isFalse);
    expect(session.insertAt(1, h.playback.queue.first).continuationAllowed,
        isFalse);
    final legacy = session.toJson()..remove('continuationAllowed');
    expect(MixSession.fromJson(legacy).continuationAllowed, isFalse);
    await h.dispose();
  });

  test('shuffled manual enqueue outranks retained history and radio', () async {
    final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
    final h = _Harness(continuationSource: source);
    await h.playback
        .playQueue([for (var id = 1; id <= 5; id++) _track(id, seconds: 5)]);
    await h.playback.setShuffleEnabled(true);
    var last = h.playback.currentIndex!;
    while (h.playback.nextQueueIndexInPlayOrder(last) != null) {
      last = h.playback.nextQueueIndexInPlayOrder(last)!;
    }
    await h.playback.skipToIndex(last);
    await pumpEventQueue();
    await h.playToEndOfQueue();
    expect(source.pending, isTrue);
    await h.playback.enqueue(_track(50, seconds: 5));
    source.release();
    await pumpEventQueue();
    expect(h.playback.currentItem?.id, '50');
    await h.dispose();
  });

  test('fixed plan restores through the real store paused and finite',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = QueuePersistenceStore();
    final items = [_mediaItem('1')];
    final json =
        MixSession.fromQueue(sessionId: 'mix_plan_saved_v1', queue: items)
            .toJson()
          ..remove('continuationAllowed');
    await store.save(QueueSnapshot(
        tracks: [_track(1, seconds: 5)], session: MixSession.fromJson(json)));
    final source = _LibrarySource([1, 2]);
    final h = _Harness(continuationSource: source, persistence: store);
    await h.playback.restore();
    expect(h.playback.isPlaying, isFalse);
    expect(h.playback.queue, hasLength(1));
    await h.playback.play();
    await h.playToEndOfQueue();
    expect(source.calls, 0);
    expect(h.playback.isPlaying, isFalse);
    await h.dispose();
  });

  for (final boundary in ['load', 'play']) {
    test('Off during real controller $boundary await cannot resurrect',
        () async {
      final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
      final h = _Harness(continuationSource: source);
      await h.playback.playQueue([_track(1, seconds: 5)]);
      await h.playToEndOfQueue();
      h.engine.arm(boundary);
      source.release();
      await h.engine.entered.future.timeout(const Duration(seconds: 2));
      h.playback.setEndOfQueueMode(EndOfQueueMode.off);
      h.engine.release.complete();
      await pumpEventQueue();
      expect(h.playback.isPlaying, isFalse);
      await h.dispose();
    });
  }

  test('repeated natural shuffled exhaustion keeps extending the play order',
      () async {
    final source = _LibrarySource([1, 2, 3, 4]);
    final h = _Harness(continuationSource: source);
    await h.playback.playQueue([_track(1, seconds: 5), _track(2, seconds: 5)]);
    await h.playback.setShuffleEnabled(true);
    await pumpEventQueue();
    for (var cycle = 0; cycle < 5; cycle++) {
      await h.playToEndOfQueue();
      expect(source.calls, cycle + 1);
      expect(h.playback.isPlaying, isTrue);
      expect(h.playback.snapshot.continuationDisposition,
          ContinuationDisposition.none);
    }
    await h.dispose();
  });

  for (final boundary in ['load', 'play']) {
    for (final action in [
      'off',
      'pause',
      'stop',
      'seek',
      'dispose',
      'replacement'
    ]) {
      test('$action during $boundary prevents clock and voice start dispatch',
          () async {
        final source =
            _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
        final h = _Harness(continuationSource: source);
        await h.playback.playQueue([_track(1, seconds: 5)]);
        await h.playToEndOfQueue();
        expect(h.playback.snapshot.continuationDisposition,
            ContinuationDisposition.waiting);
        h.engine.arm(boundary);
        source.release();
        await h.engine.entered.future;
        expect(h.playback.snapshot.continuationDisposition,
            ContinuationDisposition.waiting);
        final starts = <bool>[];
        final sub = h.clock.isPlayingStream.listen((v) {
          if (v) starts.add(v);
        });
        Future<void>? command;
        switch (action) {
          case 'off':
            h.playback.setEndOfQueueMode(EndOfQueueMode.off);
          case 'pause':
            command = h.playback.pause();
          case 'stop':
            command = h.playback.stop();
          case 'seek':
            command = h.playback.seek(Duration.zero);
          case 'dispose':
            h.playback.dispose();
          case 'replacement':
            command = h.playback.playTrack(_track(2, seconds: 5));
        }
        h.engine.release.complete();
        await command;
        await pumpEventQueue();
        if (action != 'replacement') {
          expect(starts, isEmpty,
              reason: 'no post-cancel transient clock start');
        }
        expect(h.voices.expand((v) => v.playedSources),
            isNot(contains('https://example.com/90.mp3')));
        if (action != 'dispose') {
          expect(h.playback.snapshot.continuationDisposition,
              ContinuationDisposition.none);
          await h.dispose();
        }
        await sub.cancel();
      });
    }
  }

  test('waiting resolves to completed on empty and error without retry',
      () async {
    for (final source in <QueueContinuationSource>[
      _RecordingContinuationSource(batches: [[]]),
      _ThrowingContinuationSource(),
    ]) {
      final h = _Harness(continuationSource: source);
      await h.playback.playQueue([_track(1, seconds: 5)]);
      await h.playToEndOfQueue();
      expect(h.playback.snapshot.continuationDisposition,
          ContinuationDisposition.completed);
      expect(h.playback.isPlaying, isFalse);
      await h.dispose();
    }
  });

  for (final boundary in ['load', 'play']) {
    test('A to B to A auth intent during $boundary invalidates old radio',
        () async {
      final service = _IntentAuthService();
      final authState = auth.AuthState(authService: service);
      final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
      final h = _Harness(
          continuationSource: source, accountIdProvider: () async => 'A');
      var revision = authState.sessionRevision;
      final stops = <Future<void>>[];
      authState.addListener(() {
        if (revision != authState.sessionRevision) {
          revision = authState.sessionRevision;
          stops.add(h.playback.stop());
        }
      });
      await h.playback.playQueue([_track(1, seconds: 5)]);
      await h.playToEndOfQueue();
      h.engine.arm(boundary);
      source.release();
      await h.engine.entered.future;
      final logout = authState.logout();
      expect(revision, 1, reason: 'before auth storage completes');
      final loginB = authState.login(email: 'B', password: 'test');
      final loginA = authState.login(email: 'A', password: 'test');
      expect(revision, 3);
      expect(stops, hasLength(3));
      h.engine.release.complete();
      await Future.wait(stops);
      await pumpEventQueue();
      expect(h.playback.isPlaying, isFalse);
      expect(h.voices.expand((v) => v.playedSources),
          isNot(contains('https://example.com/90.mp3')));
      service.release.complete();
      await Future.wait([logout, loginB, loginA]);
      authState.dispose();
      await h.dispose();
    });
  }

  test('auth intent cancels a radio commit queued behind a manual model load',
      () async {
    final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
    final h = _Harness(
        continuationSource: source, accountIdProvider: () async => 'A');
    final service = _IntentAuthService();
    final authState = auth.AuthState(authService: service);
    var revision = authState.sessionRevision;
    Future<void>? stopped;
    authState.addListener(() {
      if (revision != authState.sessionRevision) {
        revision = authState.sessionRevision;
        stopped = h.playback.stop();
      }
    });
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    h.engine.arm('load');
    final manual = h.playback.enqueue(_track(2, seconds: 5));
    await h.engine.entered.future;
    source.release();
    await pumpEventQueue(); // fetched + signed; commit is queued behind manual load
    final logout = authState.logout();
    expect(revision, 1);
    h.engine.release.complete();
    await manual;
    await stopped;
    await pumpEventQueue();
    expect(h.playback.queue.map((i) => i.id), ['1', '2']);
    expect(h.playback.isPlaying, isFalse);
    service.release.complete();
    await logout;
    authState.dispose();
    await h.dispose();
  });

  for (final action in [
    'off',
    'pause',
    'stop',
    'seek',
    'dispose',
    'replacement'
  ]) {
    test('$action during signing abandons the radio commit', () async {
      final gate = Completer<void>();
      final h = _Harness(
        signingGate: gate,
        continuationSource: _RecordingContinuationSource(batches: [
          [_track(90, seconds: 5)]
        ]),
      );
      await h.playback.playQueue([_track(1, seconds: 5)]);
      await h.playToEndOfQueue();
      expect(h.playback.snapshot.continuationDisposition,
          ContinuationDisposition.waiting);
      switch (action) {
        case 'off':
          h.playback.setEndOfQueueMode(EndOfQueueMode.off);
        case 'pause':
          await h.playback.pause();
        case 'stop':
          await h.playback.stop();
        case 'seek':
          await h.playback.seek(Duration.zero);
        case 'dispose':
          h.playback.dispose();
        case 'replacement':
          await h.playback.playTrack(_track(2, seconds: 5));
      }
      gate.complete();
      await pumpEventQueue();
      expect(h.voices.expand((v) => v.playedSources),
          isNot(contains('https://example.com/90.mp3')));
      if (action != 'dispose') {
        expect(h.playback.queue.map((i) => i.id), isNot(contains('90')));
        expect(h.playback.snapshot.continuationDisposition,
            ContinuationDisposition.none);
        await h.dispose();
      }
    });
  }

  test('facade notifies disposition-only cancellation for snapshot selectors',
      () async {
    final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
    final h = _Harness(continuationSource: source);
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    final observed = <ContinuationDisposition>[];
    h.playback.addListener(
        () => observed.add(h.playback.snapshot.continuationDisposition));
    h.playback.setEndOfQueueMode(EndOfQueueMode.off);
    await pumpEventQueue();
    expect(observed, contains(ContinuationDisposition.none));
    source.release();
    await pumpEventQueue();
    await h.dispose();
  });

  test('account switch while library fetch waits cannot play old results',
      () async {
    var account = 'A';
    final source = _GatedContinuationSource(batch: [_track(90, seconds: 5)]);
    final h = _Harness(
        continuationSource: source, accountIdProvider: () async => account);
    await h.playback.playQueue([_track(1, seconds: 5)]);
    await h.playToEndOfQueue();
    account = 'B';
    source.release();
    await pumpEventQueue();
    expect(h.playback.queue.map((i) => i.id), ['1']);
    expect(h.playback.isPlaying, isFalse);
    await h.dispose();
  });

  test('serialized commit rechecks cancellation after an earlier command',
      () async {
    var now = DateTime.utc(2026);
    final clock = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final engine = _GatedEngine(clock);
    final c = QueueTimelineController(engine);
    await c.setQueue([_mediaItem('1')]);
    final eventFuture = c.queueExhaustedStream.first;
    await c.play();
    now = now.add(const Duration(minutes: 1));
    clock.tickForTest();
    final event = await eventFuture;
    engine.arm('load');
    final insert = c.appendToQueue([_mediaItem('2')]);
    await engine.entered.future;
    final continuation = c.continueExhaustedQueue(event, [_mediaItem('90')],
        stillCurrent: () => true);
    c.cancelContinuation();
    engine.release.complete();
    await insert;
    await continuation;
    expect(c.queue.map((i) => i.id), ['1', '2']);
    expect(c.snapshot.playing, isFalse);
    await c.dispose();
    await clock.dispose();
  });

  test(
      'stale delivered exhaustion cannot attach to replacement controller session',
      () async {
    var now = DateTime.utc(2026);
    final clock = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final c = QueueTimelineController(_GatedEngine(clock));
    await c.setQueue([_mediaItem('1')]);
    final eventFuture = c.queueExhaustedStream.first;
    await c.play();
    now = now.add(const Duration(minutes: 1));
    clock.tickForTest();
    final event = await eventFuture;
    await c.setQueue([_mediaItem('2')]);
    await c.continueExhaustedQueue(event, [_mediaItem('90')],
        stillCurrent: () => true);
    expect(c.queue.map((i) => i.id), ['2']);
    expect(c.snapshot.playing, isFalse);
    await c.dispose();
    await clock.dispose();
  });

  test('preview exhaustion stays finite then restores ordinary eligibility',
      () async {
    final source = _LibrarySource([1, 2, 3]);
    final h = _Harness(continuationSource: source);
    await h.playback.playQueue([_track(3, seconds: 5)]);
    final plan = MixPlan.fromJson({
      'id': 'preview',
      'version': 1,
      'schemaVersion': 1,
      'name': 'Preview',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'summary': {
        'clipCount': 2,
        'trackIds': ['1', '2'],
        'durationMs': 10000
      },
      'clips': [
        for (var i = 0; i < 2; i++)
          {
            'clipId': 'c$i',
            'queueItemId': 'q$i',
            'trackId': '${i + 1}',
            'timelineStartMs': i * 5000,
            'sourceStartMs': 0,
            'sourceEndMs': 5000,
          }
      ],
    });
    await h.playback.previewMixSeam(
        [_track(1, seconds: 5), _track(2, seconds: 5)], plan,
        seamIndex: 0);
    await h.playToEndOfQueue();
    expect(source.calls, 0);
    await h.playback.endMixSeamPreview();
    await h.playToEndOfQueue();
    expect(source.calls, 1);
    await h.dispose();
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
  _Harness(
      {QueueContinuationSource? continuationSource,
      QueuePersistenceStore? persistence,
      Future<String?> Function()? accountIdProvider,
      Completer<void>? signingGate,
      Duration continuationTimeout = const Duration(seconds: 15)}) {
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = _GatedEngine(clock, voices: voices);
    playback = PlaybackState(
      engine,
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
        final ids = (body['trackIds'] as List).cast<int>();
        if (ids.contains(90)) await signingGate?.future;
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
      persistence: persistence,
      accountIdProvider: accountIdProvider,
      continuationBatchSize: 2,
      continuationTimeout: continuationTimeout,
      persistenceDebounce: Duration.zero,
    );
  }

  final voices = <_CountingVoice>[];
  late final DefaultTimelineClock clock;
  late final _GatedEngine engine;
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

// The real engine and controller run; only the async engine boundary is held.
class _GatedEngine extends PlaybackEngine {
  _GatedEngine(DefaultTimelineClock clock, {List<_CountingVoice>? voices})
      : super.withClock(
            clock: clock,
            voiceFactory: () {
              final voice = _CountingVoice();
              voices?.add(voice);
              return voice;
            });
  String? boundary;
  late Completer<void> entered;
  late Completer<void> release;
  void arm(String value) {
    boundary = value;
    entered = Completer<void>();
    release = Completer<void>();
  }

  Future<void> wait(String value) async {
    if (boundary != value) return;
    boundary = null;
    entered.complete();
    await release.future;
  }

  @override
  Future<void> loadMix(TimelineModel model,
      {bool preserveActivePlayback = false}) async {
    await wait('load');
    await super.loadMix(model, preserveActivePlayback: preserveActivePlayback);
  }

  @override
  Future<void> playGuarded({required bool Function() stillCurrent}) async {
    await wait('play');
    await super.playGuarded(stillCurrent: stillCurrent);
  }
}

class _IntentAuthService extends AuthService {
  _IntentAuthService()
      : super(
            api: ApiClient(storage: SecureStorage()), storage: SecureStorage());
  final release = Completer<void>();
  @override
  Future<void> logout() => release.future;
  @override
  Future<AuthResult> login(
      {required String email, required String password}) async {
    await release.future;
    return const AuthResult.success();
  }

  @override
  Future<bool> isBiometricUnlockAvailable() async => false;
  @override
  Future<bool> isBiometricUnlockEnabled() async => false;
}

class _CountingVoice extends FakeVoice {
  _CountingVoice() : super('counting');
  final playedSources = <String>[];
  @override
  Future<void> play() async {
    playedSources.add(loads.last.toString());
    await super.play();
  }
}

class _LibrarySource implements QueueContinuationSource {
  _LibrarySource(this.ids);
  final List<int> ids;
  int calls = 0;
  @override
  Future<List<Map<String, dynamic>>> fetch(
      {required Set<String> excludeTrackIds,
      required int limit,
      List<String> recentTrackIds = const []}) async {
    calls++;
    return [
      for (final id
          in ids.where((id) => !excludeTrackIds.contains('$id')).take(limit))
        _track(id, seconds: 5)
    ];
  }
}

class _MultiGateSource implements QueueContinuationSource {
  final gates = <Completer<List<Map<String, dynamic>>>>[];
  @override
  Future<List<Map<String, dynamic>>> fetch(
      {required Set<String> excludeTrackIds,
      required int limit,
      List<String> recentTrackIds = const []}) {
    final gate = Completer<List<Map<String, dynamic>>>();
    gates.add(gate);
    return gate.future;
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
    List<String> recentTrackIds = const [],
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
    List<String> recentTrackIds = const [],
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
    List<String> recentTrackIds = const [],
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
    List<String> recentTrackIds = const [],
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
      extras: {'url': 'https://example.com/$id.mp3'},
      duration: const Duration(seconds: 5),
    );
