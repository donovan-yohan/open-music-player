import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

class OpenMusicPlayerApp extends StatelessWidget {
  const OpenMusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Open Music Player',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
