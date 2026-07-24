import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/share/shared_intent_receiver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('settings provider crossfade reaches playback audio defaults',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final playback = _PlaybackState();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: OpenMusicPlayerApp(
          apiClient: ApiClient(),
          authState: _AuthState(),
          playbackState: playback,
          sharedIntentReceiver: _SharedIntentReceiver(),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(OpenMusicPlayerApp)),
      listen: false,
    );
    container.read(settingsProvider.notifier).setCrossfadeDuration(3);
    await tester.pump();

    expect(playback.appliedDefaults.last.defaultCrossfadeMs, 3000);
  });
}

class _PlaybackState extends Fake implements PlaybackState {
  final List<AudioPlaybackDefaults> appliedDefaults = [];

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
  Future<void> applyAudioDefaults(AudioPlaybackDefaults defaults) async {
    appliedDefaults.add(defaults);
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _AuthState extends Fake implements AuthState {
  @override
  AuthStatus get status => AuthStatus.unauthenticated;

  @override
  bool get hasLocalSession => false;

  @override
  bool get isAuthenticated => false;

  @override
  bool get isBiometricLocked => false;

  @override
  bool get isLoading => false;

  @override
  String? get error => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _SharedIntentReceiver extends SharedIntentReceiver {
  @override
  Future<String?> initialSharedText() async => null;

  @override
  Stream<String> sharedTextStream() => const Stream.empty();
}
