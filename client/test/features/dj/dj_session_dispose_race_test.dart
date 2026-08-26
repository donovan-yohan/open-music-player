import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_transport.dart';

import '../../support/dj_viewport_fixtures.dart';

/// Every mutator on `DjSessionProvider` awaits the engine and *then* notifies,
/// so each one straddles an async gap that a back-navigation can land in. The
/// deck route owns its session, so leaving disposes the provider while those
/// continuations are still queued — and `notifyListeners` throws on a disposed
/// `ChangeNotifier`, in a continuation nothing awaits, which reaches the app as
/// an unhandled zone error:
///
///     E flutter : Unhandled Exception: A DjSessionProvider was used after
///                 being disposed.
///     #3 DjSessionProvider.togglePlay (dj_session_provider.dart:179:5)
///
/// Observed once on device against #414's head. The 33 Hz snapshot loop already
/// carried its own `_disposed` guard; the deck callbacks did not.
void main() {
  /// Mounts a shell and pushes the deck onto it, so the test can pop the deck
  /// the way the system back gesture does.
  ///
  /// [sessionFactory] (rather than an injected session) is deliberate: it is
  /// the only seam onto the production ownership branch, where the SCREEN
  /// disposes the provider on pop. An injected session stays caller-owned and
  /// is merely parked, which never reproduces this.
  Future<void> openDeck(
    WidgetTester tester, {
    required GlobalKey<NavigatorState> navigator,
    required void Function(DjSessionProvider) onSession,
    required void Function(_GatedVoice) onVoice,
  }) async {
    landscapeReference.apply(tester);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => DjScreen(
            filePicker: () async => null,
            sessionFactory: () {
              final built = DjSessionProvider.prototype(
                voiceFactory: () {
                  final voice = _GatedVoice();
                  onVoice(voice);
                  return voice;
                },
                resolver: const DirectEngineAudioSourceResolver(),
              );
              onSession(built);
              return built;
            },
          ),
        ),
      ),
    );
    // Explicit pumps, never pumpAndSettle: the live session notifies on a 33 ms
    // period, so this tree never goes idle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Pops the deck and lets the reverse transition finish unmounting it. The
  /// route is removed a frame after the animation ends, and the live session
  /// keeps scheduling frames, so this steps rather than settles.
  Future<void> popDeck(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigator,
  ) async {
    navigator.currentState!.pop();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets(
      'a PLAY tap still in flight when the deck route pops does not notify a '
      'disposed session', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final voices = <_GatedVoice>[];
    DjSessionProvider? session;

    await openDeck(
      tester,
      navigator: navigator,
      onSession: (built) => session = built,
      onVoice: voices.add,
    );
    // Deck A is built first, so it holds the first voice.
    expect(voices, hasLength(2));

    // The transport is gated on a deck that holds audio (#414), so seed one.
    await session!.load(DjDeckId.a, djLoadedDeckSeed());
    await tester.pump();

    // PLAY. `togglePlay` reaches `await controller.play()` and parks there,
    // because the voice's gate is still shut.
    await tester.tap(find.byKey(const ValueKey('dj_play_pause')).first);
    await tester.pump();
    expect(voices.first.playCalls, 1,
        reason: 'the tap must reach the engine, or the race is not staged');

    // Back out while that await is unresolved. The screen owns this session,
    // so the pop is what disposes it.
    await popDeck(tester, navigator);
    expect(find.byType(DjScreen), findsNothing);

    // The engine answers only now. `togglePlay` resumes into a provider that
    // was torn down two frames ago.
    voices.first.releasePlay();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull,
        reason: 'a continuation that outlives the route must notify nobody');
  });

  testWidgets('a deck callback captured across the pop drives no released voice',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final voices = <_GatedVoice>[];
    DjSessionProvider? session;

    await openDeck(
      tester,
      navigator: navigator,
      onSession: (built) => session = built,
      onVoice: voices.add,
    );
    await session!.load(DjDeckId.a, djLoadedDeckSeed());
    await tester.pump();

    // A callback held by something that outlives the route — a tooltip, a
    // long-press recogniser, a queued gesture — invoked entirely after dispose.
    final onPlayPause = tester
        .widget<DjTransport>(find.byType(DjTransport).first)
        .onPlayPause;

    await popDeck(tester, navigator);
    expect(find.byType(DjScreen), findsNothing);

    onPlayPause();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(voices.first.playCalls, 0,
        reason: 'a disposed session must not drive a voice it already released');
  });
}

/// A voice whose `play()` hangs until the test lets it finish, which is how the
/// route gets to pop in the middle of `togglePlay`'s await.
class _GatedVoice implements Voice {
  final _events = StreamController<VoiceEvent>.broadcast();
  final _playGate = Completer<void>();
  var playCalls = 0;
  var _playing = false;
  int? _positionMs = 0;

  /// Lets the parked `play()` complete: the engine answering after the deck is
  /// already gone.
  void releasePlay() {
    if (!_playGate.isCompleted) _playGate.complete();
  }

  @override
  String get debugId => 'gated-dj';
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
  Future<void> play() async {
    playCalls++;
    await _playGate.future;
    _playing = true;
  }

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
