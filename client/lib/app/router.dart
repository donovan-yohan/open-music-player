import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_state.dart';
import '../core/commands/search_focus_controller.dart';
import '../features/auth/screens/biometric_unlock_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/register_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/home/home_screen.dart';
import '../features/search/search_screen.dart';
import '../features/library/library_screen.dart';
import '../features/library/local_browse_screens.dart';
import '../features/settings/settings_screen.dart';
import '../features/player/player_screen.dart';
import '../features/player/widgets/mini_player.dart';
import '../features/share/share_import_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/playlists/playlists_screen.dart';
import '../features/playlists/playlist_detail_screen.dart';
import '../features/playlists/playlist_import_screen.dart';
import '../screens/queue_screen.dart';
import 'theme.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

GoRouter createRouter(
  AuthState authState, {
  SearchFocusController? searchFocusController,
}) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
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
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const PlayerScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
        path: '/downloads',
        builder: (context, state) => const DownloadsScreen(),
      ),
      GoRoute(
        path: '/share',
        builder: (context, state) => ShareImportScreen(
          sharedText: state.uri.queryParameters['text'] ?? '',
          autoSubmit: state.uri.queryParameters['auto'] == '1',
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
          GoRoute(
            path: '/library/artist/:name',
            pageBuilder: (context, state) => NoTransitionPage(
              child: LocalArtistScreen(
                artist: Uri.decodeComponent(state.pathParameters['name']!),
              ),
            ),
          ),
          GoRoute(
            path: '/library/album/:name',
            pageBuilder: (context, state) => NoTransitionPage(
              child: LocalAlbumScreen(
                album: Uri.decodeComponent(state.pathParameters['name']!),
              ),
            ),
          ),
          GoRoute(
            path: '/playlists',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: PlaylistsScreen()),
          ),
          GoRoute(
            path: '/playlists/import',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: PlaylistImportScreen()),
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
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: QueueScreen(showImportJobs: true)),
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
  final path = Uri.base.path;
  return path.isEmpty ? '/' : path;
}

class ScaffoldWithNavBar extends StatelessWidget {
  const ScaffoldWithNavBar({
    super.key,
    required this.child,
    this.miniPlayer = const MiniPlayer(),
  });

