import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> pumpPlaybackSettings(
    WidgetTester tester, {
    Map<String, Object> initialValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SettingsPlaybackSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return preferences;
  }

  SettingsModel? stored(SharedPreferences preferences) {
    final raw = preferences.getString('app_settings');
    if (raw == null) return null;
    return SettingsModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  testWidgets('swipe-to-queue shows the historical behavior until changed',
      (tester) async {
    final preferences = await pumpPlaybackSettings(tester);

    expect(
      find.textContaining(
        'Add to queue · Queue after anything you have already queued',
      ),
      findsOneWidget,
    );
    expect(stored(preferences), isNull);

    await tester.tap(find.byKey(const ValueKey('settings_swipe_queue_mode')));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<QueueInsertMode>), findsNWidgets(2));

    await tester.tap(
      find.byKey(const ValueKey('settings_swipe_queue_mode_playNext')),
    );
    await tester.pumpAndSettle();

    expect(stored(preferences)?.swipeQueueMode, QueueInsertMode.playNext);
    expect(find.textContaining('Play next ·'), findsOneWidget);
  });

  testWidgets('keeping queued songs is on by default and can be turned off',
      (tester) async {
    final preferences = await pumpPlaybackSettings(tester);

    final toggle = find.byKey(const ValueKey('settings_preserve_manual_queue'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(stored(preferences)?.preserveManualQueue, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('a persisted choice is restored into the controls',
      (tester) async {
    await pumpPlaybackSettings(
      tester,
      initialValues: {
        'app_settings': jsonEncode(
          const SettingsModel(
            swipeQueueMode: QueueInsertMode.playNext,
            preserveManualQueue: false,
          ).toJson(),
        ),
      },
    );

    expect(find.textContaining('Play next ·'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('settings_preserve_manual_queue')),
          )
          .value,
      isFalse,
    );
  });
}
