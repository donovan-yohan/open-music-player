import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';

void main() {
  // Pixel 10 Pro class landscape: 2856 x 1280 at dpr 3 -> 952 x 426.7 dp.
  void pinViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('deck-unavailable notice replaces the waveform lane',
      (tester) async {
    pinViewport(tester);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, const _RemoteResolver()),
      deckB: _deck(DjDeckId.b, const _LocalResolver()),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DjScreen(session: session, filePicker: () async => null),
      ),
    );
    await tester.pump();
    // Deck A refuses (remote), deck B loads.
    await session.seed(current: _track('11'), next: _track('12'));
    await tester.pump();

    final notice = find.byKey(const ValueKey('dj_deck_unavailable_a'));
    expect(notice, findsOneWidget);
    final text = tester.widget<Text>(notice).data;
    expect(text, 'Download this track to use it on the deck');
    expect(text, isNot(contains('!')));
    expect(find.bySemanticsLabel('Deck A waveform'), findsOneWidget);
    expect(find.bySemanticsLabel('Deck B waveform'), findsOneWidget);
    // A loaded deck keeps its painter path.
    expect(find.byKey(const ValueKey('dj_deck_unavailable_b')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    // The session is built inside the test body, so its 30 Hz snapshot timer
    // is a FakeTimer that must be cancelled before the binding's invariants.
    session.dispose();
  });

  testWidgets('deck entry loads the queue once and does not prompt for a '
      'local file', (tester) async {
    pinViewport(tester);
    final api = _CountingQueueApiClient(
      QueueState(tracks: [_track('4242')], currentIndex: 0),
    );
    final queue = QueueProvider(api);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, const _LocalResolver()),
      deckB: _deck(DjDeckId.b, const _LocalResolver()),
    );
    var pickerCalls = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queue,
        child: MaterialApp(
          home: DjScreen(
            session: session,
            filePicker: () async {
              pickerCalls++;
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(api.getQueueCalls, 1);
    expect(pickerCalls, 0);
    expect(find.text('Load local audio file'), findsNothing);
    expect(session.deckA.isLoaded, isTrue);
    expect(session.deckA.trackRef, '4242');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    // The session is built inside the test body, so its 30 Hz snapshot timer
    // is a FakeTimer that must be cancelled before the binding's invariants.
    session.dispose();
    // QueueProvider's analysis retry timer is a FakeTimer too.
    queue.dispose();
  });

  testWidgets('a genuinely empty queue renders the inline load affordance '
      'instead of a modal', (tester) async {
    pinViewport(tester);
    final api = _CountingQueueApiClient(QueueState.empty());
    final queue = QueueProvider(api);
    final session = DjSessionProvider(
      deckA: _deck(DjDeckId.a, const _LocalResolver()),
      deckB: _deck(DjDeckId.b, const _LocalResolver()),
    );
    var pickerCalls = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queue,
        child: MaterialApp(
          home: DjScreen(
            session: session,
            filePicker: () async {
              pickerCalls++;
              return DjDeckLoad(
                trackRef: 'local:/tmp/picked.mp3',
                title: 'Picked track',
                localUri: Uri.file('/tmp/picked.mp3'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // #414: an empty queue is answered in the lane, not by a modal that
    // ambushes a session that may already be playing.
    expect(api.getQueueCalls, 1);
    expect(pickerCalls, 0);
    expect(find.text('Load local audio file'), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dj_deck_load_file_a')));
    await tester.pumpAndSettle();

    expect(pickerCalls, 1);
    expect(session.deckA.title, 'Picked track');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    // The session is built inside the test body, so its 30 Hz snapshot timer
    // is a FakeTimer that must be cancelled before the binding's invariants.
    session.dispose();
    queue.dispose();
  });
}

/// A short title and a lean analysis: a fully populated deck header overflows
/// this viewport, and that layout ticket belongs to another lane.
QueueTrack _track(String id) => QueueTrack(
      id: id,
      queueItemId: 'queue-item-$id',
      playbackTrackId: id,
      title: 'T$id',
      duration: 196,
      addedAt: DateTime.utc(2026, 8, 26),
    );

DeckController _deck(DjDeckId deckId, EngineAudioSourceResolver resolver) =>
    DeckController.empty(
      deckId: deckId,
      voice: _FakeVoice(),
      resolver: resolver,
      slew: const Duration(milliseconds: 1),
    );

class _CountingQueueApiClient extends EmptyQueueApiClient {
  _CountingQueueApiClient(this.state);
  final QueueState state;
  int getQueueCalls = 0;

  @override
  Future<QueueState> getQueue() async {
    getQueueCalls++;
    return state;
  }

  @override
  Future<TrackAnalysis> getTrackAnalysis(int trackId) async =>
      TrackAnalysis.fromJson(status: 'analyzed', summary: const {});
}

class _LocalResolver implements EngineAudioSourceResolver {
  const _LocalResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.local(Uri.file('/tmp/local.mp3'));
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _RemoteResolver implements EngineAudioSourceResolver {
  const _RemoteResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.remote(
          Uri(scheme: 'https', host: 'example.test'), null);
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _FakeVoice implements Voice {
  bool _playing = false;
  int positionMs = 0;
  final _events = StreamController<VoiceEvent>.broadcast();

  @override
  String get debugId => 'fake';
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  bool get isLoaded => true;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isReady => true;
  @override
  int? get currentLocalPositionMs => positionMs;
  @override
  Future<void> dispose() async => _events.close();
  @override
  int? driftMs(int expectedLocalPositionMs) =>
      positionMs - expectedLocalPositionMs;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    positionMs = initialLocalPositionMs;
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> release() async => _playing = false;
  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);
  @override
  Future<void> seekLocal(int localPositionMs) async =>
      positionMs = localPositionMs;
  @override
  Future<bool> setPitch(double factor) async => true;
  @override
  Future<void> setSpeed(double rate) async {}
  @override
  Future<void> setVolume(double linearGain) async {}
}
