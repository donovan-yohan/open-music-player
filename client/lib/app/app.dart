import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/api/api_client.dart';
import '../core/audio/playback_state.dart';
import '../core/auth/auth_state.dart';
import '../core/connect/connect_service.dart';
import '../core/connect/device_presence_service.dart';
import '../core/jam/jam_host_controller.dart';
import '../core/jam/jam_playback_admission.dart';
import '../core/jam/jam_service.dart';
import '../core/storage/secure_storage.dart';
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
import '../shared/widgets/app_snack_bar.dart';

class OpenMusicPlayerApp extends ConsumerStatefulWidget {
  final ApiClient apiClient;
  final AuthState authState;
  final PlaybackState playbackState;
  final GoRouter router;
  final SharedIntentReceiver sharedIntentReceiver;
  final SearchFocusController searchFocusController;

  /// Production supplies the canonical retirement barrier from main.
  final Future<void> Function()? playbackAccountRetirement;

  factory OpenMusicPlayerApp({
    Key? key,
    required ApiClient apiClient,
    required AuthState authState,
    required PlaybackState playbackState,
    SharedIntentReceiver? sharedIntentReceiver,
    Future<void> Function()? playbackAccountRetirement,
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
      playbackAccountRetirement: playbackAccountRetirement,
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
    required this.playbackAccountRetirement,
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
  late final ConnectService _connectService;
  late final DevicePresenceService _presence;
  int? _connectRevision;
  AuthSessionScope? _connectScope;
  Object? _connectAdmission;
  JamHostController? _jamHost;

  JamHostController _createJamHost() {
    final service = JamService(widget.apiClient);
    return _jamHost ??= JamHostController(
      service: service,
      presence: _presence,
      source: widget.playbackState.snapshotStream,
      canonicalSessionGeneration: () => widget.playbackState.sessionGeneration,
      accountChanges: widget.authState,
      accountRevision: () => widget.authState.sessionRevision,
      admit: canonicalJamAdmission(
          playback: widget.playbackState, service: service),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectService = ConnectService(widget.apiClient);
    _presence = DevicePresenceService(
      _connectService,
      label: kIsWeb ? 'SoundQ browser' : 'SoundQ ${defaultTargetPlatform.name}',
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase(),
    );
    _presence.setActive(
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached);
    widget.authState.addListener(_handleAuthStateChanged);
    _syncConnectSession();
    _commandRegistry = CommandRegistry(playbackState: widget.playbackState);
    _startShareIntentListener();
    final settings = ref.read(settingsProvider);
    _applyCrossfadeDuration(settings.crossfadeDuration);
    widget.playbackState.setEndOfQueueMode(settings.endOfQueueMode);
    widget.playbackState.setSwipeQueueMode(settings.swipeQueueMode);
    widget.playbackState.setPreserveManualQueue(settings.preserveManualQueue);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.authState.removeListener(_handleAuthStateChanged);
    _connectAdmission = null;
    _jamHost?.dispose();
    _presence.dispose();
    _sharedTextSubscription?.cancel();
    _commandRegistry.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Window focus and UI visibility do not determine whether audio is alive.
    // Paused mobile processes keep best-effort heartbeats while Dart can run;
    // hard suspension is bounded by the server lease rather than a UI clock.
    _presence.setActive(state != AppLifecycleState.detached);
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
    ref.listen<EndOfQueueMode>(
      settingsProvider.select((settings) => settings.endOfQueueMode),
      (_, mode) => widget.playbackState.setEndOfQueueMode(mode),
    );
    ref.listen<QueueInsertMode>(
      settingsProvider.select((settings) => settings.swipeQueueMode),
      (_, mode) => widget.playbackState.setSwipeQueueMode(mode),
    );
    ref.listen<bool>(
      settingsProvider.select((settings) => settings.preserveManualQueue),
      (_, preserve) => widget.playbackState.setPreserveManualQueue(preserve),
    );
    final settings = ref.watch(settingsProvider);

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: widget.apiClient),
        Provider<ConnectService>.value(value: _connectService),
        // Created on first use, retained above routes until application teardown.
        // Screen owns its AnimatedBuilder subscription. Merely exposing this
        // app-owned capability must not subscribe ancestors during route init.
        InheritedProvider<JamHostController>(create: (_) => _createJamHost()),
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
            child: AppFeedbackTheme(child: child ?? const SizedBox.shrink()),
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
    _syncConnectSession();
    if (!mounted || _isAuthCheckInFlight) return;
    final sharedText = _pendingSharedText;
    if (sharedText == null) return;

    _pendingSharedText = null;
    _goToShareImport(sharedText);
  }

  void _syncConnectSession() {
    final auth = widget.authState;
    // Unauthenticated harnesses need neither playback nor revision access.
    if (!auth.isAuthenticated) {
      // Local biometric UI locking is not credential revocation: background
      // playback keeps the admitted lease, but a locked startup cannot attach.
      if (_connectScope != null &&
          auth.isBiometricLocked &&
          _connectRevision == auth.sessionRevision) {
        return;
      }
      _connectAdmission = null;
      if (_connectScope != null) _presence.detach();
      _connectRevision = null;
      _connectScope = null;
      return;
    }
    if (_connectRevision != auth.sessionRevision) {
      _connectAdmission = null;
      _presence.detach();
      _connectScope = null;
      _connectRevision = auth.sessionRevision;
    }
    if (auth.isLoading) return;
    final attached = _connectScope;
    if (attached != null) {
      if (!widget.apiClient.acceptsAuthSession(attached)) _presence.detach();
      return;
    }
    final scope = widget.apiClient.captureAuthSession();
    if (!widget.apiClient.acceptsAuthSession(scope)) return;
    if (_connectAdmission != null) return;
    final admission = Object();
    final revision = auth.sessionRevision;
    _connectAdmission = admission;
    unawaited(() async {
      try {
        await widget.playbackAccountRetirement?.call();
        if (!mounted ||
            !identical(_connectAdmission, admission) ||
            revision != auth.sessionRevision ||
            !auth.isAuthenticated ||
            auth.isLoading ||
            !widget.apiClient.acceptsAuthSession(scope)) {
          return;
        }
        _connectScope = scope;
        _presence.attach(widget.playbackState.snapshotStream, scope);
      } catch (error) {
        debugPrint('Connect playback admission blocked: $error');
      } finally {
        if (identical(_connectAdmission, admission)) _connectAdmission = null;
      }
    }());
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