  final Widget child;
  final Widget miniPlayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 960) {
          return _MobileShell(
            miniPlayer: miniPlayer,
            selectedIndex: _calculateSelectedIndex(context),
            onDestinationSelected: (index) => _onItemTapped(index, context),
            child: child,
          );
        }
        return Theme(
          data: AppTheme.darkTheme,
          child: _DesktopShell(
            miniPlayer: miniPlayer,
            compact: constraints.maxWidth < 1200,
            selectedIndex: _calculateSelectedIndex(context),
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
    if (location.startsWith('/library') || location.startsWith('/playlists')) {
      return 2;
    }
    if (location.startsWith('/queue')) return 3;
    if (location.startsWith('/settings')) return 4;
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
        context.go('/queue');
        break;
      case 4:
        context.go('/settings');
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
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
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

class _DesktopShell extends StatefulWidget {
  const _DesktopShell({
    required this.child,
    required this.miniPlayer,
    required this.compact,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final Widget child;
  final Widget miniPlayer;
  final bool compact;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<_DesktopShell> {
  final FocusNode _shellFocusNode = FocusNode(
    debugLabel: 'Sound Q desktop shell',
    skipTraversal: true,
  );
  late final List<FocusNode> _destinationFocusNodes = List.generate(
    5,
    (index) => FocusNode(debugLabel: 'Sound Q destination $index'),
  );

  @override
  void dispose() {
    _shellFocusNode.dispose();
    for (final node in _destinationFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final railWidth = widget.compact ? 80.0 : 224.0;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.tab):
            _FocusDesktopNavigationIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _FocusDesktopNavigationIntent:
              CallbackAction<_FocusDesktopNavigationIntent>(
            onInvoke: (_) {
              final focusedIndex = _destinationFocusNodes.indexWhere(
                (node) => node.hasFocus,
              );
              if (focusedIndex < 0) {
                _destinationFocusNodes.first.requestFocus();
              } else {
                _destinationFocusNodes[focusedIndex].nextFocus();
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          focusNode: _shellFocusNode,
          child: Scaffold(
            key: const ValueKey('soundq_desktop_shell'),
            body: Row(
              children: [
                SizedBox(
                  key: const ValueKey('soundq_desktop_rail_container'),
                  width: railWidth,
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: NavigationRail(
                      key: const ValueKey('soundq_desktop_navigation_rail'),
                      extended: !widget.compact,
                      selectedIndex: widget.selectedIndex,
                      labelType: NavigationRailLabelType.none,
                      leading: Padding(
                        padding: const EdgeInsets.only(top: 20, bottom: 20),
                        child: Image.asset(
                          'assets/brand/soundq-logo.png',
                          width: widget.compact ? 36 : 44,
                          height: widget.compact ? 36 : 44,
                          semanticLabel: 'Sound Q',
                        ),
                      ),
                      trailing: widget.compact
                          ? null
                          : const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('SOUND Q', maxLines: 1),
                            ),
                      onDestinationSelected: widget.onDestinationSelected,
                      destinations: [
                        NavigationRailDestination(
                          icon: _DesktopRailIcon(
                            index: 0,
                            icon: Icons.home_outlined,
                            focusNode: _destinationFocusNodes[0],
                            onActivate: widget.onDestinationSelected,
                          ),
                          selectedIcon: _DesktopRailIcon(
                            index: 0,
                            icon: Icons.home,
                            focusNode: _destinationFocusNodes[0],
                            onActivate: widget.onDestinationSelected,
                          ),
                          label: const Text('Home'),
                        ),
                        NavigationRailDestination(
                          icon: _DesktopRailIcon(
                            index: 1,
                            icon: Icons.search_outlined,
                            focusNode: _destinationFocusNodes[1],
                            onActivate: widget.onDestinationSelected,
                          ),
                          selectedIcon: _DesktopRailIcon(
                            index: 1,
                            icon: Icons.search,
                            focusNode: _destinationFocusNodes[1],
                            onActivate: widget.onDestinationSelected,
                          ),
                          label: const Text('Search'),
                        ),
                        NavigationRailDestination(
                          icon: _DesktopRailIcon(
                            index: 2,
                            icon: Icons.library_music_outlined,
                            focusNode: _destinationFocusNodes[2],
                            onActivate: widget.onDestinationSelected,
                          ),
                          selectedIcon: _DesktopRailIcon(
                            index: 2,
                            icon: Icons.library_music,
                            focusNode: _destinationFocusNodes[2],
                            onActivate: widget.onDestinationSelected,
                          ),
                          label: const Text('Library'),
                        ),
                        NavigationRailDestination(
                          icon: _DesktopRailIcon(
                            index: 3,
                            icon: Icons.queue_music_outlined,
                            focusNode: _destinationFocusNodes[3],
                            onActivate: widget.onDestinationSelected,
                          ),
                          selectedIcon: _DesktopRailIcon(
                            index: 3,
                            icon: Icons.queue_music,
                            focusNode: _destinationFocusNodes[3],
                            onActivate: widget.onDestinationSelected,
                          ),
                          label: const Text('Queue'),
                        ),
                        NavigationRailDestination(
                          icon: _DesktopRailIcon(
                            index: 4,
                            icon: Icons.settings_outlined,
                            focusNode: _destinationFocusNodes[4],
                            onActivate: widget.onDestinationSelected,
                          ),
                          selectedIcon: _DesktopRailIcon(
                            index: 4,
                            icon: Icons.settings,
                            focusNode: _destinationFocusNodes[4],
                            onActivate: widget.onDestinationSelected,
                          ),
                          label: const Text('Settings'),
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: widget.child),
                      widget.miniPlayer,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusDesktopNavigationIntent extends Intent {
  const _FocusDesktopNavigationIntent();
}

class _DesktopRailIcon extends StatefulWidget {
  const _DesktopRailIcon({
    required this.index,
    required this.icon,
    required this.focusNode,
    required this.onActivate,
  });

  final int index;
  final IconData icon;
  final FocusNode focusNode;
  final ValueChanged<int> onActivate;

  @override
  State<_DesktopRailIcon> createState() => _DesktopRailIconState();
}

class _DesktopRailIconState extends State<_DesktopRailIcon> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.index.toDouble()),
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onActivate(widget.index);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: AnimatedContainer(
          key: ValueKey('soundq_desktop_nav_focus_${widget.index}'),
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
              color: _focused ? colors.primary : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(widget.icon),
        ),
      ),
    );
  }
}
