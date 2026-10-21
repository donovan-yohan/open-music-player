import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/auth/biometric_unlock_service.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/share/shared_intent_receiver.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show snapshot, flush;

void main() {
  testWidgets('locked startup waits for authenticated admission',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final storage =
        SecureStorage(tokenStorage: _BiometricTokens()..enabled = true);
    final wire = support.Wire((o) {
      if (o.path == '/auth/refresh') {
        return support.reply({'accessToken': 'restored', 'refreshToken': 'r'});
      }
      if (o.method == 'POST') {
        return support.reply({
          'device': {...deviceJson(), 'deviceId': o.data['deviceId']}
        }, 201);
      }
      return support.reply({'device': deviceJson()});
    });
    final api = support.client(storage, wire);
    final biometrics = _Biometrics()..allow = false;
    final auth = AuthState(
        authService: AuthService(
            api: api, storage: storage, biometricUnlockService: biometrics));
    final check = auth.checkAuthStatus();
    await flush(tester);
    await check;
    expect(auth.isBiometricLocked, isTrue);
    final playback = ConnectPlayback();
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        sharedIntentReceiver: NoSharedIntent());
    app.router.go('/share');
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: app));
    await flush(tester);
    expect(playback.source.hasListener, isFalse);
    expect(
        wire.requests.where((o) => o.path.startsWith('/me/devices')), isEmpty);
    biometrics.allow = true;
    final unlock = auth.unlockWithBiometrics();
    await flush(tester);
    expect(await unlock, isTrue);
    await flush(tester);
    expect(playback.source.hasListener, isTrue);
    expect(
        wire.requests
            .where((o) => o.method == 'POST' && o.path == '/me/devices'),
        hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    app.router.dispose();
    auth.dispose();
    await playback.source.close();
  });

  testWidgets('production app attaches once after authenticated admission',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final storage = SecureStorage(tokenStorage: _BiometricTokens());
    final loginGate = Completer<void>();
    Completer<void>? reportGate;
    final logoutGate = Completer<void>();
    final wire = support.Wire((o) async {
      if (o.path == '/auth/login') {
        await loginGate.future;
        return support.reply({'accessToken': 'signed-in', 'refreshToken': 'r'});
      }
      if (o.method == 'POST' && o.path == '/me/devices') {
        // Authorization is asserted after the real adapter completes.
        return support.reply({
          'device': {...deviceJson(), 'deviceId': (o.data as Map)['deviceId']}
        }, 201);
      }
      if (o.method == 'PUT') {
        await reportGate?.future;
        return support.reply({'device': deviceJson()});
      }
      if (o.path == '/auth/logout') await logoutGate.future;
      return support.reply({}, 204);
    });
    final api = support.client(storage, wire);
    final auth = AuthState(
        authService: AuthService(
            api: api, storage: storage, biometricUnlockService: _Biometrics()));
    final playback = ConnectPlayback();
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        sharedIntentReceiver: NoSharedIntent());
    // Avoid unrelated home/library providers while still mounting the real app.
    app.router.go('/share');
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: app));
    await flush(tester);
    expect(playback.source.hasListener, isFalse);
    expect(
        wire.requests.where((o) => o.path.startsWith('/me/devices')), isEmpty);

    final login =
        auth.login(email: 'fixture@example.test', password: 'fixture');
    await flush(tester);
    expect(auth.isLoading, isTrue);
    expect(playback.source.hasListener, isFalse);
    loginGate.complete();
    await flush(tester);
    expect(await login, isTrue);
    await flush(tester);
    expect(playback.source.hasListener, isTrue);
    expect(
        wire.requests
            .where((o) => o.method == 'POST' && o.path == '/me/devices'),
        hasLength(1));
    final report = wire.requests.singleWhere((o) => o.method == 'PUT',
        orElse: () => throw StateError(
            'requests: ${wire.requests.map((o) => '${o.method} ${o.path} ${o.data} ${o.headers}').toList()}'));
    expect((report.data as Map)['playback']['positionMs'], 1200);
    expect((report.data as Map)['playback']['activeVoiceCount'], 2);
    expect(report.headers['Authorization'], 'Bearer signed-in');
    final registration = wire.requests
        .singleWhere((o) => o.method == 'POST' && o.path == '/me/devices');
    expect(registration.data['platform'], 'macos');

    auth.clearError();
    await flush(tester);
    await auth.setBiometricUnlockEnabled(false);
    await flush(tester);
    expect(
        wire.requests
            .where((o) => o.method == 'POST' && o.path == '/me/devices'),
        hasLength(1),
        reason: 'unrelated auth notifications keep the incarnation');

    final enabled = auth.setBiometricUnlockEnabled(true);
    await flush(tester);
    expect(await enabled, isTrue);
    final firstId = wire.requests
        .firstWhere((o) => o.path == '/me/devices')
        .data['deviceId'];
    for (final lifecycle in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      await flush(tester, const Duration(seconds: 5));
      expect(playback.source.hasListener, isTrue);
      expect(
          wire.requests
              .where((o) => o.method == 'POST' && o.path == '/me/devices'),
          hasLength(1));
      expect(wire.requests.lastWhere((o) => o.method == 'PUT').path,
          endsWith(firstId));
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await flush(tester);
    expect(playback.source.hasListener, isFalse,
        reason: 'detached process retires presence');
    final detachedCount = wire.requests.length;
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, hasLength(detachedCount));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(playback.source.hasListener, isTrue);
    final registrations = wire.requests
        .where((o) => o.method == 'POST' && o.path == '/me/devices');
    expect(registrations, hasLength(2));
    expect(registrations.last.data['deviceId'], isNot(firstId));

    reportGate = Completer<void>();
    await flush(tester, const Duration(seconds: 5));
    final pending = wire.requests.lastWhere((o) => o.method == 'PUT');
    expect(pending.cancelToken!.isCancelled, isFalse);
    final logout = auth.logout();
    expect(pending.cancelToken!.isCancelled, isTrue,
        reason: 'auth intent cancels before logout awaits the server');
    await flush(tester);
    expect(playback.source.hasListener, isFalse);
    final countAfterLogout =
        wire.requests.where((o) => o.path.startsWith('/me/devices')).length;
    reportGate.complete();
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests.where((o) => o.path.startsWith('/me/devices')),
        hasLength(countAfterLogout));
    logoutGate.complete();
    await flush(tester);
    await logout;
    await flush(tester);
    expect(wire.requests.where((o) => o.path.startsWith('/me/devices')),
        hasLength(countAfterLogout));
    final nextLogin = auth.login(email: 'b@example.test', password: 'fixture');
    await flush(tester);
    expect(await nextLogin, isTrue);
    await flush(tester);
    expect(playback.source.hasListener, isTrue);
    final nextRegistrations = wire.requests
        .where((o) => o.method == 'POST' && o.path == '/me/devices');
    expect(nextRegistrations, hasLength(3));
    expect(nextRegistrations.last.data['deviceId'], isNot(firstId));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(playback.source.hasListener, isFalse);
    app.router.dispose();
    auth.dispose();
    await playback.source.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

