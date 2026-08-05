import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';

void main() {
  test('click audition settings have safe local defaults', () {
    const model = SettingsModel();

    expect(model.clickAuditionVolume, defaultClickAuditionVolume);
    expect(model.clickAuditionDownbeatAccentEnabled, isTrue);
    expect(
      model.clickAuditionOutputOffsets.asMap,
      {
        'bluetooth': 0,
        'wired': 0,
        'speaker': 0,
        'other': 0,
        'unknown': 0,
      },
    );
    expect(model.toJson(), isNot(contains('clickAuditionEnabled')));
  });

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

  test('click audition JSON is canonical and tolerates malformed values', () {
    final model = SettingsModel.fromJson(const {
      'crossfadeDuration': 'not-a-number',
      'themeMode': 99,
      'clickAuditionVolume': '1.25',
      'clickAuditionDownbeatAccentEnabled': 'false',
      'clickAuditionOutputOffsetsMs': {
        'bluetooth': 900,
        'wired': '-900',
        'speaker': 'invalid',
        'other': 12.6,
        'unknown': null,
        'future-route': 321,
      },
    });

    expect(model.crossfadeDuration, 0);
    expect(model.themeMode, AppThemeMode.system);
    expect(model.clickAuditionVolume, 1);
    expect(model.clickAuditionDownbeatAccentEnabled, isFalse);
    expect(
      model.clickAuditionOutputOffsets.asMap,
      {
        'bluetooth': maxClickAuditionOutputOffsetMs,
        'wired': minClickAuditionOutputOffsetMs,
        'speaker': 0,
        'other': 13,
        'unknown': 0,
      },
    );
    expect(
      model.toJson()['clickAuditionOutputOffsetsMs'],
      model.clickAuditionOutputOffsets.asMap,
    );
  });

  test('route offset copies preserve other routes and expose no mutable map',
      () {
    final original = ClickAuditionOutputOffsets(
      bluetooth: 900,
      wired: -900,
    );
    final changed = original.withOffset(
      ClickAuditionOutputRoute.speaker,
      750,
    );

    expect(changed.bluetooth, maxClickAuditionOutputOffsetMs);
    expect(changed.wired, minClickAuditionOutputOffsetMs);
    expect(changed.speaker, maxClickAuditionOutputOffsetMs);
    expect(
      () => changed.asMap['speaker'] = 0,
      throwsUnsupportedError,
    );
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

  test('settings notifier persists clamped local audition preferences',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final notifier = SettingsNotifier(preferences);

    notifier.setClickAuditionVolume(-1);
    notifier.setClickAuditionDownbeatAccentEnabled(false);
    notifier.setClickAuditionOutputOffsetMs(
      ClickAuditionOutputRoute.bluetooth,
      700,
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.clickAuditionVolume, 0);
    expect(notifier.state.clickAuditionDownbeatAccentEnabled, isFalse);
    expect(
      notifier.state.clickAuditionOutputOffsetMsFor(
        ClickAuditionOutputRoute.bluetooth,
      ),
      maxClickAuditionOutputOffsetMs,
    );

    final saved = jsonDecode(preferences.getString('app_settings')!)
        as Map<String, dynamic>;
    expect(saved['clickAuditionVolume'], 0);
    expect(saved['clickAuditionDownbeatAccentEnabled'], isFalse);
    expect(
      (saved['clickAuditionOutputOffsetsMs']
          as Map<String, dynamic>)['bluetooth'],
      maxClickAuditionOutputOffsetMs,
    );
  });

  test('DJ mode defaults on and survives an upgrade from an older blob', () {
    // The deck is the sanctioned ADR 0001 exception, scoped by this switch.
    // Default-on is deliberate (the operator is the only user), and an existing
    // stored blob predating the key must land on that default rather than
    // silently disabling a feature the user never turned off.
    expect(const SettingsModel().djModeEnabled, isTrue);
    expect(SettingsModel.fromJson(const {}).djModeEnabled, isTrue);
    expect(
      SettingsModel.fromJson(const {'crossfadeDuration': 4}).djModeEnabled,
      isTrue,
    );
    expect(
      SettingsModel.fromJson(const {'djModeEnabled': false}).djModeEnabled,
      isFalse,
    );
    expect(const SettingsModel().toJson()['djModeEnabled'], isTrue);
  });

  test('settings notifier persists the DJ mode opt-out', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final notifier = SettingsNotifier(preferences);

    expect(notifier.state.djModeEnabled, isTrue);

    notifier.setDjModeEnabled(false);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.djModeEnabled, isFalse);
    final saved = jsonDecode(preferences.getString('app_settings')!)
        as Map<String, dynamic>;
    expect(saved['djModeEnabled'], isFalse);

    // The opt-out has to survive a restart, otherwise the gate is decorative.
    expect(SettingsNotifier(preferences).state.djModeEnabled, isFalse);
  });
}
