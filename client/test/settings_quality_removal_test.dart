import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'settings screen has no streaming or download quality selectors',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'OMP',
        packageName: 'com.openmusicplayer.app',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
          child: provider.MultiProvider(
            providers: [
              provider.ListenableProvider<AuthState>.value(value: _AuthState()),
              provider.Provider<PlaybackCacheManager?>.value(value: null),
              provider.ListenableProvider<DownloadState>.value(
                value: _DownloadState(),
              ),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Streaming quality'), findsNothing);
      expect(find.text('Download quality'), findsNothing);
      expect(find.textContaining('Always 320'), findsNothing);
      expect(find.byType(RadioListTile), findsNothing);
      expect(find.text('Gapless playback'), findsNothing);
      expect(find.text('Crossfade'), findsOneWidget);
    },
  );
}

class _AuthState extends Fake implements AuthState {
  @override
  bool get hasLocalSession => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _DownloadState extends Fake implements DownloadState {
  @override
  String get formattedTotalSize => '0 B';

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
