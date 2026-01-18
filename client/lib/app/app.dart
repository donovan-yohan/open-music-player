import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/auth/auth_state.dart';
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
    return ChangeNotifierProvider.value(
      value: authState,
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
