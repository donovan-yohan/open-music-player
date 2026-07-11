import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';

void main() {
  test('key notation defaults and migrates to Camelot', () {
    expect(const SettingsModel().keyNotation, KeyNotation.camelot);
    expect(SettingsModel.fromJson(const {}).keyNotation, KeyNotation.camelot);
  });

  test('key notation persists by stable enum name', () {
    final model = SettingsModel.fromJson(const {'keyNotation': 'musical'});

    expect(model.keyNotation, KeyNotation.musical);
    expect(model.toJson()['keyNotation'], 'musical');
  });

  test('settings notifier persists key notation locally', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final notifier = SettingsNotifier(preferences);

    notifier.setKeyNotation(KeyNotation.musical);
    await Future<void>.delayed(Duration.zero);

    final saved = jsonDecode(preferences.getString('app_settings')!)
        as Map<String, dynamic>;
    expect(saved['keyNotation'], 'musical');
  });
}
