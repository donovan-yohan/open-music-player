import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('storage reads and clears the real playback cache manager',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final cache = _PlaybackCacheManager()..size = 2048;

    await tester.pumpWidget(
      _testApp(preferences: preferences, cache: cache),
    );
    await tester.pumpAndSettle();

    expect(find.text('2.0 KB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings_clear_cache')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Clear'),
      ),
    );
    await tester.pumpAndSettle();

    expect(cache.clearCalls, 1);
    expect(find.text('0 B'), findsOneWidget);
  });

  testWidgets('Downloads tile navigates to the real route', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      _testApp(
        preferences: preferences,
        cache: _PlaybackCacheManager(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    expect(find.text('Real downloads screen'), findsOneWidget);
  });
}

Widget _testApp({
  required SharedPreferences preferences,
  required PlaybackCacheManager cache,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: SettingsStorageSection()),
      ),
      GoRoute(
        path: '/downloads',
        builder: (_, __) => const Scaffold(
          body: Text('Real downloads screen'),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    child: provider.MultiProvider(
      providers: [
        provider.Provider<PlaybackCacheManager?>.value(value: cache),
        provider.ListenableProvider<DownloadState>.value(
          value: _DownloadState(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

class _PlaybackCacheManager extends Fake implements PlaybackCacheManager {
  int size = 0;
  int clearCalls = 0;

  @override
  Future<int> currentSizeBytes() async => size;

  @override
  Future<void> clear() async {
    clearCalls++;
    size = 0;
  }
}

class _DownloadState extends Fake implements DownloadState {
  @override
  String get formattedTotalSize => '0 B';

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
