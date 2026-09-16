import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_queue_projection.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/dj_analysis_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';
import '../../support/mock_dio_client.dart';
import '../../support/playback_fixtures.dart';

/// ADR 0012 step 3, the live bug this step exists to fix.
///
/// The deck used to seed from `QueueProvider.currentTrack` / `upNext`, which
/// read the *import* queue's `currentPosition`. The backend never advances that
/// field (`backend/internal/queue/queue.go` only nudges it to survive
/// insert/remove/reorder), so the import queue's head is not what is playing.
///
/// The characterization below is the user-visible failure: play an album with
/// an empty import queue and the deck must load the track that is actually
/// playing. On HEAD this fails — the deck seeds nothing at all.
void main() {
  testWidgets(
      'album playing + empty import queue: deck A is the playing track',
      (tester) async {
    landscapeReference.apply(tester);
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    // An import queue that is genuinely empty: no download jobs at all.
    final queue = QueueProvider(EmptyQueueApiClient());
    addTearDown(queue.dispose);

    await tester.runAsync(() => playAlbum(playback, [7001, 7002], startIndex: 1));
    await tester.pump();

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Preconditions: nothing is in the import queue, and the album IS playing.
    expect(queue.queue.tracks, isEmpty);
    expect(playback.currentItem, isNotNull);
    expect(playback.currentItem!.id, '7002',
        reason: 'the album is playing from index 1');

    expect(
      session.deckA.isLoaded,
      isTrue,
      reason: 'an empty import queue made the deck seed nothing (#453)',
    );
    expect(session.deckA.trackRef, '7002');

    await djRetireSession(tester, session, queue: queue);
  });

  testWidgets('deck B is the next track in play order, not the import queue',
      (tester) async {
    landscapeReference.apply(tester);
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    final queue = QueueProvider(EmptyQueueApiClient());
    addTearDown(queue.dispose);

    await tester.runAsync(() => playAlbum(playback, [7101, 7102, 7103]));
    await tester.pump();

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(session.deckA.trackRef, '7101');
    expect(session.deckB.trackRef, '7102',
        reason: 'deck B must come from the playback queue, in play order');

    await djRetireSession(tester, session, queue: queue);
  });

  testWidgets('deck B follows play order under shuffle', (tester) async {
    landscapeReference.apply(tester);
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    final queue = QueueProvider(EmptyQueueApiClient());
    addTearDown(queue.dispose);

    await tester.runAsync(() => playAlbum(playback, [7201, 7202, 7203, 7204]));
    await tester.runAsync(playback.toggleShuffle);
    await tester.pump();

    final snapshot = playback.snapshot;
    final currentIndex = snapshot.currentQueueIndex!;
    // Read the play-order successor through the step-1 seam that already exists
    // on HEAD, so this test's RED is the deck assertion below rather than a
    // compile error against a method introduced by the fix.
    final nextIndex = playback.nextQueueIndexInPlayOrder(currentIndex);
    final expectedNext = [
      for (final cue in snapshot.cues)
        if (cue.queueIndex == nextIndex)
          playbackTrackForMediaItem(cue.mediaItem, queueItemId: cue.queueItemId),
    ].single;
    expect(
      expectedNext.id,
      isNot((currentIndex + 1).toString()),
      reason: 'the fixture must discriminate: naive queue index + 1 is a '
          'different track than the play-order successor',
    );

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(session.deckB.trackRef, expectedNext.id,
        reason: 'deck B must be the play-order successor '
            '(PlaybackState.nextQueueIndexInPlayOrder), not queue index + 1');

    await djRetireSession(tester, session, queue: queue);
  });

  testWidgets('a deck never seeds from a stale import-queue head',
      (tester) async {
    landscapeReference.apply(tester);
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    // An import queue whose head is a *different* track from the one playing.
    // This is the ADR 0012 fiction made concrete: `currentPosition` stays at 0,
    // so the import queue presents item 1 as "the playing track".
    final queue = QueueProvider(
      _HeadPinnedQueueApiClient(const [9001, 9002]),
    );
    addTearDown(queue.dispose);
    await tester.runAsync(queue.loadQueue);
    await tester.pump();

    await tester.runAsync(() => playAlbum(playback, [9101, 9102, 9103]));
    await tester.pump();

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(queue.currentTrack?.playbackTrackId, '9001',
        reason: 'the import queue still reports its own head as current');
    expect(session.deckA.trackRef, '9101',
        reason: 'the deck must read playback truth, not the import queue head');
    expect(session.deckB.trackRef, '9102');

    await djRetireSession(tester, session, queue: queue);
  });

  testWidgets('the deck seed never issues an import-queue fetch', (tester) async {
    landscapeReference.apply(tester);
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    final api = _CountingQueueApiClient();
    final queue = QueueProvider(api);
    addTearDown(queue.dispose);

    await tester.runAsync(() => playAlbum(playback, [7301, 7302]));
    await tester.pump();

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // #453 drops the post-frame `await queue.loadQueue()`: the deck no longer
    // asks the import queue what is playing, so it must not fetch it either.
    expect(api.getQueueCalls, 0);
    expect(session.deckA.trackRef, '7301');

    await djRetireSession(tester, session, queue: queue);
  });
}

class _HeadPinnedQueueApiClient extends EmptyQueueApiClient {
  _HeadPinnedQueueApiClient(this.ids);
  final List<int> ids;

  @override
  Future<QueueState> getQueue() async => QueueState(
        tracks: [
          for (final id in ids)
            QueueTrack(
              id: '$id',
              queueItemId: 'import-$id',
              playbackTrackId: '$id',
              title: 'Import $id',
              duration: 200,
              addedAt: DateTime.utc(2026, 9, 1),
            ),
        ],
        currentIndex: 0,
      );
}

class _CountingQueueApiClient extends EmptyQueueApiClient {
  int getQueueCalls = 0;

  @override
  Future<QueueState> getQueue() async {
    getQueueCalls++;
    return QueueState.empty();
  }
}

DeckController _deck(DjDeckId deckId) => DeckController.empty(
      deckId: deckId,
      voice: CountingFakeVoice('dj-${deckId.name}'),
      resolver: const _LocalResolver(),
      slew: const Duration(milliseconds: 1),
    );

/// Local-file resolver: the deck refuses remote sources (Phase 0 item 3), and
/// these tests are about *which* track is seeded, not where its bytes live.
class _LocalResolver implements EngineAudioSourceResolver {
  const _LocalResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.local(Uri.file('/tmp/dj-playback-truth.mp3'));
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}
