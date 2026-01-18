import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/audio/audio_player_service.dart';
import 'core/audio/playback_state.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/auth_state.dart';
import 'core/providers/settings_provider.dart';
import 'core/storage/secure_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SharedPreferences before app starts
  final sharedPreferences = await SharedPreferences.getInstance();

  final storage = SecureStorage();
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);

  final audioService = await AudioPlayerService.init();
  final playbackState = PlaybackState(audioService);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: OpenMusicPlayerApp(
        authState: authState,
        playbackState: playbackState,
      ),
    ),
  );
}
