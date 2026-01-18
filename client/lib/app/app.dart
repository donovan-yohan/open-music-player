import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/auth/auth_state.dart';
import '../providers/queue_provider.dart';
import '../services/api_client.dart' as queue_api;
import 'router.dart';
import 'theme.dart';

class OpenMusicPlayerApp extends StatelessWidget {
  final AuthState authState;

  const OpenMusicPlayerApp({
    super.key,
    required this.authState,
  });

  @override
  Widget build(BuildContext context) {
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
        themeMode: ThemeMode.dark,
        routerConfig: router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
