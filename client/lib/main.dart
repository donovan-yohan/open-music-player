import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/audio/audio_player_service.dart';
import 'core/audio/playback_state.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/auth_state.dart';
import 'core/providers/settings_provider.dart';
import 'core/storage/secure_storage.dart';
import 'core/storage/offline_database.dart';
import 'core/network/connectivity_service.dart';
import 'core/download/download_service.dart';
import 'core/download/download_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final sharedPreferences = await SharedPreferences.getInstance();

  final storage = SecureStorage();
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);

  final audioService = await AudioPlayerService.init();
  final playbackState = PlaybackState(audioService);

  final offlineDb = OfflineDatabase();
  final connectivityService = ConnectivityService();
  final downloadService = DownloadService(db: offlineDb);
  final downloadState = DownloadState(
    downloadService: downloadService,
    db: offlineDb,
  );

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: provider.MultiProvider(
        providers: [
          provider.Provider.value(value: offlineDb),
          provider.ChangeNotifierProvider.value(value: connectivityService),
          provider.Provider.value(value: downloadService),
          provider.ChangeNotifierProvider.value(value: downloadState),
        ],
        child: OpenMusicPlayerApp(
          authState: authState,
          playbackState: playbackState,
        ),
      ),
    ),
  );
}
