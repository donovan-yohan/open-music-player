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

  EndOfQueueMode? storedMode(SharedPreferences preferences) {
    final raw = preferences.getString('app_settings');
    if (raw == null) return null;
    return SettingsModel.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    ).endOfQueueMode;
  }

  testWidgets('end-of-queue defaults to off so playback still stops',
      (tester) async {
    final preferences = await pumpPlaybackSettings(tester);

    expect(find.text('End of queue'), findsOneWidget);
    expect(
      find.textContaining('Off · Playback stops when the queue runs out'),
      findsOneWidget,
    );
    // Nothing has been chosen, so nothing has been written.
    expect(storedMode(preferences), isNull);
  });

  testWidgets('choosing shuffle library persists the choice', (tester) async {
    final preferences = await pumpPlaybackSettings(tester);

    await tester.tap(find.byKey(const ValueKey('settings_end_of_queue')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings_end_of_queue_shuffleLibrary')),
    );
    await tester.pumpAndSettle();

    expect(storedMode(preferences), EndOfQueueMode.shuffleLibrary);
    expect(
      find.textContaining(
        'Shuffle library · Keep playing shuffled tracks from your library',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a persisted choice is restored into the control',
      (tester) async {
    final preferences = await pumpPlaybackSettings(
      tester,
      initialValues: {
        'app_settings': jsonEncode(
          const SettingsModel(endOfQueueMode: EndOfQueueMode.shuffleLibrary)
              .toJson(),
        ),
      },
    );

    expect(
      find.textContaining('Shuffle library ·'),
      findsOneWidget,
    );
    expect(storedMode(preferences), EndOfQueueMode.shuffleLibrary);

    // And it can be turned back off, restoring the pre-#352 behavior.
    await tester.tap(find.byKey(const ValueKey('settings_end_of_queue')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings_end_of_queue_off')),
    );
    await tester.pumpAndSettle();

    expect(storedMode(preferences), EndOfQueueMode.off);
  });

  testWidgets('only implemented modes are offered', (tester) async {
    await pumpPlaybackSettings(tester);

    await tester.tap(find.byKey(const ValueKey('settings_end_of_queue')));
    await tester.pumpAndSettle();

    // Phase 2's similar-track radio has no source yet, so it must not be
    // selectable — an option the playback core cannot honor is worse than an
    // option that is not offered.
    expect(find.byType(RadioListTile<EndOfQueueMode>), findsNWidgets(2));
    expect(find.textContaining('radio', findRichText: true), findsNothing);
  });
}
