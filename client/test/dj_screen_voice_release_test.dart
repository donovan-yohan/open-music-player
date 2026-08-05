import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

/// The deck is the sanctioned ADR 0001 exception: it drives two audio voices of
/// its own, in addition to the five the canonical `VoicePool` already holds.
/// That exception is only bounded if leaving the deck actually gives those
/// voices back — a leaked deck voice would keep an `AudioPlayer` and an audio
/// focus claim alive underneath normal playback for the rest of the session.
///
/// These tests cover both ownership modes, because the release path differs:
/// production mounts `DjScreen()` and owns its session (release AND dispose),
/// while an injected session stays caller-owned (release only).
void main() {
  Future<void> pumpDeck(WidgetTester tester, DjSessionProvider session) async {
    tester.view.physicalSize = const Size(980, 448);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DjScreen(session: session, filePicker: () async => null),
      ),
    );
    await tester.pump();
  }

  testWidgets('leaving the deck releases every injected deck voice',
      (tester) async {
    final voices = <_TrackingVoice>[];
    final session = DjSessionProvider.prototype(
      voiceFactory: () {
        final voice = _TrackingVoice();
        voices.add(voice);
        return voice;
      },
      resolver: const DirectEngineAudioSourceResolver(),
    );

    await pumpDeck(tester, session);
    expect(voices, hasLength(2),
        reason: 'the deck is a two-voice surface: one per deck');
    for (final voice in voices) {
      expect(voice.releaseCount, 0);
    }

    // Unmounting DjScreen is the only exit: back/pop tears the route down.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));

    for (final voice in voices) {
      expect(voice.releaseCount, greaterThanOrEqualTo(1),
          reason: 'an exited deck must hand its voice back');
      expect(voice.isPlaying, isFalse,
          reason: 'a released voice must not still be producing audio');
      // The caller owns an injected session, so the screen must not destroy
      // voices it did not create.
      expect(voice.disposeCount, 0,
          reason: 'an injected session stays caller-owned');
    }

    // The caller retires the session it owns, including its snapshot timer.
    session.dispose();
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('leaving an owned deck releases and disposes both voices',
      (tester) async {
    // The production path: the router builds DjScreen with no session, so the
    // SCREEN owns it and _DjScreenState.dispose() is what must fully tear the
    // voices down. Driving the session directly would not exercise that branch.
    final voices = <_TrackingVoice>[];
    DjSessionProvider buildSession() => DjSessionProvider.prototype(
          voiceFactory: () {
            final voice = _TrackingVoice();
            voices.add(voice);
            return voice;
          },
          resolver: const DirectEngineAudioSourceResolver(),
        );

    tester.view.physicalSize = const Size(980, 448);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DjScreen(
          filePicker: () async => null,
          sessionFactory: buildSession,
        ),
      ),
    );
    await tester.pump();
    expect(voices, hasLength(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));

    for (final voice in voices) {
      expect(voice.releaseCount, 1,
          reason: 'released exactly once, not double-released');
      expect(voice.disposeCount, 1,
          reason: 'a voice the screen created must be destroyed, not parked');
      expect(voice.isPlaying, isFalse);
    }
  });
}

class _TrackingVoice implements Voice {
  final _events = StreamController<VoiceEvent>.broadcast();
  var _playing = false;
  int? _positionMs;
  var releaseCount = 0;
  var disposeCount = 0;

  @override
  String get debugId => 'tracking-dj';
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
  Future<void> dispose() async {
    disposeCount++;
    await _events.close();
  }

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
  Future<void> release() async {
    releaseCount++;
    _playing = false;
  }

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
