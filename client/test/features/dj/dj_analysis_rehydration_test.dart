import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';
import 'package:provider/provider.dart';

import '../../support/dj_analysis_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';

TimelineWaveformPainter lanePainter(WidgetTester tester, DjDeckId deck) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is DjWaveformLane && widget.deck.deckId == deck,
        ),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((paint) => paint.painter)
    .whereType<TimelineWaveformPainter>()
    .first;

void main() {
  group('DeckController.updateQueueTrack (#410)', () {
    test('swaps the analysis snapshot without reloading the voice', () async {
      final voices = <CountingFakeVoice>[];
      final session = djCountingSession(voices);
      addTearDown(session.dispose);
      final compact = djAnalysisTrack(analysis: djCompactAnalysis());
      await djLoadDecks(session, deckA: compact);
      await session.seek(DjDeckId.a, 4321);
      await session.togglePlay(DjDeckId.a);

      final before = session.deckA;
      expect(voices.first.loadCount, 1);
      expect(before.queueTrack!.analysis!.summary!.waveform, isNull);

      final hydrated = compact.copyWith(analysis: djHydratedAnalysis());
      expect(session.applyAnalysisUpdate([hydrated]), isTrue);

      final after = session.deckA;
      expect(identical(after.queueTrack, hydrated), isTrue);
      expect(after.queueTrack!.analysis!.summary!.waveform, isNotNull);
      expect(after.beatsMs, isNotEmpty);
      // Nothing else moved, and no second Voice.load happened.
      expect(voices.first.loadCount, 1);
      expect(after.positionMs, before.positionMs);
      expect(after.loadedCueMs, before.loadedCueMs);
      expect(after.playing, before.playing);
      expect(after.rate, before.rate);
      expect(after.activeLoop, before.activeLoop);
    });

    test('refuses a snapshot that would drop the waveform it already has',
        () async {
      final session = djCountingSession([]);
      addTearDown(session.dispose);
      final compact = djAnalysisTrack(analysis: djCompactAnalysis());
      await djLoadDecks(session, deckA: compact);
      expect(
        session.applyAnalysisUpdate([
          compact.copyWith(analysis: djHydratedAnalysis()),
        ]),
        isTrue,
      );
      final hydrated = session.deckA;
      expect(hydrated.queueTrack!.analysis!.summary!.waveform, isNotNull);

      // What a hydration eviction on another screen produces: the next
      // revision tick offers the deck the compact queue snapshot again.
      // Accepting it would flip a painted lane back to a flat "Analyzing…"
      // baseline and re-derive beatsMs from the truncated grid.
      var notifications = 0;
      void listener() => notifications++;
      session.addListener(listener);
      expect(
        session.applyAnalysisUpdate([
          compact.copyWith(analysis: djCompactAnalysis()),
        ]),
        isFalse,
      );
      session.removeListener(listener);

      expect(notifications, 0);
      expect(identical(session.deckA, hydrated), isTrue);
      expect(session.deckA.queueTrack!.analysis!.summary!.waveform, isNotNull);
      expect(session.deckA.beatsMs, hydrated.beatsMs);
    });

    test('refuses an empty deck and a refused deck', () async {
      final voices = <CountingFakeVoice>[];
      final session = djCountingSession(voices);
      addTearDown(session.dispose);
      await session.load(DjDeckId.b, djRefusedSeed());

      final empty = DeckController.empty(
        deckId: DjDeckId.a,
        voice: CountingFakeVoice('empty'),
        resolver: const DirectEngineAudioSourceResolver(),
      );
      final track = djAnalysisTrack(analysis: djHydratedAnalysis());
      expect(empty.updateQueueTrack(track), isFalse);
      expect(empty.state.queueTrack, isNull);

      final refusedBefore = session.deckB;
      expect(refusedBefore.loadFailure, isNotNull);
      expect(
        session.applyAnalysisUpdate([
          djAnalysisTrack(id: '99', analysis: djHydratedAnalysis()),
        ]),
        isFalse,
      );
      expect(session.deckB.queueTrack, isNull);
      expect(identical(session.deckB, refusedBefore), isTrue);
    });
  });

  group('DjSessionProvider.applyAnalysisUpdate (#410)', () {
    test('routes a queue-item match to one deck and notifies once', () async {
      final session = djCountingSession([]);
      addTearDown(session.dispose);
      final a = djAnalysisTrack(id: '42', analysis: djCompactAnalysis());
      final b = djAnalysisTrack(id: '43', analysis: djCompactAnalysis());
      await djLoadDecks(session, deckA: a, deckB: b);

      final deckABefore = session.deckA;
      var notifications = 0;
      void listener() => notifications++;
      session.addListener(listener);
      expect(
        session.applyAnalysisUpdate([
          b.copyWith(analysis: djHydratedAnalysis()),
        ]),
        isTrue,
      );
      session.removeListener(listener);

      expect(notifications, 1);
      expect(identical(session.deckA, deckABefore), isTrue);
      expect(session.deckB.queueTrack!.analysis!.summary!.waveform, isNotNull);
    });

    test('a two-deck update still notifies exactly once', () async {
      final session = djCountingSession([]);
      addTearDown(session.dispose);
      final a = djAnalysisTrack(id: '42', analysis: djCompactAnalysis());
      final b = djAnalysisTrack(id: '43', analysis: djCompactAnalysis());
      await djLoadDecks(session, deckA: a, deckB: b);

      var notifications = 0;
      void listener() => notifications++;
      session.addListener(listener);
      expect(
        session.applyAnalysisUpdate([
          a.copyWith(analysis: djHydratedAnalysis()),
          b.copyWith(analysis: djHydratedAnalysis()),
        ]),
        isTrue,
      );
      session.removeListener(listener);
      expect(notifications, 1);
    });

    test('an identical track notifies zero times', () async {
      final session = djCountingSession([]);
      addTearDown(session.dispose);
      final a = djAnalysisTrack(analysis: djCompactAnalysis());
      await djLoadDecks(session, deckA: a);

      var notifications = 0;
      void listener() => notifications++;
      session.addListener(listener);
      expect(session.applyAnalysisUpdate([a]), isFalse);
      session.removeListener(listener);
      expect(notifications, 0);
    });
  });

  group('DjScreen re-seeds from QueueProvider.analysisRevision (#410)', () {
    testWidgets('the lane gains frames once the per-track analysis lands',
        (tester) async {
      final api = _HydratingAnalysisApi();
      final queue = QueueProvider(api);
      final voices = <CountingFakeVoice>[];
      final session = DjSessionProvider(
        deckA: DeckController(
          deckId: DjDeckId.a,
          voice: _record(voices, 'a'),
          resolver: const _LocalResolver(),
        ),
        deckB: DeckController(
          deckId: DjDeckId.b,
          voice: _record(voices, 'b'),
          resolver: const _LocalResolver(),
        ),
      );

      landscapeReference.apply(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<QueueProvider>.value(
          value: queue,
          child: MaterialApp(
            home: DjScreen(session: session, filePicker: () async => null),
          ),
        ),
      );
      // Let the post-frame seed run, but hold the analysis fetch.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(session.deckA.isLoaded, isTrue);
      expect(lanePainter(tester, DjDeckId.a).waveform!.frames, isEmpty);
      expect(lanePainter(tester, DjDeckId.a).waveform!.analyzed, isFalse);
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsOneWidget,
      );
      expect(voices.first.loadCount, 1);

      // The per-track endpoint answers with the waveform arrays.
      api.completeAnalysis();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        lanePainter(tester, DjDeckId.a).waveform!.frames,
        isNotEmpty,
        reason: 'hydrated peaks never reached the deck lane',
      );
      expect(lanePainter(tester, DjDeckId.a).waveform!.analyzed, isTrue);
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsNothing,
      );
      // Hydration must never become a second audio load.
      expect(voices.first.loadCount, 1);
      expect(tester.takeException(), isNull);

      await djRetireSession(tester, session, queue: queue);
    });

    testWidgets('a notify with an unchanged revision does not re-seed',
        (tester) async {
      final api = _HydratingAnalysisApi()..autoComplete = true;
      final queue = QueueProvider(api);
      final session = _SpySession();

      landscapeReference.apply(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<QueueProvider>.value(
          value: queue,
          child: MaterialApp(
            home: DjScreen(session: session, filePicker: () async => null),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final applied = session.applyCalls;
      expect(applied, greaterThan(0));
      // A queue/position-only notification leaves analysisRevision alone.
      queue.notifyListeners();
      await tester.pump();
      expect(session.applyCalls, applied);

      // After unmount, a further notification touches nothing.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
      queue.notifyListeners();
      await tester.pump();
      expect(session.applyCalls, applied);
      expect(tester.takeException(), isNull);

      session.dispose();
      queue.dispose();
    });
  });
}

