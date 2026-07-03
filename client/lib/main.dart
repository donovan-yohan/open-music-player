import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/audio/playback_state.dart';
import 'core/audio/play_recorder_service.dart';
import 'core/audio/queue_persistence.dart';
import 'core/audio/signed_audio_url_service.dart';
import 'core/engine/playback_engine.dart';
import 'core/cache/playback_cache_manager.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/auth_state.dart';
import 'core/providers/settings_provider.dart';
import 'core/storage/secure_storage.dart';
import 'core/storage/offline_database.dart';
import 'core/network/connectivity_service.dart';
import 'core/download/download_service.dart';
import 'core/download/download_state.dart';

const _enableJustAudioBackground = bool.fromEnvironment(
  'OMP_ENABLE_JUST_AUDIO_BACKGROUND',
  defaultValue: true,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Surface a media-style now-playing notification (lock screen + shade) with
  // transport controls while audio plays. Must run before any AudioPlayer is
  // constructed by the PlaybackEngine. Mobile-only — not on web.
  //
  // The Phase 2 mix-engine dogfood build disables this with
  // OMP_ENABLE_JUST_AUDIO_BACKGROUND=false because just_audio_background wraps
  // the just_audio platform with a single-player background adapter. The debug
  // mix proof intentionally creates up to four real AudioPlayers, then owns its
  // own AudioService handler from the debug screen.
  if (!kIsWeb && _enableJustAudioBackground) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.openmusicplayer.app.channel.audio',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    );
  }

  final sharedPreferences = await SharedPreferences.getInstance();

  final storage = SecureStorage();
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);
  await authState.checkAuthStatus();

  final signedAudioUrlService = SignedAudioUrlService(apiClient);
  final playbackEngine = PlaybackEngine();

  final offlineDb = OfflineDatabase();
  final connectivityService = ConnectivityService();
  final downloadService = DownloadService(
    db: offlineDb,
    signedAudioUrlService: signedAudioUrlService,
  );
  final downloadState = DownloadState(
    downloadService: downloadService,
    db: offlineDb,
  );

  // Bounded, evictable playback cache: bandwidth-saving copies of recent/near
  // playback artifacts, separate from explicit downloads. Mobile-only — it
  // needs a real filesystem, so (like explicit downloads) it stays disabled on
  // web, where playback falls back to signed URLs.
  final playbackCacheManager = kIsWeb
      ? null
      : PlaybackCacheManager(
          store: offlineDb,
          explicitDownloads: downloadService,
        );

  // Resolution prefers a validated explicit download (offline / after restart),
  // then a matching cache artifact, then a freshly signed remote URL.
  final playbackState = PlaybackState(
    playbackEngine,
    signedAudioUrlService: signedAudioUrlService,
    localResolver: downloadService,
    cacheManager: playbackCacheManager,
    persistence: QueuePersistenceStore(prefs: Future.value(sharedPreferences)),
  );
  // Rebuild the last listening queue (paused, at the saved position) so a
  // restart resumes where the user left off. Best-effort: failures are
  // swallowed inside restore() and never block startup.
  unawaited(playbackState.restore());

  // Records exactly one play per continuous listen (>=30s or completion) to
  // /me/plays, tagged with the current playback context. Pending state is
  // cleared whenever the session drops so a play can't cross accounts.
  final playRecorder = PlayRecorderService(
    playbackState,
    ApiPlayEventSink(apiClient),
  )..start();
  authState.addListener(() {
    if (!authState.isAuthenticated) {
      playRecorder.reset();
    }
  });

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: provider.MultiProvider(
        providers: [
          provider.Provider.value(value: storage),
          provider.Provider.value(value: offlineDb),
          provider.ChangeNotifierProvider.value(value: connectivityService),
          provider.Provider.value(value: downloadService),
          provider.ChangeNotifierProvider.value(value: downloadState),
        ],
        child: OpenMusicPlayerApp(
          apiClient: apiClient,
          authState: authState,
          playbackState: playbackState,
        ),
      ),
    ),
  );
}
