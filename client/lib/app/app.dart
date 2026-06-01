import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:provider/provider.dart';
import '../core/audio/playback_state.dart';
import '../core/auth/auth_state.dart';
import '../core/models/settings_model.dart';
import '../core/providers/settings_provider.dart';
import '../providers/queue_provider.dart';
import '../services/mock_queue_repository.dart';
import '../services/queue_repository.dart';
import 'router.dart';
import 'theme.dart';

class OpenMusicPlayerApp extends ConsumerWidget {
  final AuthState authState;
  final PlaybackState playbackState;

  const OpenMusicPlayerApp({
    super.key,
    required this.authState,
    required this.playbackState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authState),
        ChangeNotifierProvider.value(value: playbackState),
        // Web/mobile queue skeleton runs on an in-memory repository so it
        // works offline on staging builds and in tests. Swap for an
        // API-backed QueueRepository when backend wiring lands.
        Provider<QueueRepository>(create: (_) => MockQueueRepository()),
        ChangeNotifierProxyProvider<QueueRepository, QueueProvider>(
          create: (context) => QueueProvider(context.read<QueueRepository>()),
          update: (_, repository, previous) =>
              previous ?? QueueProvider(repository),
        ),
      ],
      child: MaterialApp.router(
        title: 'Open Music Player',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: _getThemeMode(settings.themeMode),
        routerConfig: router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }

  ThemeMode _getThemeMode(AppThemeMode appThemeMode) {
    switch (appThemeMode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }
}