CountingFakeVoice _record(List<CountingFakeVoice> sink, String id) {
  final voice = CountingFakeVoice('dj-$id');
  sink.add(voice);
  return voice;
}

/// A queue whose collection payload omits waveform arrays and whose per-track
/// analysis carries real `artifacts.waveforms.detail.peaks` — the exact shape
/// #410 describes.
class _HydratingAnalysisApi extends ApiClient {
  _HydratingAnalysisApi();

  bool autoComplete = false;
  final List<Completer<TrackAnalysis>> _pending = [];

  // The queue timing mix-plan load is awaited inside loadQueue; leaving it on
  // real transport would strand the deck's post-frame seed.
  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<QueueState> getQueue() async => QueueState(
        tracks: [djAnalysisTrack(analysis: djCompactAnalysis())],
        currentIndex: 0,
      );

  @override
  Future<TrackAnalysis> getTrackAnalysis(int trackId) {
    if (autoComplete) return Future.value(djHydratedAnalysis());
    final completer = Completer<TrackAnalysis>();
    _pending.add(completer);
    return completer.future;
  }

  void completeAnalysis() {
    for (final completer in _pending) {
      if (!completer.isCompleted) completer.complete(djHydratedAnalysis());
    }
    _pending.clear();
  }
}

class _SpySession extends DjSessionProvider {
  _SpySession()
      : super(
          deckA: DeckController(
            deckId: DjDeckId.a,
            voice: CountingFakeVoice('spy-a'),
            resolver: const _LocalResolver(),
          ),
          deckB: DeckController(
            deckId: DjDeckId.b,
            voice: CountingFakeVoice('spy-b'),
            resolver: const _LocalResolver(),
          ),
        );

  int applyCalls = 0;

  @override
  bool applyAnalysisUpdate(Iterable<QueueTrack> tracks) {
    applyCalls++;
    return super.applyAnalysisUpdate(tracks);
  }
}

class _LocalResolver implements EngineAudioSourceResolver {
  const _LocalResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.local(Uri.file('/tmp/dj-rehydration.mp3'));
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}
