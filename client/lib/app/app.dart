import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/api/api_client.dart';
import '../core/audio/playback_state.dart';
import '../core/auth/auth_state.dart';
import '../core/commands/app_command.dart';
import '../core/commands/command_registry.dart';
import '../core/commands/command_widgets.dart';
import '../core/commands/search_focus_controller.dart';
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
  final SearchFocusController searchFocusController;

  factory OpenMusicPlayerApp({
    Key? key,
    required ApiClient apiClient,
    required AuthState authState,
    required PlaybackState playbackState,
    SharedIntentReceiver? sharedIntentReceiver,
  }) {
    final searchFocusController = SearchFocusController();
    return OpenMusicPlayerApp._(
      key: key,
      apiClient: apiClient,
      authState: authState,
      playbackState: playbackState,
      router: createRouter(
        authState,
        searchFocusController: searchFocusController,
      ),
      sharedIntentReceiver: sharedIntentReceiver ?? SharedIntentReceiver(),
      searchFocusController: searchFocusController,
    );
  }

  const OpenMusicPlayerApp._({
    super.key,
    required this.apiClient,
    required this.authState,
    required this.playbackState,
    required this.router,
    required this.sharedIntentReceiver,
    required this.searchFocusController,
  });

  @override
  ConsumerState<OpenMusicPlayerApp> createState() => _OpenMusicPlayerAppState();
}

class _OpenMusicPlayerAppState extends ConsumerState<OpenMusicPlayerApp>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _sharedTextSubscription;
  String? _pendingSharedText;
  late final CommandRegistry _commandRegistry;
  bool _shortcutHelpOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.authState.addListener(_handleAuthStateChanged);
    _commandRegistry = CommandRegistry(playbackState: widget.playbackState);
    _startShareIntentListener();
    _applyCrossfadeDuration(
      ref.read(settingsProvider).crossfadeDuration,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authState.removeListener(_handleAuthStateChanged);
    _sharedTextSubscription?.cancel();
    _commandRegistry.dispose();
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
    ref.listen<int>(
      settingsProvider.select((settings) => settings.crossfadeDuration),
      (_, seconds) => _applyCrossfadeDuration(seconds),
    );
    final settings = ref.watch(settingsProvider);

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: widget.apiClient),
        ChangeNotifierProvider.value(value: widget.authState),
        ChangeNotifierProvider.value(value: widget.playbackState),
        Provider<CommandRegistry>.value(value: _commandRegistry),
        ChangeNotifierProxyProvider<ApiClient, QueueProvider>(
          create: (context) => QueueProvider(context.read<ApiClient>()),
          update: (_, apiClient, previous) =>
              previous ?? QueueProvider(apiClient),
        ),
      ],
      child: MaterialApp.router(
        title: 'Sound Q',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: _getThemeMode(settings.themeMode),
        routerConfig: widget.router,
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          final navigation = _AppCommandNavigation(
            router: widget.router,
            searchFocusController: widget.searchFocusController,
            showShortcutHelp: () => _showShortcutHelp(context),
          );
          return CommandHost(
            registry: _commandRegistry,
            contextFor: (_) => CommandContext(
              playbackState: widget.playbackState,
              navigation: navigation,
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }

  void _applyCrossfadeDuration(int seconds) {
    unawaited(
      widget.playbackState.applyAudioDefaults(
        AudioPlaybackDefaults(defaultCrossfadeMs: seconds * 1000),
      ),
    );
  }

  Future<void> _showShortcutHelp(BuildContext fallbackContext) async {
    if (_shortcutHelpOpen) return;
    _shortcutHelpOpen = true;
    try {
      final navigatorContext =
          widget.router.routerDelegate.navigatorKey.currentContext ??
              fallbackContext;
      await showShortcutHelpDialog(navigatorContext, _commandRegistry);
    } finally {
      _shortcutHelpOpen = false;
    }
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

class _AppCommandNavigation implements CommandNavigation {
  const _AppCommandNavigation({
    required this.router,
    required this.searchFocusController,
    required Future<void> Function() showShortcutHelp,
  }) : _showShortcutHelp = showShortcutHelp;

  final GoRouter router;
  final SearchFocusController searchFocusController;
  final Future<void> Function() _showShortcutHelp;

  @override
  bool get canBack => router.canPop();

  @override
  void go(String location) => router.go(location);

  @override
  void back() {
    if (router.canPop()) router.pop();
  }

  @override
  void focusSearch() {
    router.go('/search');
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => searchFocusController.requestFocus(),
    );
  }

  @override
  Future<void> showShortcutHelp() => _showShortcutHelp();
}

bool shouldLockForBiometricLifecycleState(AppLifecycleState state) {
  return state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
}
