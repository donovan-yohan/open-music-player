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
import 'core/audio/audio_preparation_service.dart';
import 'core/audio/library_shuffle_continuation.dart';
import 'core/audio/mix_audio_handler.dart';
import 'core/audio/playback_state.dart';
import 'core/audio/play_recorder_service.dart';
import 'core/audio/queue_persistence.dart';
import 'core/audio/signed_audio_url_service.dart';
import 'core/engine/playback_engine.dart';
import 'core/engine/native_playback_backend.dart';
import 'core/engine/engine_audio_source_resolver.dart';
import 'core/cache/playback_cache_manager.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/auth_state.dart';
import 'core/providers/settings_provider.dart';
import 'core/storage/secure_storage.dart';
import 'core/storage/offline_database.dart';
import 'core/network/connectivity_service.dart';
import 'core/platform/desktop_initialization.dart';
import 'core/platform/application_startup.dart';
import 'core/download/download_service.dart';
import 'core/download/download_state.dart';
import 'core/services/library_service.dart';
import 'core/services/liked_tracks_state.dart';
import 'core/performance/performance_fixture.dart';

Future<void> main() async {
  await PerformanceFixture.preflight();
  WidgetsFlutterBinding.ensureInitialized();
  PerformanceFixture.verifyIsolation();
  await PerformanceFixture.configureDatabases();
  await runApplicationStartup(_initializeApplication);
}

/// Bind before account consumers. Auth intent revokes work synchronously;
/// Connect waits on the canonical owner barrier. Short-lived embedders unbind.
VoidCallback bindPlaybackAccountRetirement({
  required AuthState authState,
  required PlaybackState playbackState,
  VoidCallback? onRetirement,
}) {
  var revision = authState.sessionRevision;
  void changed() {
    if (revision == authState.sessionRevision) return;
    revision = authState.sessionRevision;
    final retirement = playbackState.retireAccount();
    onRetirement?.call();
    // The owner retains failures on its admission barrier, failing closed.
    unawaited(retirement.catchError((Object error, StackTrace stack) {
      debugPrint('Playback account retirement failed: $error');
    }));
  }

  authState.addListener(changed);
  return () => authState.removeListener(changed);
}

Future<void> _initializeApplication() async {
  final sharedPreferences = await SharedPreferences.getInstance();

  final storage = SecureStorage(storage: applicationSecureStorage());
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);
  await authState.checkAuthStatus();
  final fixture = PerformanceFixture.active;
  if (fixture != null &&
      !await authState.login(
          email: fixture.email, password: fixture.password)) {
    throw StateError('fixture-authentication-failed');
  }
  Future<String?> currentAccountId() async =>
      accountIdFromAccessToken(await storage.getAccessToken());
  final initialAccountId = await currentAccountId();
  final libraryService = LibraryService(apiClient);
  final likedTracksState = LikedTracksState(
    libraryService,
    accountId: initialAccountId,
  );

  final signedAudioUrlService = SignedAudioUrlService(apiClient);

  final offlineDb =
      OfflineDatabase(databasePathProvider: fixture?.databasePath);
  final connectivityService = ConnectivityService();
  final downloadService = DownloadService(
    db: offlineDb,
    signedAudioUrlService: signedAudioUrlService,
    downloadDirectoryProvider: fixture?.downloadDirectory,
  );
  final downloadState = DownloadState(
    downloadService: downloadService,
    db: offlineDb,
  );

  // Bounded, evictable playback cache: bandwidth-saving copies of recent/near
  // playback artifacts, separate from explicit downloads. Native platforms only — it
  // needs a real filesystem, so (like explicit downloads) it stays disabled on
  // web, where playback falls back to signed URLs.
  final playbackCacheManager = kIsWeb
      ? null
      : PlaybackCacheManager(
          store: offlineDb,
          explicitDownloads: downloadService,
          cacheDirectoryProvider: fixture?.cacheDirectory,
        );

  final audioPreparationService = playbackCacheManager == null
      ? null
      : AudioPreparationService(
          cache: playbackCacheManager,
          explicitDownloads: downloadService,
          maxConcurrent: 2,
          maxQueued: 16,
        );
  // Listening media items already contain the selected URI. Pin exact cache
  // paths here instead of interpreting their filenames as API track IDs.
  final playbackEngine = PlaybackEngine(
    nativeBackendFactory: applicationNativePlaybackFactory(apiClient,
        accountIdProvider: currentAccountId),
    resolver: DirectEngineAudioSourceResolver(
      acquireLocal: playbackCacheManager?.acquirePath,
    ),
  );

  // Resolution prefers a validated explicit download (offline / after restart),
  // then a matching cache artifact, then a freshly signed remote URL.
  final queuePersistence = QueuePersistenceStore(
    prefs: Future.value(sharedPreferences),
    accountIdProvider: currentAccountId,
  );
  final playbackState = PlaybackState(
    playbackEngine,
    signedAudioUrlService: signedAudioUrlService,
    localResolver: downloadService,
    cacheManager: playbackCacheManager,
    persistence: queuePersistence,
    accountIdProvider: currentAccountId,
    // The selected end-of-queue mode is pushed in from OpenMusicPlayerApp.
    continuationSource: LibraryShuffleContinuationSource(libraryService),
  );
  // Surface the app playback session as one OS media session/notification. The
  // handler consumes PlaybackState's canonical session snapshot so lock-screen
  // metadata and transport controls stay aligned with the visible player.
  //
  // Ownership: audio_service builds this handler once and holds it for the
  // whole process — there is no destroy hook, and an OS stop ends the session
  // without ending the handler, so nothing here disposes it. Its listeners
  // therefore live exactly as long as the app that owns them (LikedTracksState
  // included). MixAudioHandler.dispose() exists for tests and for embedders
  // that do own a shorter-lived handler, and is idempotent for that reason.
  if (!kIsWeb) {
    await audio_service.AudioService.init<MixAudioHandler>(
      cacheManager: fixture?.artworkCache,
      builder: () => MixAudioHandler(
        playbackState: playbackState,
        likedTracksState: likedTracksState,
      ),
      config: const audio_service.AudioServiceConfig(
        androidNotificationChannelId: 'com.openmusicplayer.app.channel.audio',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/omp_notification',
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
  var persistenceAuthStatus = authState.status;
  bindPlaybackAccountRetirement(
    authState: authState,
    playbackState: playbackState,
    onRetirement: () {
      queuePersistence.invalidateAccountId();
      playRecorder.reset();
    },
  );
  authState.addListener(() {
    if (authState.status != persistenceAuthStatus) {
      persistenceAuthStatus = authState.status;
      queuePersistence.invalidateAccountId();
    }
    final syncGeneration = ++accountSyncGeneration;
    if (!authState.isAuthenticated || authState.isLoading) {
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
          provider.Provider<AudioPreparationService?>.value(
            value: audioPreparationService,
          ),
          provider.Provider<PlaybackCacheManager?>.value(
            value: playbackCacheManager,
          ),
        ],
        child: OpenMusicPlayerApp(
          apiClient: apiClient,
          authState: authState,
          playbackState: playbackState,
          playbackAccountRetirement: () => playbackState.accountRetirement,
        ),
      ),
    ),
  );
}