class _BiometricTokens extends support.MemoryTokens {
  bool enabled = false;
  @override
  Future<bool> isBiometricUnlockEnabled() async => enabled;
  @override
  Future<void> setBiometricUnlockEnabled(bool value) async => enabled = value;
}

class _Biometrics implements BiometricUnlockService {
  bool allow = true;
  @override
  Future<bool> isDeviceUnlockAvailable() async => true;
  @override
  Future<bool> authenticate({required String reason}) async => allow;
}

class NoSharedIntent extends SharedIntentReceiver {
  @override
  Future<String?> initialSharedText() async => null;
  @override
  Stream<String> sharedTextStream() => const Stream.empty();
}

/// Only the hardware transport is absent; the canonical-shaped ValueStream is
/// observed by the real production presence service and authenticated ApiClient.
class ConnectPlayback extends Fake implements PlaybackState {
  final source =
      BehaviorSubject<PlaybackSnapshot>.seeded(snapshot(position: 1200));
  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => source;
  @override
  bool get hasTrack => false;
  @override
  bool get isPlaying => false;
  @override
  List<MediaItem> get queue => const [];
  @override
  int? get currentIndex => null;
  @override
  Duration get duration => Duration.zero;
  @override
  Duration get position => Duration.zero;
  @override
  bool get canSkipNext => false;
  @override
  bool get canSkipPrevious => false;
  @override
  Future<void> applyAudioDefaults(AudioPlaybackDefaults defaults) async {}
  @override
  void setEndOfQueueMode(EndOfQueueMode mode) {}
  @override
  void setSwipeQueueMode(QueueInsertMode mode) {}
  @override
  void setPreserveManualQueue(bool preserve) {}
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
