import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../features/desktop/desktop_listening_shell.dart';
import '../features/desktop/desktop_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_state.dart';
import '../features/connect/connected_devices_screen.dart';
import '../features/jam/jam_route_screen.dart';
import '../core/commands/search_focus_controller.dart';
import '../core/providers/settings_provider.dart';
import '../features/auth/screens/biometric_unlock_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/register_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/home/home_screen.dart';
import '../features/search/search_screen.dart';
import '../features/library/library_screen.dart';
import '../features/library/local_browse_navigation.dart';
import '../features/settings/settings_screen.dart';
import '../features/player/player_screen.dart';
import '../features/dj/dj_screen.dart';
import '../features/dj_session/dj_session_screen.dart';
import '../features/player/widgets/mini_player.dart';
import '../features/share/share_import_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/playlists/playlists_screen.dart';
import '../features/playlists/mix/desktop_mix_editor_screen.dart';
import '../features/playlists/playlist_detail_screen.dart';
import '../features/playlists/playlist_import_progress_screen.dart';
import '../core/models/playlist_import.dart';
import '../screens/queue_screen.dart';
import 'theme.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

GoRouter createRouter(
  AuthState authState, {
  SearchFocusController? searchFocusController,
}) {
  final mixEditorKey = GlobalKey<DesktopMixEditorScreenState>();
  final rootRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    observers: [rootRouteObserver],
    initialLocation: _initialRoute,
    refreshListenable: authState,
    redirect: (context, state) => _authRedirect(authState, state),
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
      GoRoute(
        path: '/unlock',
        builder: (context, state) => const BiometricUnlockScreen(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/player',
        pageBuilder: (context, state) =>
            MediaQuery.disableAnimationsOf(context) ||
                    MediaQuery.accessibleNavigationOf(context)
                ? const NoTransitionPage<void>(child: PlayerScreen())
                : CustomTransitionPage<void>(
                    transitionDuration: const Duration(milliseconds: 240),
                    reverseTransitionDuration:
                        const Duration(milliseconds: 180),
                    child: const PlayerScreen(),
                    transitionsBuilder:
                        (context, animation, secondaryAnimation, child) {
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                        child: child,
                      );
                    },
                  ),
      ),
      GoRoute(
        path: '/dj',
        // The deck allocates two Voices outside QueueTimelineController the
        // moment it mounts, so the ADR 0001 addendum scopes that exception to a
        // user-controlled switch. Gating only the app-bar button would leave the
        // route reachable by URL, restored route state, or any later
        // context.go('/dj') — so the gate has to live on the route itself.
        redirect: (context, state) =>
            djModeEnabledForRouting(context) ? null : '/player',
        builder: (context, state) => const DjScreen(),
      ),
      GoRoute(
        path: '/dj-session',
        // Discovery and queue mutations are canonical, but the surface remains
        // an intentional DJ-mode feature while it is being iterated.
        redirect: (context, state) =>
            djModeEnabledForRouting(context) ? null : '/player',
        builder: (context, state) => const DjSessionScreen(),
      ),
      GoRoute(
        path: '/downloads',
        builder: (context, state) => const DownloadsScreen(),
      ),
      GoRoute(
        path: '/devices',
        builder: (context, state) =>
            ConnectedDevicesScreen(routeObserver: rootRouteObserver),
      ),
      GoRoute(
        path: '/jam',
        builder: (context, state) =>
            JamRouteScreen(routeObserver: rootRouteObserver),
      ),
      GoRoute(
        path: '/share',
        builder: (context, state) => ShareImportScreen(
          sharedText: state.uri.queryParameters['text'] ?? '',
          autoSubmit: state.uri.queryParameters['auto'] == '1',
        ),
      ),
      GoRoute(
        path: '/mixes',
        builder: (context, state) => const DesktopMixEditorPicker(),
      ),
      GoRoute(
        path: '/mixes/:id',
        onExit: (_) async =>
            await mixEditorKey.currentState?.confirmExit() ?? true,
        builder: (context, state) => DesktopMixEditorScreen(
          key: mixEditorKey,
          planId: state.pathParameters['id']!,
        ),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          return ScaffoldWithNavBar(child: child);
        },
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => NoTransitionPage(
              child: SearchScreen(
                commandFocusController: searchFocusController,
              ),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: LibraryScreen()),
          ),
          ...localBrowseRoutes(),
          GoRoute(
            path: '/playlists',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: PlaylistsScreen()),
          ),
          GoRoute(
            path: '/playlists/import',
            pageBuilder: (context, state) => NoTransitionPage(
              child: PlaylistImportProgressScreen(
                importJobId: state.uri.queryParameters['importJobId'],
                initialStatus: state.extra is PlaylistImportStatus
                    ? state.extra as PlaylistImportStatus
                    : null,
              ),
            ),
          ),
          GoRoute(
            path: '/playlists/:id',
            pageBuilder: (context, state) {
              final id = int.parse(state.pathParameters['id']!);
              return NoTransitionPage(
                child: PlaylistDetailScreen(playlistId: id),
              );
            },
          ),
          GoRoute(
            path: '/queue',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: QueueScreen()),
          ),
          GoRoute(
            path: '/queue/imports',
            pageBuilder: (context, state) => const NoTransitionPage(
                child: QueueScreen(showImportJobs: true)),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: SettingsScreen()),
          ),
        ],
      ),
    ],
  );
}

