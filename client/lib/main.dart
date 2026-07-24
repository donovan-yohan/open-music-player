import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart' as audio_service;

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/audio/audio_focus_coordinator.dart';
import 'core/audio/mix_audio_handler.dart';
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
import 'core/services/api_client.dart' as services_api;
import 'core/services/library_service.dart';
import 'core/services/liked_tracks_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final sharedPreferences = await SharedPreferences.getInstance();

  final storage = SecureStorage();
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);
  await authState.checkAuthStatus();
  Future<String?> currentAccountId() async =>
      accountIdFromAccessToken(await storage.getAccessToken());
  final initialAccountId = await currentAccountId();
  final likedTracksState = LikedTracksState(
    LibraryService(services_api.ApiClient(storage: storage)),
    accountId: initialAccountId,
  );

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
    persistence: QueuePersistenceStore(
      prefs: Future.value(sharedPreferences),
      accountIdProvider: currentAccountId,
    ),
    accountIdProvider: currentAccountId,
  );
  // Surface the app playback session as one OS media session/notification. The
  // handler consumes PlaybackState's canonical session snapshot so lock-screen
  // metadata and transport controls stay aligned with the visible player.
  if (!kIsWeb) {
    await audio_service.AudioService.init<MixAudioHandler>(
      builder: () => MixAudioHandler(playbackState: playbackState),
      config: const audio_service.AudioServiceConfig(
        androidNotificationChannelId: 'com.openmusicplayer.app.channel.audio',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  }
  final audioFocusCoordinator = AudioFocusCoordinator(playback: playbackState);
  await audioFocusCoordinator.start();
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
  var accountSyncGeneration = 0;
  authState.addListener(() {
    final syncGeneration = ++accountSyncGeneration;
    if (!authState.isAuthenticated) {
      playRecorder.reset();
      likedTracksState.setAccountId(null);
    } else {
      unawaited(
        currentAccountId().then((accountId) {
          if (syncGeneration != accountSyncGeneration ||
              !authState.isAuthenticated) {
            return;
          }
          likedTracksState.setAccountId(accountId);
        }),
      );
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
          provider.ChangeNotifierProvider.value(value: likedTracksState),
          provider.Provider<PlaybackCacheManager?>.value(
            value: playbackCacheManager,
          ),
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
