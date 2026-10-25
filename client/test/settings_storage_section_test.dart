import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_playback_cache_store.dart';

void main() {
  testWidgets('logout cache option is honestly disabled without a manager',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogoutOptionsDialog(
          cacheManager: null,
          onConfirm: () async {},
        ),
      ),
    );

    final option = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(option.onChanged, isNull);
    expect(
      find.text(
        'Temporary playback audio is unavailable on this platform.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('storage confirms a complete clear and refreshes cache size',
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
    expect(find.text('Cache cleared'), findsOneWidget);
  });

  testWidgets(
      'clear defers leased audio and refreshes size including retired bytes',
      (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory =
          await Directory.systemTemp.createTemp('settings_cache_clear_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = FakePlaybackCacheStore();
      final cache = PlaybackCacheManager(
        store: store,
        cacheDirectoryProvider: () async => directory.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(2048, 1));
        },
      );
      SignedAudioDescriptor audio(String version) => SignedAudioDescriptor(
            trackId: 1,
            url: 'https://objects.example/1?signature=$version',
            expiresAt: DateTime.utc(2030),
            storageKeyVersion: version,
            sizeBytes: 2048,
          );
      final lease = (await cache.warmAndAcquire(1, audio('v1')))!;
      await cache.warm(1, audio('v2'));

      await tester.pumpWidget(
        _testApp(preferences: preferences, cache: cache),
      );
      await cache.currentSizeBytes();
      await tester.pumpAndSettle();
      expect(find.text('4.0 KB'), findsOneWidget);

      await _clearCache(tester, cache);

      expect(
        find.text('In-use audio will clear after playback releases it'),
        findsOneWidget,
      );
      expect(find.text('Cache cleared'), findsNothing);
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(store.entries, isEmpty);
      expect(await File(lease.localPath).exists(), isTrue);

      await lease.release();
      expect(await File(lease.localPath).exists(), isFalse);
      ScaffoldMessenger.of(tester.element(find.byType(SettingsStorageSection)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await _clearCache(tester, cache);
      expect(find.text('0 B'), findsOneWidget);
      expect(find.text('Cache cleared'), findsOneWidget);
    });
  });

  testWidgets('clear reports a cancelled transfer that is still finishing',
      (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final directory =
          await Directory.systemTemp.createTemp('settings_cache_transfer_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final started = Completer<void>();
      final finish = Completer<void>();
      final store = FakePlaybackCacheStore();
      final cache = PlaybackCacheManager(
        store: store,
        cacheDirectoryProvider: () async => directory.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          started.complete();
          // Model a downloader that has not yet acknowledged cancellation.
          await finish.future;
          await File(path).writeAsBytes([1]);
        },
      );
      final transfer = cache.warm(
        1,
        SignedAudioDescriptor(
          trackId: 1,
          url: 'https://objects.example/1',
          expiresAt: DateTime.utc(2030),
          sizeBytes: 1,
        ),
      );
      await started.future;
      await tester.pumpWidget(
        _testApp(preferences: preferences, cache: cache),
      );
      await cache.currentSizeBytes();
      await tester.pumpAndSettle();

      await _clearCache(tester, cache);

      expect(find.text('Cache clearing is finishing'), findsOneWidget);
      expect(find.text('Cache cleared'), findsNothing);
      expect(find.text('0 B'), findsOneWidget);
      finish.complete();
      await transfer;
      expect(store.entries, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    });
  });

  for (final deferred in [false, true]) {
    testWidgets(
        'clear reports deletion failures${deferred ? ' ahead of deferred files and transfers' : ''}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final cache = _PlaybackCacheManager()
        ..size = 4096
        ..sizeAfterClear = 2048
        ..result = PlaybackCacheClearResult(
          deferredFiles: deferred ? 1 : 0,
          deferredBytes: deferred ? 1024 : 0,
          failedFiles: 1,
          pendingTransfers: deferred ? 1 : 0,
        );
      await tester.pumpWidget(
        _testApp(preferences: preferences, cache: cache),
      );
      await tester.pumpAndSettle();
      expect(find.text('4.0 KB'), findsOneWidget);

      await _clearCache(tester, cache);

      expect(
          find.text('Some cached audio could not be removed'), findsOneWidget);
      expect(find.text('Cache cleared'), findsNothing);
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(cache.clearCalls, 1);
    });
  }

  testWidgets('storage is honestly unavailable without a cache manager',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      _testApp(preferences: preferences, cache: null),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unavailable on this platform'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('settings_clear_cache')),
          )
          .onPressed,
      isNull,
    );
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

Future<void> _clearCache(
  WidgetTester tester,
  PlaybackCacheManager cache,
) async {
  await tester.tap(find.byKey(const ValueKey('settings_clear_cache')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Clear'),
    ),
  );
  await cache.currentSizeBytes();
  await tester.pumpAndSettle();
}

Widget _testApp({
  required SharedPreferences preferences,
  required PlaybackCacheManager? cache,
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
  int sizeAfterClear = 0;
  PlaybackCacheClearResult result =
      const PlaybackCacheClearResult(deferredFiles: 0, deferredBytes: 0);

  @override
  Future<int> currentSizeBytes() async => size;

  @override
  Future<PlaybackCacheClearResult> clear() async {
    clearCalls++;
    size = sizeAfterClear;
    return result;
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
