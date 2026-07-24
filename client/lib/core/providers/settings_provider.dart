import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings_model.dart';

const _settingsKey = 'app_settings';

/// Provider for SharedPreferences instance
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in main');
});

/// Settings notifier that manages app settings state
class SettingsNotifier extends StateNotifier<SettingsModel> {
  final SharedPreferences _prefs;

  SettingsNotifier(this._prefs) : super(const SettingsModel()) {
    _loadSettings();
  }

  void _loadSettings() {
    final jsonString = _prefs.getString(_settingsKey);
    if (jsonString != null) {
      try {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        state = SettingsModel.fromJson(json);
      } catch (_) {
        // Use default settings if parsing fails
      }
    }
  }

  Future<void> _saveSettings() async {
    final jsonString = jsonEncode(state.toJson());
    await _prefs.setString(_settingsKey, jsonString);
  }

  void setCrossfadeDuration(int seconds) {
    state = state.copyWith(crossfadeDuration: seconds.clamp(0, 12));
    _saveSettings();
  }

  void setThemeMode(AppThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _saveSettings();
  }

  void setKeyNotation(KeyNotation notation) {
    state = state.copyWith(keyNotation: notation);
    _saveSettings();
  }
}

/// Provider for settings state
final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsModel>(
  (ref) {
    final prefs = ref.watch(sharedPreferencesProvider);
    return SettingsNotifier(prefs);
  },
);
