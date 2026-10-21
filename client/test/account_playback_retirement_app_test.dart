import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/main.dart' show bindPlaybackAccountRetirement;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_voice.dart';
import 'connect_app_composition_test.dart' show NoSharedIntent;
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show flush;

class _HeldVoice extends FakeVoice {
  _HeldVoice() : super('no-hardware');
  Completer<void>? pauseGate;
  @override
  Future<void> pause() async {
    await pauseGate?.future;
    await super.pause();
  }
}

void main() {
  testWidgets(
      'real main reset retires canonical A metadata before B presence admission',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final voices = <_HeldVoice>[];
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () {
        final voice = _HeldVoice();
        voices.add(voice);
        return voice;
      },
    );
    final playback = PlaybackState(
      engine,
      signedAudioUrlService:
          SignedAudioUrlService.withRequester((body) async => {
                'urls': [
                  for (final id in body['trackIds'] as List)
                    {
                      'trackId': id,
                      'url': 'https://example.test/$id.mp3',
                      'expiresAt': DateTime.utc(2027).toIso8601String()
                    }
                ],
                'unavailable': <Map<String, dynamic>>[],
              }),
    );
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) {
      if (o.path == '/auth/login') {
        return support
            .reply({'accessToken': o.data['email'], 'refreshToken': 'refresh'});
      }
      if (o.path == '/auth/logout') return support.reply({}, 204);
      if (o.method == 'POST') {
        return support.reply({
          'device': {...deviceJson(), 'deviceId': o.data['deviceId']}
        }, 201);
      }
      return support.reply({'device': deviceJson()});
    });
    final api = support.client(storage, wire);
    final auth = AuthState(
        authService: AuthService(
            api: api,
            storage: storage,
            biometricUnlockService: support.NoBiometrics()));
    final unbind =
        bindPlaybackAccountRetirement(authState: auth, playbackState: playback);
    final a = auth.login(email: 'account-a', password: 'fixture');
    await flush(tester);
    expect(await a, isTrue);
    final playing = playback.playQueue([
      {
        'id': 42,
        'title': 'Account A private recording',
        'artist': 'Private',
        'duration': 30
      }
    ],
        context: const PlaybackContext(
            kind: PlaybackContextKind.playlist,
            id: 'private-a',
            label: 'Private A'));
    await flush(tester);
    await playing;
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        playbackAccountRetirement: () => playback.accountRetirement,
        sharedIntentReceiver: NoSharedIntent());
    app.router.go('/share');
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: app));
    await flush(tester);
    final gate = Completer<void>();
    for (final voice in voices) {
      voice.pauseGate = gate;
    }
    final oldTransport = playback.transportCommandGeneration;
    final logout = auth.logout();
    expect(playback.transportCommandGeneration, greaterThan(oldTransport));
    await flush(tester);
    await logout;
    final b = auth.login(email: 'account-b', password: 'fixture');
    await flush(tester);
    expect(await b, isTrue);
    await flush(tester);
    expect(
        wire.requests.where((o) =>
            o.path.startsWith('/me/devices') &&
            o.headers['Authorization'] == 'Bearer account-b'),
        isEmpty,
        reason: 'Even registration waits for old canonical retirement');
    gate.complete();
    await flush(tester);
    await playback.accountRetirement;
    expect(playback.snapshot.currentMediaItem, isNull);
    expect(playback.currentItem, isNull);
    expect(playback.queue, isEmpty);
    expect(playback.playbackContext, isNull);
    final bReports = wire.requests.where((o) =>
        o.method == 'PUT' && o.headers['Authorization'] == 'Bearer account-b');
    expect(bReports, isNotEmpty);
    expect(bReports.every((o) => o.data['playback'] == null), isTrue);
    final bPlay = playback.playQueue([
      {'id': 7, 'title': 'Account B selection', 'duration': 30}
    ]);
    await flush(tester);
    await bPlay;
    await flush(tester, const Duration(seconds: 5));
    expect(playback.snapshot.currentMediaItem!.title, 'Account B selection');
    expect(
        wire.requests
            .lastWhere((o) =>
                o.method == 'PUT' &&
                o.headers['Authorization'] == 'Bearer account-b')
            .data['playback']['track']['title'],
        'Account B selection');
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    app.router.dispose();
    unbind();
    auth.dispose();
    final done = Future.wait([
      engine.positionMsStream.drain<void>(),
      engine.isPlayingStream.drain<void>(),
      engine.completedStream.drain<void>(),
      engine.playbackErrors.drain<void>(),
    ]);
    var disposed = false;
    done.then((_) => disposed = true);
    playback.dispose();
    for (var i = 0; i < 200 && !disposed; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(disposed, isTrue);
    await clock.dispose();
  });
}
