import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/auth/auth_state.dart';
import '../core/models/settings_model.dart';
import '../core/providers/settings_provider.dart';
import '../providers/queue_provider.dart';
import '../services/api_client.dart' as queue_api;
import 'router.dart';
import 'theme.dart';

class OpenMusicPlayerApp extends ConsumerWidget {
  final AuthState authState;

  const OpenMusicPlayerApp({
    super.key,
    required this.authState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authState),
        Provider<queue_api.ApiClient>(create: (_) => queue_api.ApiClient()),
        ChangeNotifierProxyProvider<queue_api.ApiClient, QueueProvider>(
          create: (context) => QueueProvider(context.read<queue_api.ApiClient>()),
          update: (_, apiClient, previous) =>
              previous ?? QueueProvider(apiClient),
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
