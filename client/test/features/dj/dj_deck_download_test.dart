import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/shared/models/downloaded_track.dart';
import 'package:open_music_player/shared/models/track.dart' as library_models;
import 'package:provider/provider.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/fake_voice.dart';
import '../../support/mock_dio_client.dart';

/// #414 acceptance criterion (d) in widget form: a refused deck offers a
/// download, the transfer runs without the user leaving `/dj`, and the deck
/// re-seeds itself in place when it lands.
///
/// This pumps the real [DjScreen] against the real provider wiring — the
/// `DjDeckActions` seam is supplied by the screen, not by the test — so the
/// screen's queue-row resolution, `Track` synthesis and re-seed are all under
/// test rather than mocked past.
void main() {
  testWidgets('a refused deck downloads and re-seeds without leaving the deck',
      (tester) async {
    landscapeReference.apply(tester);
    final track = djLoadedQueueTrack(id: '4242', title: 'phantom parade');
    final api = _QueueApiClient(QueueState(tracks: [track], currentIndex: 0));
    final queue = QueueProvider(api);
    final resolver = _SwitchableResolver();
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, resolver),
      deckB: _deck(DjDeckId.b, resolver),
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

    // The deck refused: the resolver answered remote for a library track.
    expect(session.deckA.isLoaded, isFalse);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('dj_deck_unavailable_a')))
          .data,
      djDeckDownloadRequired,
    );
    expect(find.byKey(const ValueKey('dj_deck_header_status_a')),
        findsOneWidget);

    // (1) the action reaches the app's one download pipeline, with the id the
    // pipeline keys on.
    await tester.tap(find.byKey(const ValueKey('dj_deck_download_a')));
    await tester.pump();
    expect(downloads.downloadCalls, [4242]);

    // (2) while it is in flight the action is disabled and says so.
    downloads.report(0.4);
    await tester.pump();
    final running = tester.widget<FilledButton>(
      find.byKey(const ValueKey('dj_deck_download_a')),
    );
    expect(running.onPressed, isNull);
    expect(find.text(djDeckDownloadRunningAction), findsOneWidget);

    // (3) on completion the deck re-seeds in place: no route change, no second
    // seed authority.
    resolver.local = true;
    downloads.complete();
    await tester.pumpAndSettle();

    expect(session.deckA.isLoaded, isTrue);
    expect(find.byKey(const ValueKey('dj_deck_unavailable_a')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_header_a')), findsOneWidget);
    expect(find.textContaining('BPM'), findsWidgets);
    expect(find.text('124.5 BPM'), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_screen')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    session.dispose();
    queue.dispose();
    downloads.dispose();
  });

  testWidgets('a failed transfer offers a retry rather than the same button',
      (tester) async {
    landscapeReference.apply(tester);
    final track = djLoadedQueueTrack(id: '4242', title: 'phantom parade');
    final api = _QueueApiClient(QueueState(tracks: [track], currentIndex: 0));
    final queue = QueueProvider(api);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, _SwitchableResolver()),
      deckB: _deck(DjDeckId.b, _SwitchableResolver()),
    );
    final downloads = _RecordingDownloadState()..throwOnDownload = true;

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

    await tester.tap(find.byKey(const ValueKey('dj_deck_download_a')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dj_deck_download_error_a')),
      findsOneWidget,
    );
    expect(find.text(djDeckDownloadRetryAction), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('dj_deck_download_a')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    session.dispose();
    queue.dispose();
    downloads.dispose();
  });

  testWidgets('without a DownloadState the lane offers no download at all',
      (tester) async {
    landscapeReference.apply(tester);
    final track = djLoadedQueueTrack(id: '4242', title: 'phantom parade');
    final api = _QueueApiClient(QueueState(tracks: [track], currentIndex: 0));
    final queue = QueueProvider(api);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, _SwitchableResolver()),
      deckB: _deck(DjDeckId.b, _SwitchableResolver()),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queue,
        child: MaterialApp(home: DjScreen(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('dj_deck_unavailable_a')))
          .data,
      djDeckDownloadRequired,
    );
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    session.dispose();
    queue.dispose();
  });
}

DeckController _deck(DjDeckId deckId, EngineAudioSourceResolver resolver) =>
    DeckController.empty(
      deckId: deckId,
      voice: FakeVoice('download-${deckId.name}'),
      resolver: resolver,
      slew: const Duration(milliseconds: 1),
    );

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

class _QueueApiClient extends EmptyQueueApiClient {
  _QueueApiClient(this.state);
  final QueueState state;

  @override
  Future<QueueState> getQueue() async => state;

  @override
  Future<TrackAnalysis> getTrackAnalysis(int trackId) async =>
      djLoadedAnalysis();
}

/// Records what the deck asked the pipeline for and lets the test drive the
/// transfer's progress and its terminal state.
class _RecordingDownloadState extends ChangeNotifier implements DownloadState {
  final List<int> downloadCalls = <int>[];
  bool throwOnDownload = false;
  DownloadProgress? _progress;
  Completer<void>? _pending;

  void report(double progress) {
    final id = downloadCalls.last;
    _progress = DownloadProgress(
      trackId: id,
      progress: progress,
      status: DownloadStatus.downloading,
    );
    notifyListeners();
  }

  void complete() {
    _progress = null;
    _pending?.complete();
    _pending = null;
    notifyListeners();
  }

  @override
  Future<void> downloadTrack(library_models.Track track) async {
    downloadCalls.add(track.id);
    if (throwOnDownload) throw StateError('transfer failed');
    _pending = Completer<void>();
    await _pending!.future;
  }

  @override
  DownloadProgress? getProgress(int trackId) =>
      _progress?.trackId == trackId ? _progress : null;

  @override
  Set<int> get downloadedTrackIds => const <int>{};

  @override
  bool isDownloading(int trackId) => getProgress(trackId) != null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
