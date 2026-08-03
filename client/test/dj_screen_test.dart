import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

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
    tester.view.physicalSize = const Size(980, 448);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
          home: DjScreen(session: session, filePicker: () async => null)),
    );
    await tester.pump();
  }

  testWidgets('fits 980 by 448 and renders both waveform lanes',
      (tester) async {
    await pumpDj(tester);

    expect(find.byKey(const ValueKey('dj_screen')), findsOneWidget);
    expect(find.bySemanticsLabel('Deck A waveform'), findsOneWidget);
    expect(find.bySemanticsLabel('Deck B waveform'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport toggles deck playback state', (tester) async {
    await pumpDj(tester);
    expect(session.deckA.playing, isFalse);

    await tester.tap(find.byKey(const ValueKey('dj_play_pause')).first);
    await tester.pump();

    expect(session.deckA.playing, isTrue);
  });

  testWidgets('unavailable stem source is hidden', (tester) async {
    await pumpDj(tester);

    expect(find.text('STEMS'), findsNothing);
    expect(
        find.byType(IconButton).evaluate().where((element) {
          final widget = element.widget as IconButton;
          return widget.tooltip?.contains('Mute') ?? false;
        }),
        isEmpty);
  });

  testWidgets('empty queue invokes local-file fallback and loads deck A', (
    tester,
  ) async {
    var fallbackCalls = 0;
    tester.view.physicalSize = const Size(980, 448);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
