import 'package:shared_preferences/shared_preferences.dart';

const String mixPreferenceKeyPrefix = 'mix_enabled_';

/// Best-effort local persistence for the per-playlist mix toggle.
Future<bool> loadMixEnabled(int playlistId) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('$mixPreferenceKeyPrefix$playlistId') ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> saveMixEnabled(int playlistId, bool enabled) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('$mixPreferenceKeyPrefix$playlistId', enabled);
  } catch (_) {
    // Preference persistence is best-effort; mix state stays in memory.
  }
}
