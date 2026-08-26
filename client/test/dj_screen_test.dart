import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

import 'support/dj_viewport_fixtures.dart';

void main() {
  late DjSessionProvider session;

  setUp(() {
    session = DjSessionProvider.prototype(
      voiceFactory: () => _FakeVoice(),
      resolver: const DirectEngineAudioSourceResolver(),
    );
  });

  tearDown(() => session.dispose());

  Future<void> pumpDj(WidgetTester tester) async {
    landscapeReference.apply(tester);
    await tester.pumpWidget(
      MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null)),
    );
    await tester.pump();
  }

  testWidgets(
      'fits the Pixel 10 Pro landscape viewport and renders both waveform '
      'lanes', (tester) async {
    await pumpDj(tester);

    expect(find.byKey(const ValueKey('dj_screen')), findsOneWidget);
    expect(find.bySemanticsLabel('Deck A waveform'), findsOneWidget);
    expect(find.bySemanticsLabel('Deck B waveform'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport toggles a loaded deck and never an empty one',
      (tester) async {
    await pumpDj(tester);
    expect(session.deckA.playing, isFalse);

    // #414: an empty deck's transport is gated. PLAY used to latch
    // `playing == true` over silence on a deck holding no audio.
    await tester.tap(
      find.byKey(const ValueKey('dj_play_pause')).first,
      warnIfMissed: false,
    );
    await tester.pump();
    expect(session.deckA.playing, isFalse);

    await session.load(DjDeckId.a, djLoadedDeckSeed());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('dj_play_pause')).first);
    await tester.pump();

    expect(session.deckA.playing, isTrue);
  });

  testWidgets('the stems panel is reachable but exposes no mixer', (
    tester,
  ) async {
    await pumpDj(tester);

    // STEMS used to be hidden until stems existed, which made the opt-in
    // unreachable. The segment is now always present; what it shows is the
    // honest state, and an unavailable source still yields no faders.
    expect(find.text('STEMS'), findsWidgets);
    expect(
        find.byType(IconButton).evaluate().where((element) {
          final widget = element.widget as IconButton;
          return widget.tooltip?.contains('Mute') ?? false;
        }),
        isEmpty);
  });

  testWidgets('selecting STEMS shows the honest unavailable state', (
    tester,
  ) async {
    await pumpDj(tester);

    await tester.tap(find.text('STEMS').first);
    await tester.pumpAndSettle();

    // The default prototype session carries no backend-bound source, so the
    // panel must not offer a separation it cannot queue.
    expect(find.byKey(const ValueKey('dj_stem_unsupported')), findsWidgets);
    expect(find.byKey(const ValueKey('dj_stem_separate')), findsNothing);
  });

  testWidgets('empty queue invokes local-file fallback and loads deck A', (
    tester,
  ) async {
    var fallbackCalls = 0;
    landscapeReference.apply(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: DjScreen(
          session: session,
          filePicker: () async {
            fallbackCalls++;
            return DjDeckLoad(
              trackRef: 'picked-track',
              title: 'Picked track',
              localUri: Uri(scheme: 'file', path: '/tmp/picked.mp3'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(fallbackCalls, 1);
    expect(session.deckA.trackRef, 'picked-track');
    expect(session.deckA.title, 'Picked track');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}

class _FakeVoice implements Voice {
  final _events = StreamController<VoiceEvent>.broadcast();
  var _playing = false;
  int? _positionMs;

  @override
  String get debugId => 'test-dj';
  @override
  bool get isLoaded => true;
  @override
  bool get isReady => true;
  @override
  bool get isPlaying => _playing;
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  int? get currentLocalPositionMs => _positionMs;
  @override
  Future<void> dispose() => _events.close();
  @override
  int? driftMs(int expectedLocalPositionMs) => 0;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    _positionMs = initialLocalPositionMs;
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
      _positionMs = localPositionMs;
  @override
  Future<bool> setPitch(double factor) async => true;
  @override
  Future<void> setSpeed(double rate) async {}
  @override
  Future<void> setVolume(double linearGain) async {}
}
