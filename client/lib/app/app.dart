import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/api/api_client.dart';
import '../core/audio/playback_state.dart';
import '../core/auth/auth_state.dart';
import '../core/models/settings_model.dart';
import '../core/providers/settings_provider.dart';
import '../core/share/shared_intent_receiver.dart';
import '../core/share/shared_url_parser.dart';
import '../providers/queue_provider.dart';
import 'router.dart';
import 'theme.dart';

class OpenMusicPlayerApp extends ConsumerStatefulWidget {
  final ApiClient apiClient;
  final AuthState authState;
  final PlaybackState playbackState;
  final GoRouter router;
  final SharedIntentReceiver sharedIntentReceiver;

  OpenMusicPlayerApp({
    super.key,
    required this.apiClient,
    required this.authState,
    required this.playbackState,
    SharedIntentReceiver? sharedIntentReceiver,
  })  : router = createRouter(authState),
        sharedIntentReceiver = sharedIntentReceiver ?? SharedIntentReceiver();

  @override
  ConsumerState<OpenMusicPlayerApp> createState() => _OpenMusicPlayerAppState();
}

class _OpenMusicPlayerAppState extends ConsumerState<OpenMusicPlayerApp>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _sharedTextSubscription;
  String? _pendingSharedText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.authState.addListener(_handleAuthStateChanged);
    _startShareIntentListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authState.removeListener(_handleAuthStateChanged);
    _sharedTextSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (shouldLockForBiometricLifecycleState(state)) {
      widget.authState.lockIfBiometricRequired();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: widget.apiClient),
        ChangeNotifierProvider.value(value: widget.authState),
        ChangeNotifierProvider.value(value: widget.playbackState),
        ChangeNotifierProxyProvider<ApiClient, QueueProvider>(
          create: (context) => QueueProvider(context.read<ApiClient>()),
          update: (_, apiClient, previous) =>
              previous ?? QueueProvider(apiClient),
        ),
      ],
      child: MaterialApp.router(
        title: 'Open Music Player',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: _getThemeMode(settings.themeMode),
        routerConfig: widget.router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }

  void _startShareIntentListener() {
    widget.sharedIntentReceiver.initialSharedText().then(_handleSharedText);
    _sharedTextSubscription = widget.sharedIntentReceiver
        .sharedTextStream()
        .listen(_handleSharedText, onError: (_) {});
  }

  void _handleSharedText(String? sharedText) {
    if (!mounted) return;
    if (parseSharedUrlCandidate(sharedText) == null) return;

    final normalizedText = sharedText!.trim();
    if (_isAuthCheckInFlight) {
      _pendingSharedText = normalizedText;
      return;
    }

    _goToShareImport(normalizedText);
  }

  bool get _isAuthCheckInFlight =>
      widget.authState.status == AuthStatus.initial ||
      widget.authState.status == AuthStatus.checking;

  void _handleAuthStateChanged() {
    if (!mounted || _isAuthCheckInFlight) return;
    final sharedText = _pendingSharedText;
    if (sharedText == null) return;

    _pendingSharedText = null;
    _goToShareImport(sharedText);
  }

  void _goToShareImport(String sharedText) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final encoded = Uri.encodeComponent(sharedText);
      widget.router.go('/share?text=$encoded');
    });
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

bool shouldLockForBiometricLifecycleState(AppLifecycleState state) {
  return state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
}
