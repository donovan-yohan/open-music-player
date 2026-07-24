/// Theme mode options
enum AppThemeMode {
  system,
  light,
  dark;

  String get displayName {
    switch (this) {
      case AppThemeMode.system:
        return 'System';
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
    }
  }
}

enum KeyNotation {
  camelot,
  musical;

  String get displayName => switch (this) {
    KeyNotation.camelot => 'Camelot',
    KeyNotation.musical => 'Musical key',
  };
}

/// Application settings model
class SettingsModel {
  final int crossfadeDuration;
  final AppThemeMode themeMode;
  final KeyNotation keyNotation;

  const SettingsModel({
    this.crossfadeDuration = 0,
    this.themeMode = AppThemeMode.system,
    this.keyNotation = KeyNotation.camelot,
  });

  SettingsModel copyWith({
    int? crossfadeDuration,
    AppThemeMode? themeMode,
    KeyNotation? keyNotation,
  }) {
    return SettingsModel(
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      themeMode: themeMode ?? this.themeMode,
      keyNotation: keyNotation ?? this.keyNotation,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'crossfadeDuration': crossfadeDuration,
      'themeMode': themeMode.index,
      'keyNotation': keyNotation.name,
    };
  }

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    return SettingsModel(
      crossfadeDuration: json['crossfadeDuration'] ?? 0,
      themeMode: AppThemeMode.values[json['themeMode'] ?? 0],
      keyNotation: _keyNotationFromJson(json['keyNotation']),
    );
  }
}

KeyNotation _keyNotationFromJson(Object? value) {
  if (value is int && value >= 0 && value < KeyNotation.values.length) {
    return KeyNotation.values[value];
  }
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'musical' || 'musical_key' || 'raw' => KeyNotation.musical,
    _ => KeyNotation.camelot,
  };
}
