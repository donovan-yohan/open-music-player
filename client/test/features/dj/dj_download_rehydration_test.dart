import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/shared/models/track.dart' as library_models;
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';
import 'package:provider/provider.dart';

import '../../support/dj_analysis_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';
import '../../support/mock_dio_client.dart';

/// #410 follow-up from the integrated emulator QA at 92395c4: the in-place
/// download handoff loaded the deck but left its lane on "Analyzing…" with no
/// peaks until the user left `/dj` and came back.
///
/// The cold entry seeds through `QueueProvider.trackWithAnalysis`, which both
/// carries the hydrated snapshot and re-arms hydration interest. The
/// post-download re-seed used the raw `queue.currentTrack` instead, so it
/// pushed the collection payload's compact analysis — which never contains
/// waveform arrays — onto a deck the revision listener already considered
/// reconciled. Nothing fired again, and the lane stayed blank.
///
/// Both orderings of "download lands" and "analysis lands" are pinned here.
void main() {
  testWidgets(
      'a deck downloaded in place paints analysis that hydrated while it was '
      'refused', (tester) async {
    final harness = await _pumpRefusedDeck(tester);

    // The per-track endpoint answers while the deck is still refused. This is
    // the emulator ordering: the user sat on /dj long enough for hydration to
    // finish before tapping Download.
    harness.api.completeAnalysis();
    await tester.pump();
    await tester.pump();
    expect(harness.queue.analysisRevision, greaterThan(0));
    // A refused deck holds no queue track, so the hydrated snapshot has
    // nowhere to land yet.
    expect(harness.session.deckA.queueTrack, isNull);

    await harness.download(tester);

    expect(harness.session.deckA.isLoaded, isTrue);
    expect(
      _lanePainter(tester, DjDeckId.a).waveform!.frames,
      isNotEmpty,
      reason: 'the deck loaded in place but its lane never got the peaks that '
          'QueueProvider had already hydrated',
    );
    expect(_lanePainter(tester, DjDeckId.a).waveform!.analyzed, isTrue);
    expect(
      find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
      findsNothing,
      reason: 'the lane is still telling the user it is analyzing',
    );
    // The user never left the deck, and hydration never became a second load.
    expect(find.byKey(const ValueKey('dj_screen')), findsOneWidget);
    expect(harness.voices.first.loadCount, 1);
    expect(tester.takeException(), isNull);

    await harness.retire(tester);
  });

  testWidgets('analysis that lands after the in-place download still reaches '
      'the lane', (tester) async {
    final harness = await _pumpRefusedDeck(tester);

    await harness.download(tester);

    // Loaded, but the collection payload carries no waveform arrays yet.
    expect(harness.session.deckA.isLoaded, isTrue);
    expect(_lanePainter(tester, DjDeckId.a).waveform!.frames, isEmpty);
    expect(
      find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
      findsOneWidget,
    );

    harness.api.completeAnalysis();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      _lanePainter(tester, DjDeckId.a).waveform!.frames,
      isNotEmpty,
      reason: 'hydration interest was not re-armed by the re-seed',
    );
    expect(
      find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
      findsNothing,
    );
    expect(harness.voices.first.loadCount, 1);
    expect(tester.takeException(), isNull);

    await harness.retire(tester);
  });
}

TimelineWaveformPainter _lanePainter(WidgetTester tester, DjDeckId deck) =>
    tester
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

/// Mounts the real [DjScreen] over a one-row queue the resolver refuses, which
/// is the state the deck's Download affordance exists for.
Future<_DownloadHarness> _pumpRefusedDeck(WidgetTester tester) async {
  landscapeReference.apply(tester);
  final api = _HeldAnalysisQueueApi(
    QueueState(
      tracks: [djAnalysisTrack(id: '4242', analysis: djCompactAnalysis())],
      currentIndex: 0,
    ),
  );
  final queue = QueueProvider(api);
  final resolver = _SwitchableResolver();
  final voices = <CountingFakeVoice>[];
  CountingFakeVoice voice(String id) {
    final created = CountingFakeVoice('dj-download-$id');
    voices.add(created);
    return created;
  }

  final session = DjSessionProvider(
    deckA: DeckController.empty(
      deckId: DjDeckId.a,
      voice: voice('a'),
      resolver: resolver,
      slew: const Duration(milliseconds: 1),
    ),
    deckB: DeckController.empty(
      deckId: DjDeckId.b,
      voice: voice('b'),
      resolver: resolver,
      slew: const Duration(milliseconds: 1),
    ),
  );
  final downloads = _RecordingDownloadState();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ChangeNotifierProvider<DownloadState>.value(value: downloads),
      ],
      child: MaterialApp(home: DjScreen(session: session)),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump();

  expect(session.deckA.isLoaded, isFalse);
  expect(find.byKey(const ValueKey('dj_deck_download_a')), findsOneWidget);

  return _DownloadHarness(
    api: api,
    queue: queue,
    resolver: resolver,
    session: session,
    downloads: downloads,
    voices: voices,
  );
}

class _DownloadHarness {
  _DownloadHarness({
    required this.api,
    required this.queue,
    required this.resolver,
    required this.session,
    required this.downloads,
    required this.voices,
  });

  final _HeldAnalysisQueueApi api;
  final QueueProvider queue;
  final _SwitchableResolver resolver;
  final DjSessionProvider session;
  final _RecordingDownloadState downloads;
  final List<CountingFakeVoice> voices;

  /// Runs the lane's Download affordance to completion, the way the user does:
  /// tap, the transfer lands, the file is now local.
  Future<void> download(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('dj_deck_download_a')));
    await tester.pump();
    expect(downloads.downloadCalls, [4242]);
    resolver.local = true;
    downloads.complete();
    await tester.pumpAndSettle();
  }

  Future<void> retire(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    session.dispose();
    queue.dispose();
    downloads.dispose();
  }
}

/// A queue whose collection payload omits waveform arrays and whose per-track
/// analysis is held until the test releases it.
class _HeldAnalysisQueueApi extends EmptyQueueApiClient {
  _HeldAnalysisQueueApi(this.state);
  final QueueState state;
  final List<Completer<TrackAnalysis>> _pending = [];

  @override
  Future<QueueState> getQueue() async => state;

  @override
  Future<TrackAnalysis> getTrackAnalysis(int trackId) {
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

/// Remote until the transfer lands, local afterwards — the shape the real
/// resolver takes once `DownloadService` has an artifact on disk.
class _SwitchableResolver implements EngineAudioSourceResolver {
  bool local = false;

  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async => local
      ? ResolvedAudioSource.local(Uri.file('/tmp/4242.mp3'))
      : ResolvedAudioSource.remote(
          Uri(scheme: 'https', host: 'example.test'), null);

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

/// Records what the deck asked the pipeline for and lets the test decide when
/// the transfer lands.
class _RecordingDownloadState extends ChangeNotifier implements DownloadState {
  final List<int> downloadCalls = <int>[];
  Completer<void>? _pending;

  void complete() {
    _pending?.complete();
    _pending = null;
    notifyListeners();
  }

  @override
  Future<void> downloadTrack(library_models.Track track) async {
    downloadCalls.add(track.id);
    _pending = Completer<void>();
    await _pending!.future;
  }

  @override
  DownloadProgress? getProgress(int trackId) => null;

  @override
  Set<int> get downloadedTrackIds => const <int>{};

  @override
  bool isDownloading(int trackId) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
