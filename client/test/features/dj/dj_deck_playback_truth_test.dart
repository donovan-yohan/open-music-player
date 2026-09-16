import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// The characterization is the user-visible failure: play an album with an
/// empty import queue and the deck must load the track that is actually
/// playing. On HEAD this fails — the deck seeds nothing at all.
///
/// Playback truth is injected through [TestPlaybackState], whose state reads are
/// overridden but whose projection methods are the production ones. A widget
/// test's fake-async zone cannot drain the engine's transport chain, so a real
/// engine here would stall the deck's post-frame callback before the seed ran;
/// the deck-facing adapter is still exercised for real.
void main() {
  /// Pumps the deck over [playback] and an import queue holding [importQueue].
  Future<void> pumpDeck(
    WidgetTester tester, {
    required TestPlaybackState playback,
    required QueueProvider importQueue,
    required DjSessionProvider session,
  }) async {
    landscapeReference.apply(tester);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: importQueue),
        ],
        child: MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets(
      'album playing + empty import queue: deck A is the playing track',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(7001), playbackMediaItem(7002)],
      currentIndex: 1,
    );
    addTearDown(playback.dispose);
    // An import queue that is genuinely empty: no download jobs at all.
    final importQueue = QueueProvider(EmptyQueueApiClient());
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    expect(importQueue.queue.tracks, isEmpty);
    expect(
      session.deckA.isLoaded,
      isTrue,
      reason: 'an empty import queue made the deck seed nothing (#453)',
    );
    expect(session.deckA.trackRef, '7002');
    expect(session.deckB.isLoaded, isFalse,
        reason: 'the playing track is the queue tail, so there is no next');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('deck B is the next track in play order, not the import queue',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [
        playbackMediaItem(7101),
        playbackMediaItem(7102),
        playbackMediaItem(7103),
      ],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);
    final importQueue = QueueProvider(EmptyQueueApiClient());
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    expect(session.deckA.trackRef, '7101');
    expect(session.deckB.trackRef, '7102',
        reason: 'deck B must come from the playback queue, in play order');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('deck B follows play order under shuffle', (tester) async {
    // A shuffle play order that is deliberately not linear: queue index + 1
    // would be 7202, but the play order says 7204 plays next.
    final playback = TestPlaybackState(
      queue: [
        playbackMediaItem(7201),
        playbackMediaItem(7202),
        playbackMediaItem(7203),
        playbackMediaItem(7204),
      ],
      currentIndex: 0,
      playOrder: const [0, 3, 1, 2],
    );
    addTearDown(playback.dispose);
    final importQueue = QueueProvider(EmptyQueueApiClient());

    // The fixture must discriminate, or this test would pass on queue index + 1.
    expect(playback.nextQueueIndexInPlayOrder(0), 3);
    expect(playback.snapshot.currentQueueIndex, 0);

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    expect(session.deckB.trackRef, '7204',
        reason: 'deck B must be the play-order successor '
            '(PlaybackState.nextQueueIndexInPlayOrder), not queue index + 1');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('a deck never seeds from a stale import-queue head',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(9101), playbackMediaItem(9102)],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);
    // The ADR 0012 fiction made concrete: an import queue whose head is a
    // different track from the one playing. `currentPosition` stays at 0, so
    // the import queue presents item 1 as "the playing track".
    final importQueue = QueueProvider(
      _HeadPinnedQueueApiClient(const [9001, 9002]),
    );
    await tester.runAsync(importQueue.loadQueue);

    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    expect(importQueue.currentTrack?.playbackTrackId, '9001',
        reason: 'the import queue still reports its own head as current');
    expect(session.deckA.trackRef, '9101',
        reason: 'the deck must read playback truth, not the import queue head');
    expect(session.deckB.trackRef, '9102');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('the deck seed never issues an import-queue fetch',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(7301), playbackMediaItem(7302)],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);
    final api = _CountingQueueApiClient();
    final importQueue = QueueProvider(api);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    // #453 drops the post-frame `await queue.loadQueue()`: the deck no longer
    // asks the import queue what is playing, so it must not fetch it either.
    expect(api.getQueueCalls, 0);
    expect(session.deckA.trackRef, '7301');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('a deck already holding audio is not replaced by a track change',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(7401), playbackMediaItem(7402)],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);
    final importQueue = QueueProvider(EmptyQueueApiClient());
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );
    expect(session.deckA.trackRef, '7401');
    expect(session.deckB.trackRef, '7402');

    // The listener skips on: playback truth changes under an open deck.
    playback.emitTrackChange(currentIndex: 1);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // A performance surface must not silence a loaded lane because the album
    // moved on. The empty-deck rule is "seed what is empty", not "follow".
    expect(session.deckA.trackRef, '7401',
        reason: 'a loaded deck must keep the track the user is performing');
    expect(session.deckB.trackRef, '7402');

    await djRetireSession(tester, session, queue: importQueue);
  });

  testWidgets('a deck left empty by a first signal is seeded by the next one',
      (tester) async {
    // The #409 shape: the app restores its queue asynchronously
    // (`main.dart:122` is `unawaited(restore())`), so the deck can mount while
    // playback truth is still empty. A one-shot read would leave the deck
    // blank forever; the subscription seeds on the signal that arrives later.
    final playback = TestPlaybackState(
      queue: const [],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);
    final importQueue = QueueProvider(EmptyQueueApiClient());
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a),
      deckB: _deck(DjDeckId.b),
    );

    await pumpDeck(
      tester,
      playback: playback,
      importQueue: importQueue,
      session: session,
    );

    expect(session.deckA.isLoaded, isFalse,
        reason: 'nothing is playing yet, so the deck stays empty');

    // The restore lands.
    playback.emitTrackChange(currentIndex: 0);
    playback.replaceQueueForTest(
      [playbackMediaItem(7501), playbackMediaItem(7502)],
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(session.deckA.trackRef, '7501',
        reason: 'the deck must seed from a signal that arrives after mount, '
            'which is the #409 path a one-shot read would miss');
    expect(session.deckB.trackRef, '7502');

    await djRetireSession(tester, session, queue: importQueue);
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
