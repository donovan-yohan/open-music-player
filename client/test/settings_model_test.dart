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

  test('legacy quality and gapless keys are tolerated then removed', () {
    final model = SettingsModel.fromJson(const {
      'streamingQuality': 0,
      'downloadQuality': 1,
      'gaplessPlayback': false,
      'crossfadeDuration': 4,
    });

    expect(model.crossfadeDuration, 4);
    expect(model.toJson(), isNot(contains('gaplessPlayback')));
    expect(model.toJson(), isNot(contains('streamingQuality')));
    expect(model.toJson(), isNot(contains('downloadQuality')));
  });

  test(
      'settings notifier loads JSON containing legacy quality and gapless keys',
      () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({
        'streamingQuality': 0,
        'downloadQuality': 2,
        'gaplessPlayback': false,
        'crossfadeDuration': 6,
      }),
    });
    final preferences = await SharedPreferences.getInstance();

    final notifier = SettingsNotifier(preferences);

    expect(notifier.state.crossfadeDuration, 6);
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