String? _authRedirect(AuthState authState, GoRouterState state) {
  final path = state.uri.path;
  const publicPaths = {'/', '/unlock', '/login', '/register', '/share'};
  final isPublicPath = publicPaths.contains(path);

  if (authState.isBiometricLocked && path != '/unlock') {
    final next = Uri.encodeComponent(state.uri.toString());
    return '/unlock?next=$next';
  }

  if (!authState.hasLocalSession && path == '/unlock') {
    return '/login';
  }

  if (!authState.hasLocalSession && !isPublicPath) {
    final next = Uri.encodeComponent(state.uri.toString());
    return '/login?next=$next';
  }

  if (authState.isAuthenticated && (path == '/login' || path == '/register')) {
    return safeLoginRedirectNext(state.uri.queryParameters['next']) ?? '/home';
  }

  return null;
}

@visibleForTesting
String? safeLoginRedirectNext(String? next) {
  if (next == null || next.isEmpty) return null;
  if (!next.startsWith('/') || next.startsWith('//')) return null;
  final uri = Uri.tryParse(next);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  if (uri.path == '/login' || uri.path == '/register') return null;
  return next;
}

String get _initialRoute {
  // Native Uri.base is the working directory, not an app route. GoRouter still
  // gives platform deep links precedence over this fallback initial location.
  if (!kIsWeb) return '/';
  final path = Uri.base.path;
  return path.isEmpty ? '/' : path;
}

class ScaffoldWithNavBar extends StatelessWidget {
  const ScaffoldWithNavBar({
    super.key,
    required this.child,
    this.miniPlayer,
  });

  final Widget child;

  /// Optional chrome override for embedded/test shells. Production selects the
  /// mobile mini-player or desktop transport without changing playback owners.
  final Widget? miniPlayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 960) {
          return _MobileShell(
            miniPlayer: miniPlayer ?? const MiniPlayer(),
            selectedIndex: _calculateSelectedIndex(context),
            onDestinationSelected: (index) => _onItemTapped(index, context),
            child: child,
          );
        }
        return Theme(
          data: AppTheme.darkTheme,
          child: DesktopListeningShell(
            miniPlayer: miniPlayer ?? const DesktopTransport(),
            compact: constraints.maxWidth < 1200,
            selectedIndex:
                GoRouterState.of(context).uri.path.startsWith('/queue/imports')
                    ? 7
                    : _calculateSelectedIndex(context),
            onDestinationSelected: (index) => _onItemTapped(index, context),
            child: child,
          ),
        );
      },
    );
  }

  int _calculateSelectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    if (location.startsWith('/home')) return 0;
    if (location.startsWith('/search')) return 1;
    if (location.startsWith('/library')) return 2;
    if (location.startsWith('/playlists')) return 3;
    if (location.startsWith('/queue')) return 4;
    if (location.startsWith('/settings')) return 5;
    return 0;
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        context.go('/home');
        break;
      case 1:
        context.go('/search');
        break;
      case 2:
        context.go('/library');
        break;
      case 3:
        context.go('/playlists');
        break;
      case 4:
        context.go('/queue');
        break;
      case 5:
        context.go('/settings');
        break;
      case 6:
        context.push('/mixes');
        break;
      case 7:
        context.go('/queue/imports');
        break;
      case 8:
        context.push('/downloads');
        break;
      case 9:
        context.push('/devices');
        break;
      case 10:
        context.push('/jam');
        break;
    }
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.child,
    required this.miniPlayer,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final Widget child;
  final Widget miniPlayer;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('soundq_mobile_shell'),
      body: Column(children: [Expanded(child: child), miniPlayer]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Discover',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.playlist_play_outlined),
            selectedIcon: Icon(Icons.playlist_play),
            label: 'Playlists',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Whether the experimental DJ deck may be entered.
///
/// Falls back to closed when there is no ProviderScope: a harness that builds
/// the router without app settings has no recorded opt-in, and an experimental
/// surface must not open itself by default.
@visibleForTesting
bool djModeEnabledForRouting(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .djModeEnabled;
  } catch (_) {
    return false;
  }
}
